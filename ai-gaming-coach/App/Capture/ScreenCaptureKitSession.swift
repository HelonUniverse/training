#if canImport(ScreenCaptureKit)
import CoachCore
import Foundation

/// One in-app ScreenCaptureKit capture session:
///
///     ScreenCaptureKitCaptureProvider → GameplayFrame → FramePipeline
///         → CaptureSessionController (rolling buffer, keyframes, timeline, stats)
///
/// Everything downstream of the provider is shared with ReplayKit, and the
/// session lands in the same App Group store, so Session Summary, Event
/// Timeline, Debug and the Device Test Result work unchanged.
@available(iOS 27.0, *)
final class ScreenCaptureKitSession {
    private let runner: CaptureSessionRunner<ScreenCaptureKitCaptureProvider>

    init(environment: SharedEnvironment) throws {
        try DeviceInfo.checkFreeStorage(at: environment.containerURL)
        let provider = ScreenCaptureKitCaptureProvider()
        let controller = CaptureSessionController(
            store: environment.store,
            gameID: environment.selectedGameID,
            source: CaptureSourceInfo(
                platform: "iOS",
                mechanism: provider.kind.rawValue,
                deviceModel: DeviceInfo.hardwareModel(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ),
            settings: environment.settingsStore.load()
        )
        controller.onManifestWritten = { _ in CoachNotification.post(CoachNotification.sessionUpdated) }
        provider.onFrameWithoutImage = { status in controller.sourceFrameSkipped(status: status) }
        provider.onBackpressureDrop = { controller.frameDropped(.pipelineBackpressure) }

        let pipeline = FramePipeline(controller: controller)
        runner = CaptureSessionRunner(
            provider: provider,
            controller: controller,
            handleFrame: { frame in pipeline.process(frame) },
            finishPipeline: { reason in pipeline.finish(failureReason: reason) }
        )
    }

    /// Shows Apple's picker; returns once capture runs. Throws on cancel.
    func start() async throws {
        try await runner.start()
    }

    func stop() async {
        await runner.stop()
    }

    func waitUntilFinished() async {
        await runner.waitUntilFinished()
    }
}
#endif
