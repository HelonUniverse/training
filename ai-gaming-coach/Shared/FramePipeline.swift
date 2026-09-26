import CoachCore
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os

/// Capture-independent media pipeline for normalized frames:
///
///     GameplayFrame<CMSampleBuffer> ─┬─ SegmentWriter   (rolling buffer, every frame)
///                                    ├─ analysis        (throttled; FrameProbe today,
///                                    │                   GameAdapter vision from M2)
///                                    └─ KeyframeEncoder (periodic / on event)
///
/// It uses the same SegmentWriter, KeyframeEncoder and FrameProbe as the
/// ReplayKit extension's `BroadcastPipeline`, and does the same work, but
/// it takes a `GameplayFrame` instead of a ReplayKit sample. Pixels stay
/// in the provider's `CVPixelBuffer`; only keyframes become JPEG.
///
/// The ScreenCaptureKit provider uses it now. `BroadcastPipeline` will move
/// onto it once the ReplayKit build has passed physical-device validation,
/// so that build stays exactly what is being tested.
///
/// `process` must be called serially; `finish` after the last `process`.
final class FramePipeline: @unchecked Sendable {
    let controller: CaptureSessionController
    private let segmentWriter: SegmentWriter
    private let keyframeEncoder = KeyframeEncoder()
    private let analysisQueue = DispatchQueue(label: "coach.frame-pipeline.analysis", qos: .userInitiated)
    private let analysisLock = NSLock()
    private var analysisBusy = false
    private var lastMemorySample: Double = -.infinity

    init(controller: CaptureSessionController) {
        let settings = controller.settings
        self.controller = controller
        segmentWriter = SegmentWriter(
            configuration: .init(segmentSeconds: settings.segmentSeconds,
                                 maxDimension: settings.videoMaxDimension,
                                 bitrate: settings.videoBitrate),
            makeFile: { controller.nextSegmentFile() },
            onFinished: { segment in
                controller.segmentFinished(id: segment.id, fileName: segment.fileName,
                                           startPTS: segment.startPTS, endPTS: segment.endPTS,
                                           frameCount: segment.frameCount, byteCount: segment.byteCount)
            },
            onError: { _ in controller.reportStorageError() }
        )
    }

    func process(_ frame: GameplayFrame<CMSampleBuffer>) {
        let sampleBuffer = frame.payload
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            controller.frameDropped(.invalidBuffer)
            return
        }
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(frame.orientation)) ?? .up
        let decision = controller.videoFrame(pts: frame.timestamp, width: frame.width, height: frame.height,
                                             orientation: frame.orientation)

        switch segmentWriter.append(sampleBuffer, width: frame.width, height: frame.height, orientation: orientation) {
        case .appended: controller.frameEncoded()
        case .notReady: controller.frameDropped(.encoderNotReady)
        case .failed: controller.frameDropped(.encoderFailed)
        }

        if decision.analyze {
            analyze(PixelBufferHandoff(buffer: pixelBuffer), decision: decision)
        }
        if let reason = decision.keyframe {
            saveKeyframe(pixelBuffer, orientation: orientation, decision: decision, reason: reason)
        }
        sampleMemory(at: decision.sessionTime)
    }

    /// Finalizes the open segment, then the session.
    func finish(failureReason: String?) {
        segmentWriter.finishAll(timeout: 3)
        controller.finish(failureReason: failureReason)
        CoachNotification.post(CoachNotification.sessionUpdated)
    }

    private func analyze(_ handoff: PixelBufferHandoff, decision: FrameDecision) {
        analysisLock.lock()
        if analysisBusy {
            analysisLock.unlock()
            controller.frameDropped(.analysisBusy)
            return
        }
        analysisBusy = true
        analysisLock.unlock()

        analysisQueue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let luma = FrameProbe.meanLuma(handoff.buffer)
            // Milestone 2: GameAdapter vision runs here, on this same frame.
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            controller.analysisCompleted(frameIndex: decision.frameIndex, sessionTime: decision.sessionTime,
                                         duration: seconds, luma: luma)
            analysisLock.lock()
            analysisBusy = false
            analysisLock.unlock()
        }
    }

    private func saveKeyframe(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                              decision: FrameDecision, reason: KeyframeReason) {
        let file = controller.keyframeFile(frameIndex: decision.frameIndex)
        let settings = controller.settings
        let controller = controller
        let accepted = keyframeEncoder.encode(
            pixelBuffer, orientation: orientation,
            maxDimension: settings.keyframeMaxDimension, quality: settings.keyframeJPEGQuality,
            to: file.url
        ) { result in
            switch result {
            case .success(let output):
                controller.keyframeSaved(KeyframeRecord(
                    id: file.id, frameIndex: decision.frameIndex, timestamp: decision.sessionTime, reason: reason,
                    fileName: file.fileName, width: output.width, height: output.height, byteCount: output.byteCount
                ))
            case .failure:
                controller.reportStorageError()
            }
        }
        if !accepted { controller.frameDropped(.keyframeBusy) }
    }

    private func sampleMemory(at time: Double) {
        guard time - lastMemorySample >= 1 || time < lastMemorySample else { return }
        lastMemorySample = time
        controller.updateMemory(availableBytes: Int64(os_proc_available_memory()))
    }
}
