import XCTest
@testable import CoachCore

/// Drives the controller the way the broadcast extension does, with a fake
/// clock and fake "encoded" segment files, and checks what lands on disk.
final class CaptureSessionTests: XCTestCase {
    private var root: URL!
    private var store: SessionStore!
    private let clock = TestClock()
    private let metrics = TestMetrics()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coach-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SessionStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeController(_ mutate: (inout CaptureSettings) -> Void = { _ in }) throws -> CaptureSessionController {
        var settings = CaptureSettings.default
        settings.rollingBufferSeconds = 30
        settings.segmentSeconds = 5
        mutate(&settings)
        let controller = CaptureSessionController(
            store: store, gameID: "fortnite",
            source: CaptureSourceInfo(platform: "test", mechanism: "unit-test"),
            settings: settings, now: { [clock] in clock.now },
            metricsSampler: { [metrics] in metrics.next() },
            hostClock: { [clock] in clock.host }
        )
        try controller.start()
        return controller
    }

    /// Simulates `seconds` of 30 fps capture starting at PTS 1000, writing a
    /// fake file for each finished segment like SegmentWriter would.
    private func simulate(_ controller: CaptureSessionController, seconds: Double, fps: Double = 30, startPTS: Double = 1000) throws {
        let frames = Int(seconds * fps)
        var segment = controller.nextSegmentFile()
        var segmentStart = startPTS
        var segmentFrames = 0
        for i in 0..<frames {
            let pts = startPTS + Double(i) / fps
            clock.now = Date(timeIntervalSince1970: 1_000_000 + Double(i) / fps)
            if pts - segmentStart >= controller.settings.segmentSeconds {
                try finishSegment(controller, segment, start: segmentStart, end: pts, frames: segmentFrames)
                segment = controller.nextSegmentFile()
                segmentStart = pts
                segmentFrames = 0
            }
            let decision = controller.videoFrame(pts: pts, width: 1920, height: 886, orientation: 1)
            controller.frameEncoded()
            segmentFrames += 1
            if decision.analyze {
                controller.analysisCompleted(frameIndex: decision.frameIndex, sessionTime: decision.sessionTime, duration: 0.004, luma: 0.4)
            }
            if let reason = decision.keyframe {
                let file = controller.keyframeFile(frameIndex: decision.frameIndex)
                try Data([0xFF, 0xD8]).write(to: file.url)
                controller.keyframeSaved(KeyframeRecord(id: file.id, frameIndex: decision.frameIndex, timestamp: decision.sessionTime,
                                                        reason: reason, fileName: file.fileName, width: 960, height: 443, byteCount: 2))
            }
            if i % 2 == 0 { controller.audioSample(.app) }
        }
        try finishSegment(controller, segment, start: segmentStart, end: startPTS + seconds, frames: segmentFrames)
    }

    private func finishSegment(_ controller: CaptureSessionController, _ file: (id: Int, fileName: String, url: URL), start: Double, end: Double, frames: Int) throws {
        try Data(count: 100).write(to: file.url)
        controller.segmentFinished(id: file.id, fileName: file.fileName, startPTS: start, endPTS: end, frameCount: frames, byteCount: 100)
    }

    func testEndToEndSessionSummary() throws {
        let controller = try makeController()
        try simulate(controller, seconds: 60)
        let manifest = controller.finish()

        let stats = manifest.statistics
        XCTAssertEqual(manifest.status, .finished)
        XCTAssertEqual(stats.videoFramesReceived, 1800)
        XCTAssertEqual(stats.framesAnalyzed, 600, "10 fps analysis of 30 fps input")
        XCTAssertEqual(stats.framesSkippedByThrottle, 1200)
        XCTAssertEqual(stats.keyframesSaved, 12, "session start + every 5 s over 60 s")
        XCTAssertEqual(stats.droppedFrames, 0)
        XCTAssertEqual(stats.audioAppSamples, 900)
        XCTAssertEqual(stats.averageProcessingFPS, 10, accuracy: 0.2)
        XCTAssertEqual(stats.segmentsWritten, 12)
        XCTAssertEqual(stats.rollingBufferSeconds, 30, accuracy: 0.01)

        // Only the last 30 s of video remain on disk.
        let dir = controller.directory
        let segmentFiles = try FileManager.default.contentsOfDirectory(atPath: dir.segmentsURL.path).sorted()
        XCTAssertEqual(segmentFiles.count, 6)
        XCTAssertEqual(segmentFiles.first, "seg-00007.mp4")

        // The app reads the same session back from disk.
        let reloaded = try store.manifest(for: controller.sessionID)
        XCTAssertEqual(reloaded.statistics, stats)
        XCTAssertEqual(store.keyframes(for: controller.sessionID).count, 12)
        let events = store.events(for: controller.sessionID)
        XCTAssertEqual(events.first?.type, .captureStarted)
        XCTAssertEqual(events.last?.type, .captureFinished)
        XCTAssertEqual(events.last?.metadata["framesReceived"], "1800")
    }

