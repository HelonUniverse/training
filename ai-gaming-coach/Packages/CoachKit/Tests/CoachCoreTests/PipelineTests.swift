import XCTest
@testable import CoachCore

final class FrameGateTests: XCTestCase {
    func testThirtyFPSInputAtTenFPSTargetKeepsEveryThirdFrame() {
        var gate = FrameGate(targetFPS: 10)
        let accepted = (0..<30).filter { gate.shouldAccept(at: Double($0) / 30) }
        XCTAssertEqual(accepted, Array(stride(from: 0, to: 30, by: 3)))
    }

    func testBackwardsTimestampRestartsGate() {
        var gate = FrameGate(targetFPS: 1)
        XCTAssertTrue(gate.shouldAccept(at: 100))
        XCTAssertFalse(gate.shouldAccept(at: 100.5))
        XCTAssertTrue(gate.shouldAccept(at: 3))
    }
}

final class KeyframeSchedulerTests: XCTestCase {
    func testFirstFrameThenPeriodic() {
        var scheduler = KeyframeScheduler(interval: 5)
        XCTAssertEqual(scheduler.reason(at: 0), .sessionStart)
        XCTAssertNil(scheduler.reason(at: 4.9))
        XCTAssertEqual(scheduler.reason(at: 5), .periodic)
        XCTAssertNil(scheduler.reason(at: 6))
    }

    func testEventRequestsAreRateLimited() {
        var scheduler = KeyframeScheduler(interval: 60, minimumEventSpacing: 0.5)
        _ = scheduler.reason(at: 0)
        scheduler.request(.event(.fightStarted))
        XCTAssertNil(scheduler.reason(at: 0.2), "too close to the previous keyframe")
        XCTAssertEqual(scheduler.reason(at: 0.6), .event(.fightStarted))
        XCTAssertNil(scheduler.reason(at: 0.7))
    }
}

final class RateMeterTests: XCTestCase {
    func testRateOverOneSecondWindow() {
        var meter = RateMeter(window: 1)
        for i in 0..<120 { meter.record(at: Double(i) / 60) }
        XCTAssertEqual(meter.rate(at: 119.0 / 60), 60, accuracy: 1)
    }
}

final class RollingSegmentBufferTests: XCTestCase {
    private func segment(_ id: Int, length: Double = 5) -> VideoSegment {
        VideoSegment(id: id, fileName: "seg-\(id).mp4", start: Double(id) * length, end: Double(id + 1) * length, frameCount: 150, byteCount: 1000)
    }

    func testKeepsAtLeastCapacityAndEvictsOldest() {
        var buffer = RollingSegmentBuffer(capacity: 60)
        var evicted: [Int] = []
        for id in 0..<20 { evicted += buffer.append(segment(id)).evicted.map(\.id) }
        XCTAssertEqual(buffer.bufferedDuration, 60)
        XCTAssertEqual(buffer.segments.map(\.id), Array(8..<20))
        XCTAssertEqual(evicted, Array(0..<8))
    }

    func testPreserveCoversPastAndFutureSegments() {
        var buffer = RollingSegmentBuffer(capacity: 30)
        for id in 0..<6 { _ = buffer.append(segment(id)) } // 0–30 s
        // Event at 22 s: keep 15 s before and 10 s after → 7…32 s.
        let request = ClipRequest(reason: "fight", from: 7, to: 32)
        let immediate = buffer.preserve(request)
        XCTAssertEqual(immediate.toPreserve.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertTrue(immediate.completedClips.isEmpty)

        let next = buffer.append(segment(6)) // 30–35 s completes the clip
        XCTAssertEqual(next.toPreserve.map(\.id), [6])
        XCTAssertEqual(next.completedClips.count, 1)
        XCTAssertEqual(next.completedClips[0].segmentFileNames, ["seg-1.mp4", "seg-2.mp4", "seg-3.mp4", "seg-4.mp4", "seg-5.mp4", "seg-6.mp4"])
        XCTAssertEqual(next.completedClips[0].coveredFrom, 5)
        XCTAssertEqual(next.completedClips[0].coveredTo, 35)
        XCTAssertTrue(buffer.openRequests.isEmpty)
    }

    func testOverlappingRequestsPreserveEachSegmentOnce() {
        var buffer = RollingSegmentBuffer(capacity: 30)
        for id in 0..<4 { _ = buffer.append(segment(id)) }
        let a = buffer.preserve(ClipRequest(reason: "a", from: 0, to: 12))
        let b = buffer.preserve(ClipRequest(reason: "b", from: 8, to: 18))
        XCTAssertEqual(a.toPreserve.map(\.id), [0, 1, 2])
        XCTAssertEqual(b.toPreserve.map(\.id), [3])
        XCTAssertEqual(a.completedClips.count, 1)
        XCTAssertEqual(b.completedClips.first?.segmentFileNames, ["seg-1.mp4", "seg-2.mp4", "seg-3.mp4"])
    }

    func testCloseAllRequestsReturnsPartialClip() {
        var buffer = RollingSegmentBuffer(capacity: 30)
        _ = buffer.append(segment(0))
        _ = buffer.preserve(ClipRequest(reason: "death", from: 0, to: 100))
        let clips = buffer.closeAllRequests()
        XCTAssertEqual(clips.first?.segmentFileNames, ["seg-0.mp4"])
        XCTAssertTrue(buffer.openRequests.isEmpty)
    }
}

final class FormattingTests: XCTestCase {
    func testTimelineFormat() {
        XCTAssertEqual(SessionTimeFormatter.string(802.02), "13:22.020")
        XCTAssertEqual(SessionTimeFormatter.string(0), "00:00.000")
        XCTAssertEqual(SessionTimeFormatter.duration(125), "2m 05s")
    }

    func testSettingsAreClamped() {
        var settings = CaptureSettings.default
        settings.rollingBufferSeconds = 10_000
        settings.analysisFPS = 0
        let clean = settings.sanitized()
        XCTAssertEqual(clean.rollingBufferSeconds, 300)
        XCTAssertEqual(clean.analysisFPS, 1)
    }

    func testEventTypeRoundTripsAsPlainString() throws {
        let event = MatchEvent(timestamp: 1, type: .weaponChanged, confidence: 0.98, origin: .vision, metadata: ["from": "1", "to": "2"])
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\":\"weaponChanged\""))
        let decoded = try JSONDecoder().decode(MatchEvent.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.type, .weaponChanged)
    }
}
