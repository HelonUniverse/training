import XCTest
@testable import CoachCore

/// Stands in for ScreenCaptureKit / ReplayKit: the runner and controller
/// must behave the same whatever produced the frames.
final class FakeCaptureProvider: GameplayCaptureProvider, @unchecked Sendable {
    typealias Payload = Int

    let kind = CaptureProviderKind(rawValue: "Fake.Provider")
    let frames: AsyncStream<GameplayFrame<Int>>
    let statuses: AsyncStream<CaptureProviderStatus>
    private let frameContinuation: AsyncStream<GameplayFrame<Int>>.Continuation
    private let statusContinuation: AsyncStream<CaptureProviderStatus>.Continuation
    var startError: Error?
    private(set) var stopCalls = 0

    init() {
        (frames, frameContinuation) = AsyncStream.makeStream(of: GameplayFrame<Int>.self)
        (statuses, statusContinuation) = AsyncStream.makeStream(of: CaptureProviderStatus.self)
    }

    func start() async throws {
        statusContinuation.yield(.awaitingUserSelection)
        if let startError {
            statusContinuation.yield(.stopped(.cancelled))
            throw startError
        }
        statusContinuation.yield(.running)
    }

    func stop() async {
        stopCalls += 1
        end(.stopped(.userInApp))
    }

    func deliver(_ count: Int, fps: Double = 30, from start: Double = 500) {
        for index in 0..<count {
            frameContinuation.yield(GameplayFrame(sequenceNumber: Int64(index + 1), timestamp: start + Double(index) / fps,
                                                  width: 2556, height: 1179, orientation: 1, source: kind, payload: index))
        }
    }

    /// Terminal status first, then both streams finish (the provider contract).
    func end(_ status: CaptureProviderStatus) {
        statusContinuation.yield(status)
        statusContinuation.finish()
        frameContinuation.finish()
    }
}

final class CaptureProviderTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeRunner(_ provider: FakeCaptureProvider) -> (CaptureSessionRunner<FakeCaptureProvider>, CaptureSessionController) {
        let controller = CaptureSessionController(
            store: store, gameID: "fortnite",
            source: CaptureSourceInfo(platform: "test", mechanism: provider.kind.rawValue),
            settings: .default, metricsSampler: { ProcessMetricsSample() }, hostClock: { nil }
        )
        let runner = CaptureSessionRunner(
            provider: provider, controller: controller,
            handleFrame: { frame in
                let decision = controller.videoFrame(pts: frame.timestamp, width: frame.width, height: frame.height, orientation: frame.orientation)
                if decision.analyze {
                    controller.analysisCompleted(frameIndex: decision.frameIndex, sessionTime: decision.sessionTime, duration: 0.001, luma: 0.5)
                }
            },
            finishPipeline: { reason in controller.finish(failureReason: reason) }
        )
        return (runner, controller)
    }

    func testFramesFlowIntoTheSamePipelineAndStopFinishesTheSession() async throws {
        let provider = FakeCaptureProvider()
        let (runner, controller) = makeRunner(provider)
        try await runner.start()
        provider.deliver(90)
        await runner.stop()

        let manifest = try store.manifest(for: controller.sessionID)
        XCTAssertEqual(manifest.status, .finished)
        XCTAssertEqual(manifest.source.mechanism, "Fake.Provider")
        XCTAssertEqual(manifest.statistics.videoFramesReceived, 90)
        XCTAssertEqual(manifest.statistics.framesAnalyzed, 30)
        let statuses = store.events(for: controller.sessionID)
            .filter { $0.type == .captureSourceStatus }
            .compactMap { $0.metadata["status"] }
        XCTAssertEqual(statuses.first, "running")
        XCTAssertEqual(statuses.last, "stopped: userInApp")
        XCTAssertEqual(store.events(for: controller.sessionID).last?.type, .captureFinished)
    }

    func testCancelledPickerLeavesNoSession() async {
        let provider = FakeCaptureProvider()
        provider.startError = CaptureProviderError.cancelledByUser
        let (runner, _) = makeRunner(provider)
        do {
            try await runner.start()
            XCTFail("start should throw")
        } catch {
            XCTAssertEqual(error as? CaptureProviderError, .cancelledByUser)
        }
        XCTAssertTrue(store.allManifests().isEmpty)
    }

    func testSystemStopIsRecordedAsFailureReason() async throws {
        let provider = FakeCaptureProvider()
        let (runner, controller) = makeRunner(provider)
        try await runner.start()
        provider.deliver(10)
        provider.end(.failed("missingBackgroundMode"))
        await runner.waitUntilFinished()

        let manifest = try store.manifest(for: controller.sessionID)
        XCTAssertEqual(manifest.status, .failed)
        XCTAssertEqual(manifest.failureReason, "missingBackgroundMode")
        XCTAssertEqual(store.events(for: controller.sessionID).last?.type, .captureFailed)
    }

    func testUserStopFromSystemUIIsANormalFinish() async throws {
        let provider = FakeCaptureProvider()
        let (runner, controller) = makeRunner(provider)
        try await runner.start()
        provider.end(.stopped(.userSystemUI))
        await runner.waitUntilFinished()
        XCTAssertEqual(try store.manifest(for: controller.sessionID).status, .finished)
    }
}

