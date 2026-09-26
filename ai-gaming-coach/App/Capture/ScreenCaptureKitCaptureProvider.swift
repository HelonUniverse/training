#if canImport(ScreenCaptureKit)
import CoachCore
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Milestone 1.5 prototype: captures the whole display from inside the app
/// with ScreenCaptureKit (iOS 27+), so there is no broadcast extension and
/// no extension memory limit.
///
/// Consent: `start()` shows Apple's `SCContentSharingPicker` in full-display
/// mode (`present()`). Nothing is captured until the user confirms there.
/// The system shows its own recording indicator and can stop capture at any
/// time; that arrives as `stream(_:didStopWithError:)` with `userStopped`.
///
/// Background: capture continues while another app (Fortnite) is in front
/// only because the app declares the `screen-capture` background mode.
/// Without it, ScreenCaptureKit reports `SCStreamError.Code.missingBackgroundMode`.
///
/// Every API used here is documented for iOS 27. Stream configuration
/// options such as `minimumFrameInterval`, `pixelFormat` and `queueDepth`
/// are macOS-only, so frame rate and format are the system's defaults;
/// analysis throttling happens downstream in `FrameGate`.
@available(iOS 27.0, *)
final class ScreenCaptureKitCaptureProvider: NSObject, GameplayCaptureProvider, @unchecked Sendable {
    typealias Payload = CMSampleBuffer

    let kind = CaptureProviderKind.screenCaptureKit
    let frames: AsyncStream<GameplayFrame<CMSampleBuffer>>
    let statuses: AsyncStream<CaptureProviderStatus>

    /// Frames without image content (idle, blank, suspended…), by status.
    var onFrameWithoutImage: (@Sendable (String) -> Void)?
    /// A frame replaced in the hand-off buffer before the pipeline took it.
    var onBackpressureDrop: (@Sendable () -> Void)?

    private let frameContinuation: AsyncStream<GameplayFrame<CMSampleBuffer>>.Continuation
    private let statusContinuation: AsyncStream<CaptureProviderStatus>.Continuation
    private let sampleQueue = DispatchQueue(label: "coach.sck.samples", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var sequenceNumber: Int64 = 0
    private var ended = false

    /// Whether this device allows screen recording through the system picker.
    @MainActor static var isAvailable: Bool {
        SCContentSharingPicker.shared.isAvailable
    }

    override init() {
        // Hold at most one frame between the capture queue and the pipeline:
        // ScreenCaptureKit reuses a small pool of buffers, and hoarding them
        // would stall capture. A replaced frame is reported as backpressure.
        (frames, frameContinuation) = AsyncStream.makeStream(of: GameplayFrame<CMSampleBuffer>.self,
                                                             bufferingPolicy: .bufferingNewest(1))
        (statuses, statusContinuation) = AsyncStream.makeStream(of: CaptureProviderStatus.self)
        super.init()
    }

    // MARK: GameplayCaptureProvider

    func start() async throws {
        statusContinuation.yield(.awaitingUserSelection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock { startContinuation = continuation }
            Task { @MainActor in self.presentPicker() }
        }
    }

    func stop() async {
        let stream: SCStream? = lock.withLock {
            let current = self.stream
            self.stream = nil
            return current
        }
        if let stream {
            try? await stream.stopCapture()
        }
        end(.stopped(.userInApp))
    }

    // MARK: Picker

    @MainActor
    private func presentPicker() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        // Video only for the prototype; no microphone or camera toggles.
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        // Full-display capture, which is what lets us see another app.
        picker.present()
    }

    @MainActor
    private func deactivatePicker() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func resumeStart(with result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            let current = startContinuation
            startContinuation = nil
            return current
        }
        continuation?.resume(with: result)
    }

    private func startStream(with filter: SCContentFilter) async {
        statusContinuation.yield(.starting)
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            lock.withLock { self.stream = stream }
            statusContinuation.yield(.running)
            resumeStart(with: .success(()))
        } catch {
            let message = Self.describe(error)
            resumeStart(with: .failure(CaptureProviderError.failedToStart(message)))
            end(.failed(message))
        }
    }

    // MARK: Ending

    /// Reports the terminal status, then finishes both streams (in that
    /// order, as `GameplayCaptureProvider` requires). Idempotent.
    private func end(_ status: CaptureProviderStatus) {
        let first: Bool = lock.withLock {
            defer { ended = true }
            return !ended
        }
        guard first else { return }
        statusContinuation.yield(status)
        statusContinuation.finish()
        frameContinuation.finish()
        Task { @MainActor in self.deactivatePicker() }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? SCStreamError {
            return "\(codeName(error.code)) (\(error.localizedDescription))"
        }
        return error.localizedDescription
    }

    static func codeName(_ code: SCStreamError.Code) -> String {
        switch code {
        case .userStopped: return "userStopped"
        case .userDeclined: return "userDeclined"
        case .missingEntitlements: return "missingEntitlements"
        case .missingBackgroundMode: return "missingBackgroundMode"
        case .systemStoppedStream: return "systemStoppedStream"
        case .failedToStart: return "failedToStart"
        case .notSupported: return "notSupported"
        case .insufficientStorage: return "insufficientStorage"
        case .noCaptureSource: return "noCaptureSource"
        case .internalError: return "internalError"
        default: return "code \(code.rawValue)"
        }
    }

    // MARK: Frame metadata

    static func frameInfo(_ sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]]
        else { return nil }
        return attachments.first
    }

    static func statusName(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        @unknown default: return "status \(status.rawValue)"
        }
    }
}

// MARK: - SCContentSharingPickerObserver

@available(iOS 27.0, *)
extension ScreenCaptureKitCaptureProvider: SCContentSharingPickerObserver {
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // `stream` is non-nil when the user edits an existing share. iOS has
        // no updateContentFilter, and the prototype keeps its first choice.
        guard stream == nil, lock.withLock({ self.stream == nil && !ended }) else { return }
        Task { await startStream(with: filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        resumeStart(with: .failure(CaptureProviderError.cancelledByUser))
        end(.stopped(.cancelled))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let message = Self.describe(error)
        resumeStart(with: .failure(CaptureProviderError.failedToStart(message)))
        end(.failed(message))
    }
}

// MARK: - SCStreamOutput, SCStreamDelegate

@available(iOS 27.0, *)
extension ScreenCaptureKitCaptureProvider: SCStreamOutput, SCStreamDelegate {
    /// Runs serially on `sampleQueue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let info = Self.frameInfo(sampleBuffer)
        let status = (info?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        // Only `complete` frames carry a new image; the rest say why not.
        guard status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onFrameWithoutImage?(status.map(Self.statusName) ?? "noStatus")
            return
        }
        let orientation = (info?[.videoOrientation] as? NSNumber)?.intValue ?? 1
        sequenceNumber += 1
        let frame = GameplayFrame(
            sequenceNumber: sequenceNumber,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            orientation: orientation,
            source: kind,
            payload: sampleBuffer
        )
        if case .dropped = frameContinuation.yield(frame) {
            onBackpressureDrop?()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
        if let error = error as? SCStreamError {
            switch error.code {
            case .userStopped:
                end(.stopped(.userSystemUI))
                return
            case .systemStoppedStream:
                end(.stopped(.system))
                return
            default:
                break
            }
        }
        end(.failed(Self.describe(error)))
    }

    func streamDidBecomeInactive(_ stream: SCStream) {
        statusContinuation.yield(.interrupted("stream inactive"))
    }

    func streamDidBecomeActive(_ stream: SCStream) {
        statusContinuation.yield(.running)
    }
}
#endif
