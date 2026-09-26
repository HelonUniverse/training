import XCTest
@testable import CoachCore

final class DeviceMetricsTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!
    private let clock = TestClock()
    private let metrics = TestMetrics()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController() throws -> CaptureSessionController {
        let controller = CaptureSessionController(
            store: store, gameID: "fortnite",
            source: CaptureSourceInfo(platform: "iOS", mechanism: CaptureProviderKind.replayKit.rawValue, deviceModel: "iPhone16,1", osVersion: "Version 18.6"),
            settings: .default, now: { [clock] in clock.now },
            metricsSampler: { [metrics] in metrics.next() },
            hostClock: { [clock] in clock.host }
        )
        try controller.start()
        return controller
    }

    func testMetricsArePeakAndAverageAndThermalChangesAreEvents() throws {
        metrics.samples = [
            ProcessMetricsSample(memoryFootprintBytes: 20 << 20, cpuPercent: 30, thermalState: .nominal),
            ProcessMetricsSample(memoryFootprintBytes: 40 << 20, cpuPercent: 50, thermalState: .serious),
            ProcessMetricsSample(memoryFootprintBytes: 30 << 20, cpuPercent: 40, thermalState: .fair),
        ]
        let controller = try makeController()
        for second in 0..<3 {
            clock.now = Date(timeIntervalSince1970: 1_000_000 + Double(second) * 1.5)
            _ = controller.videoFrame(pts: Double(second), width: 10, height: 10, orientation: 1)
        }
        let stats = controller.finish().statistics
        XCTAssertEqual(stats.peakMemoryFootprintBytes, 40 << 20)
        XCTAssertEqual(stats.averageMemoryFootprintBytes ?? 0, Double(30 << 20), accuracy: 1)
        XCTAssertEqual(stats.peakCPUPercent, 50)
        XCTAssertEqual(stats.averageCPUPercent ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(stats.worstThermalState, .serious)
        XCTAssertEqual(stats.thermalState, .fair)
        let changes = store.events(for: controller.sessionID).filter { $0.type == .thermalStateChanged }
        XCTAssertEqual(changes.map { $0.metadata["to"] }, ["serious", "fair"])
    }

    func testUnmeasuredMetricsStayNil() throws {
        let controller = try makeController()
        _ = controller.videoFrame(pts: 0, width: 10, height: 10, orientation: 1)
        let stats = controller.finish().statistics
        XCTAssertNil(stats.peakMemoryFootprintBytes)
        XCTAssertNil(stats.averageCPUPercent)
        XCTAssertNil(stats.worstThermalState)
        XCTAssertNil(stats.averageCaptureLatency)
        XCTAssertNil(stats.blackFramePercent, "no frame was probed")
    }

    func testLatencyIgnoresImplausibleClockValues() throws {
        let controller = try makeController()
        clock.host = 100.020
        _ = controller.videoFrame(pts: 100.0, width: 10, height: 10, orientation: 1)   // 20 ms
        clock.host = 100.140
        _ = controller.videoFrame(pts: 100.1, width: 10, height: 10, orientation: 1)   // 40 ms
        clock.host = 9_999
        _ = controller.videoFrame(pts: 100.2, width: 10, height: 10, orientation: 1)   // different clock
        let stats = controller.finish().statistics
        XCTAssertEqual(stats.captureLatencySamples, 2)
        XCTAssertEqual(stats.averageCaptureLatency ?? 0, 0.030, accuracy: 0.0001)
        XCTAssertEqual(stats.maxCaptureLatency ?? 0, 0.040, accuracy: 0.0001)
        XCTAssertEqual(stats.captureLatencyOutOfRange, 1)
    }

    func testRollingBufferBytesAndBlackFramePercent() throws {
        let controller = try makeController()
        for i in 0..<4 {
            let decision = controller.videoFrame(pts: Double(i), width: 10, height: 10, orientation: 1)
            controller.analysisCompleted(frameIndex: decision.frameIndex, sessionTime: decision.sessionTime, duration: 0.001, luma: i == 0 ? 0.0 : 0.5)
        }
        for id in 1...3 {
            let file = controller.nextSegmentFile()
            try Data(count: 10).write(to: file.url)
            controller.segmentFinished(id: file.id, fileName: file.fileName, startPTS: Double(id - 1) * 5, endPTS: Double(id) * 5, frameCount: 1, byteCount: 1_000_000)
        }
        controller.sourceFrameSkipped(status: "idle")
        controller.sourceFrameSkipped(status: "idle")
        let stats = controller.finish().statistics
        XCTAssertEqual(stats.blackFramePercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(stats.rollingBufferBytes, 3_000_000)
        XCTAssertEqual(stats.peakRollingBufferBytes, 3_000_000)
        XCTAssertEqual(stats.sourceFrameStatus, ["idle": 2])
        XCTAssertEqual(stats.videoFramesReceived, 4, "frames without an image are not received frames")
    }

    /// A manifest written by the Milestone 1 build (before the device
    /// metrics existed) must still load, or old sessions would vanish.
    func testMilestoneOneManifestStillDecodes() throws {
        let controller = try makeController()
        _ = controller.videoFrame(pts: 0, width: 10, height: 10, orientation: 1)
        controller.finish()
        let url = controller.directory.manifestURL
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var stats = json["statistics"] as! [String: Any]
        for key in ["memoryFootprintBytes", "peakMemoryFootprintBytes", "memoryFootprintSampleSum", "memoryFootprintSamples",
                    "cpuPercent", "peakCPUPercent", "cpuPercentSampleSum", "cpuSamples", "thermalState", "worstThermalState",
                    "lastCaptureLatency", "maxCaptureLatency", "captureLatencySum", "captureLatencySamples",
                    "captureLatencyOutOfRange", "rollingBufferBytes", "peakRollingBufferBytes", "sourceFrameStatus"] {
            stats[key] = nil
        }
        json["statistics"] = stats
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try store.manifest(for: controller.sessionID).statistics.videoFramesReceived, 1)
    }

    func testDeviceTestReportCarriesAllEighteenItems() throws {
        metrics.samples = [ProcessMetricsSample(memoryFootprintBytes: 31 << 20, cpuPercent: 22, thermalState: .fair)]
        let controller = try makeController()
        let decision = controller.videoFrame(pts: 0, width: 2556, height: 1179, orientation: 1)
        controller.analysisCompleted(frameIndex: decision.frameIndex, sessionTime: 0, duration: 0.001, luma: 0.4)
        controller.frameDropped(.encoderNotReady)
        controller.finish()

        var notes = DeviceTestNotes()
        notes.iPhoneModelName = "iPhone 15 Pro"
        notes.fortniteVersion = "37.10"
        notes.survivedCombat = .yes
        notes.fortniteFrameRateDegraded = .no
        try store.save(notes, for: controller.sessionID)

        let report = try store.deviceTestReport(for: controller.sessionID)
        XCTAssertEqual(report.notes, notes)
        XCTAssertEqual(report.captureProvider, CaptureProviderKind.replayKit.displayName)
        XCTAssertEqual(report.peakMemoryMB ?? 0, 31, accuracy: 0.01)
        XCTAssertEqual(report.droppedByReason, ["encoderNotReady": 1])
        XCTAssertEqual(report.sessionStatus, "finished normally")

        let text = report.text()
        XCTAssertTrue(text.hasPrefix("DEVICE TEST RESULT"))
        for item in 1...18 {
            XCTAssertTrue(text.contains("\n\(item). "), "item \(item) missing")
        }
        XCTAssertTrue(text.contains("1. iPhone model: iPhone 15 Pro (iPhone16,1)"))
        XCTAssertTrue(text.contains("capture latency: avg not measured"))
        XCTAssertTrue(text.contains("combat: yes"))

        let decoded = try JSONDecoder.iso8601.decode(DeviceTestReport.self, from: Data(report.json().utf8))
        XCTAssertEqual(decoded.framesReceived, 1)
    }

    func testSessionThatLostItsHeartbeatIsReportedAsTerminated() throws {
        let controller = try makeController()
        _ = controller.videoFrame(pts: 0, width: 10, height: 10, orientation: 1)
        controller.flush()
        controller.waitForPendingWrites()
        let report = try store.deviceTestReport(for: controller.sessionID, now: clock.now.addingTimeInterval(60))
        XCTAssertEqual(report.sessionStatus, "ended without finishing (capture process terminated?)")
    }

    #if canImport(Darwin)
    func testDarwinSamplerReportsRealValues() {
        let sample = ProcessMetrics.sample()
        XCTAssertGreaterThan(sample.memoryFootprintBytes ?? 0, 0)
        XCTAssertNotNil(sample.cpuPercent)
        XCTAssertNotNil(sample.thermalState)
        XCTAssertNotNil(HostClock.now())
    }
    #endif
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