final class ProviderComparisonTests: XCTestCase {
    private func manifest(_ provider: CaptureProviderKind, seconds: Double, received: Int64, dropped: Int64,
                          peak: Int64?, status: SessionStatus = .finished) -> SessionManifest {
        var manifest = SessionManifest(gameID: "fortnite", createdAt: Date(timeIntervalSince1970: 0),
                                       source: CaptureSourceInfo(platform: "iOS", mechanism: provider.rawValue),
                                       settings: .default)
        manifest.status = status
        manifest.updatedAt = Date(timeIntervalSince1970: seconds)
        manifest.statistics.mediaDuration = seconds
        manifest.statistics.videoFramesReceived = received
        manifest.statistics.framesAnalyzed = Int64(seconds * 10)
        manifest.statistics.drops = ["encoderNotReady": dropped]
        manifest.statistics.peakMemoryFootprintBytes = peak
        return manifest
    }

    func testNoSessionsMeansNoNumbers() {
        let comparison = ProviderComparison(sessions: [], now: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(comparison.columns.map(\.hasData), [false, false])
        XCTAssertNil(comparison.column(.screenCaptureKit)?.inputFPS)
        XCTAssertTrue(comparison.text().contains("no completed device session recorded"))
        XCTAssertFalse(comparison.text().contains("FPS"))
    }

    func testAggregatesPerProviderWithDurationWeighting() {
        var notes = DeviceTestNotes()
        notes.fortniteFrameRateDegraded = .yes
        notes.survivedCombat = .no
        notes.fortnitePerformanceNotes = "stutter in storm"
        let sessions: [(manifest: SessionManifest, notes: DeviceTestNotes)] = [
            (manifest(.replayKit, seconds: 100, received: 3000, dropped: 30, peak: 30 << 20), DeviceTestNotes()),
            (manifest(.replayKit, seconds: 300, received: 18000, dropped: 0, peak: 40 << 20), notes),
            (manifest(.replayKit, seconds: 50, received: 0, dropped: 0, peak: nil), DeviceTestNotes()), // no frames: ignored
            (manifest(.screenCaptureKit, seconds: 60, received: 3600, dropped: 36, peak: nil, status: .failed), DeviceTestNotes()),
        ]
        let comparison = ProviderComparison(sessions: sessions, now: Date(timeIntervalSince1970: 10_000))
        let replayKit = comparison.column(.replayKit)!
        XCTAssertEqual(replayKit.sessions, 2)
        XCTAssertEqual(replayKit.inputFPS ?? 0, (30.0 * 100 + 60.0 * 300) / 400, accuracy: 0.001)
        XCTAssertEqual(replayKit.droppedPercent ?? 0, 30.0 / 21000 * 100, accuracy: 0.0001)
        XCTAssertEqual(replayKit.peakMemoryBytes, 40 << 20)
        XCTAssertNil(replayKit.averageLatency)
        XCTAssertEqual(replayKit.fortniteDegradedYes, 1)
        XCTAssertEqual(replayKit.captureSurvivalFailures, 1)
        let sck = comparison.column(.screenCaptureKit)!
        XCTAssertEqual(sck.failed, 1)
        XCTAssertNil(sck.peakMemoryBytes)
        XCTAssertTrue(comparison.text().contains("notes: stutter in storm"))
    }
}