    func testPreservedClipSurvivesEviction() throws {
        let controller = try makeController()
        try simulate(controller, seconds: 20)
        controller.preserveClip(reason: "test-event", around: 18, before: 15, after: 10)
        try simulate(controller, seconds: 60, startPTS: 1020)
        let manifest = controller.finish()

        let clip = try XCTUnwrap(manifest.preservedClips.first)
        XCTAssertEqual(clip.reason, "test-event")
        XCTAssertEqual(clip.coveredFrom, 0)
        XCTAssertEqual(clip.coveredTo ?? 0, 30, accuracy: 0.01)
        for name in clip.segmentFileNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: controller.directory.preservedURL(name).path), name)
        }
        // seg-00001 was evicted from the rolling window but kept as part of the clip.
        XCTAssertFalse(FileManager.default.fileExists(atPath: controller.directory.segmentURL("seg-00001.mp4").path))
        XCTAssertTrue(store.events(for: controller.sessionID).contains { $0.type == .clipPreserved })
    }

    func testDontSaveVideoPurgesVideoButKeepsEventsAndMetrics() throws {
        let controller = try makeController { $0.dontSaveVideo = true; $0.keepKeyframes = false }
        try simulate(controller, seconds: 20)
        controller.preserveClip(reason: "x", around: 10, before: 5, after: 5)
        let manifest = controller.finish()

        XCTAssertTrue(manifest.videoPurged)
        XCTAssertTrue(manifest.keyframesPurged)
        XCTAssertTrue(manifest.bufferedSegments.isEmpty)
        let dir = controller.directory
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.segmentsURL.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.preservedURL.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.keyframesURL.path), [])
        XCTAssertEqual(store.events(for: controller.sessionID).last?.type, .captureFinished)
        XCTAssertEqual(try store.manifest(for: controller.sessionID).statistics.videoFramesReceived, 600)
    }

    func testDropsAreCountedPerReason() throws {
        let controller = try makeController()
        _ = controller.videoFrame(pts: 0, width: 10, height: 10, orientation: 1)
        controller.frameDropped(.encoderNotReady)
        controller.frameDropped(.encoderNotReady)
        controller.frameDropped(.analysisBusy)
        let stats = controller.finish().statistics
        XCTAssertEqual(stats.droppedFrames, 3)
        XCTAssertEqual(stats.dropCount(.encoderNotReady), 2)
    }

    func testPauseIsExcludedFromAverages() throws {
        let controller = try makeController()
        try simulate(controller, seconds: 10)
        controller.pause()
        clock.now = clock.now.addingTimeInterval(5)
        controller.resume()
        let stats = controller.finish().statistics
        XCTAssertEqual(stats.pausedDuration, 5, accuracy: 0.01)
        XCTAssertTrue(store.events(for: controller.sessionID).contains { $0.type == .capturePaused })
    }

    func testFormatChangeAndMemoryPressureEvents() throws {
        let controller = try makeController()
        _ = controller.videoFrame(pts: 0, width: 1179, height: 2556, orientation: 6)
        _ = controller.videoFrame(pts: 0.1, width: 2556, height: 1179, orientation: 1)
        controller.updateMemory(availableBytes: 8 * 1024 * 1024)
        controller.updateMemory(availableBytes: 7 * 1024 * 1024)
        controller.finish()
        let types = store.events(for: controller.sessionID).map(\.type)
        XCTAssertEqual(types.filter { $0 == .videoFormatChanged }.count, 1)
        XCTAssertEqual(types.filter { $0 == .memoryPressure }.count, 1)
    }

    func testDeleteSessionAndDeleteAll() throws {
        let a = try makeController()
        a.finish()
        let b = try makeController()
        b.finish()
        XCTAssertEqual(store.allManifests().count, 2)
        try store.deleteSession(a.sessionID)
        XCTAssertEqual(store.allManifests().map(\.id), [b.sessionID])
        try store.deleteAll()
        XCTAssertTrue(store.allManifests().isEmpty)
    }

    func testTornTrailingLineIsIgnored() throws {
        let controller = try makeController()
        controller.finish()
        let handle = try FileHandle(forWritingTo: controller.directory.eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"trunc".utf8))
        try handle.close()
        XCTAssertEqual(store.events(for: controller.sessionID).count, 2)
    }
}

final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    /// Host clock for latency; nil = not measurable.
    var host: Double?
}

final class TestMetrics: @unchecked Sendable {
    var samples: [ProcessMetricsSample] = []
    func next() -> ProcessMetricsSample {
        samples.isEmpty ? ProcessMetricsSample() : samples.removeFirst()
    }
}
