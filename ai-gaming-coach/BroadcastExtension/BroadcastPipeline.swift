import CoachCore
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ReplayKit
import os

/// The extension-side pipeline:
///
///     CMSampleBuffer ─┬─ video ─┬─ SegmentWriter   (rolling buffer, every frame)
///                     │         ├─ analysis        (throttled; FrameProbe in M1,
///                     │         │                   GameAdapter vision from M2)
///                     │         └─ KeyframeEncoder (periodic / on event)
///                     └─ audio ── counted only (video is the MVP priority)
///
/// All bookkeeping lives in `CaptureSessionController` (CoachCore), so this
/// file only moves pixels.
final class BroadcastPipeline {
    enum StartError: LocalizedError {
        case lowStorage(Int64)

        var errorDescription: String? {
            switch self {
            case .lowStorage(let bytes):
                return "Not enough free storage to start coaching (\(bytes / 1_048_576) MB free, 500 MB needed)."
            }
        }
    }

    static let minimumFreeBytes: Int64 = 500 * 1_048_576

    let controller: CaptureSessionController
    private let segmentWriter: SegmentWriter
    private let keyframeEncoder = KeyframeEncoder()
    private let analysisQueue = DispatchQueue(label: "coach.analysis", qos: .userInitiated)
    private let analysisLock = NSLock()
    private var analysisBusy = false
    private var lastMemorySample: Double = -.infinity

    init() throws {
        let environment = try SharedEnvironment.current()
        try Self.checkFreeStorage(at: environment.containerURL)

        let settings = environment.settingsStore.load()
        let controller = CaptureSessionController(
            store: environment.store,
            gameID: environment.selectedGameID,
            source: CaptureSourceInfo(
                platform: "iOS",
                mechanism: "ReplayKit.BroadcastUploadExtension",
                deviceModel: Self.hardwareModel(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ),
            settings: settings
        )
        controller.onManifestWritten = { _ in CoachNotification.post(CoachNotification.sessionUpdated) }
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

        try controller.start()
        controller.flush()
    }

    // MARK: Samples

    func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            controller.frameDropped(.invalidBuffer)
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else {
            controller.frameDropped(.invalidBuffer)
            return
        }

        let orientation = Self.orientation(of: sampleBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let decision = controller.videoFrame(pts: pts.seconds, width: width, height: height,
                                             orientation: Int(orientation.rawValue))

        // 1. Rolling buffer: every frame goes to the hardware encoder.
        switch segmentWriter.append(sampleBuffer, width: width, height: height, orientation: orientation) {
        case .appended: controller.frameEncoded()
        case .notReady: controller.frameDropped(.encoderNotReady)
        case .failed: controller.frameDropped(.encoderFailed)
        }

        // 2. Fast analysis, throttled to settings.analysisFPS.
        if decision.analyze {
            analyze(pixelBuffer, decision: decision)
        }

        // 3. Keyframes.
        if let reason = decision.keyframe {
            saveKeyframe(pixelBuffer, orientation: orientation, decision: decision, reason: reason)
        }

        sampleMemory(at: decision.sessionTime)
    }

    func handleAudio(_ kind: AudioSourceKind) {
        controller.audioSample(kind)
    }

    private func analyze(_ pixelBuffer: CVPixelBuffer, decision: FrameDecision) {
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
            let luma = FrameProbe.meanLuma(pixelBuffer)
            // Milestone 2: HUD / health / shield / inventory detection runs
            // here through a GameAdapter, on this same throttled frame.
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

    // MARK: Lifecycle

    func pause() { controller.pause() }
    func resume() { controller.resume() }

    /// Finalizes the last segment and the session. Blocks briefly: the
    /// system may terminate the extension soon after broadcastFinished returns.
    func finish(failureReason: String? = nil) {
        segmentWriter.finishAll(timeout: 3)
        controller.finish(failureReason: failureReason)
        CoachNotification.post(CoachNotification.sessionUpdated)
    }

    // MARK: Helpers

    static func orientation(of sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value)
        else { return .up }
        return orientation
    }

    private static func checkFreeStorage(at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < minimumFreeBytes {
            throw StartError.lowStorage(free)
        }
    }

    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
