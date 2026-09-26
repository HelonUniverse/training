import Foundation

/// Connects any `GameplayCaptureProvider` to a `CaptureSessionController`.
///
/// It asks the provider to start (user consent). Only once capture is
/// running does it create the session on disk, so a cancelled picker leaves
/// nothing behind. It then feeds every frame to `handleFrame` (the
/// platform's frame pipeline), records provider status changes on the
/// timeline, and finishes the session when the provider ends, whoever
/// ended it.
public final class CaptureSessionRunner<Provider: GameplayCaptureProvider>: @unchecked Sendable {
    public typealias Frame = GameplayFrame<Provider.Payload>

    public let provider: Provider
    public let controller: CaptureSessionController
    private let handleFrame: (Frame) -> Void
    private let finishPipeline: (_ failureReason: String?) -> Void
    private let lock = NSLock()
    private var lastStatus: CaptureProviderStatus?
    private var sessionStarted = false
    private var statusTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var completion: Task<Void, Never>?

    /// - Parameters:
    ///   - handleFrame: called serially for every frame, off the main thread.
    ///   - finishPipeline: flushes encoders and calls `controller.finish`.
    public init(provider: Provider, controller: CaptureSessionController,
                handleFrame: @escaping (Frame) -> Void,
                finishPipeline: @escaping (_ failureReason: String?) -> Void) {
        self.provider = provider
        self.controller = controller
        self.handleFrame = handleFrame
        self.finishPipeline = finishPipeline
    }

    public var status: CaptureProviderStatus? { locked { lastStatus } }

    /// Returns once capture is running. Throws (and records nothing) if the
    /// user cancels or the provider cannot start.
    public func start() async throws {
        let statuses = provider.statuses
        statusTask = Task { [weak self] in
            for await status in statuses {
                self?.observe(status)
            }
        }

        do {
            try await provider.start()
        } catch {
            await provider.stop()
            statusTask?.cancel()
            throw error
        }

        try controller.start()
        let current: CaptureProviderStatus? = locked {
            sessionStarted = true
            return lastStatus
        }
        if let current { recordStatusEvent(current) }

        let frames = provider.frames
        let handleFrame = handleFrame
        frameTask = Task.detached(priority: .userInitiated) {
            for await frame in frames {
                handleFrame(frame)
            }
        }
        completion = Task.detached { [weak self] in
            await self?.frameTask?.value
            // Providers report the terminal status before finishing their
            // streams; wait for it so the reason reaches the manifest.
            await self?.statusTask?.value
            self?.finish()
        }
    }

    /// Stops capture and waits until the session is finished on disk.
    public func stop() async {
        await provider.stop()
        await completion?.value
    }

    /// Resolves when the session has been finished (by any party).
    public func waitUntilFinished() async {
        await completion?.value
    }

    private func observe(_ status: CaptureProviderStatus) {
        let record: Bool = locked {
            lastStatus = status
            return sessionStarted
        }
        if record { recordStatusEvent(status) }
    }

    private func recordStatusEvent(_ status: CaptureProviderStatus) {
        controller.record(MatchEvent(
            timestamp: controller.currentSessionTime, type: .captureSourceStatus, confidence: 1, origin: .pipeline,
            metadata: ["provider": provider.kind.rawValue, "status": status.label]
        ))
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func finish() {
        let reason: String? = {
            switch status {
            case .failed(let message): return message
            case .stopped(.system): return "The system stopped screen capture."
            default: return nil
            }
        }()
        finishPipeline(reason)
    }
}
