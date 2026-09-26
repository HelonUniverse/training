import Foundation

/// Decides which incoming frames go to analysis. The screen source may
/// deliver 30–60 fps; vision only needs a fraction of that. Driven by
/// presentation timestamps, not wall clock, so it is deterministic in tests.
public struct FrameGate: Sendable {
    public let minimumInterval: Double
    private var lastAccepted: Double?

    public init(targetFPS: Double) {
        minimumInterval = targetFPS > 0 ? 1 / targetFPS : 0
    }

    public mutating func shouldAccept(at time: Double) -> Bool {
        guard let last = lastAccepted else {
            lastAccepted = time
            return true
        }
        // A timestamp that jumps backwards means the source restarted its
        // clock (for example after pause/resume); start over rather than
        // starving analysis until the old time is reached again.
        if time < last {
            lastAccepted = time
            return true
        }
        // Small tolerance so 30 fps input at a 10 fps target yields every
        // third frame instead of drifting because of timestamp jitter.
        if time - last >= minimumInterval * 0.95 {
            lastAccepted = time
            return true
        }
        return false
    }
}

public struct KeyframeReason: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let sessionStart: KeyframeReason = "sessionStart"
    public static let periodic: KeyframeReason = "periodic"
    public static func event(_ type: MatchEventType) -> KeyframeReason {
        KeyframeReason(rawValue: "event:\(type.rawValue)")
    }
}

/// Periodic keyframes plus on-demand ones requested by events. Event
/// requests are rate limited so a burst of detections cannot flood storage.
public struct KeyframeScheduler: Sendable {
    public let interval: Double
    public let minimumEventSpacing: Double
    private var lastPeriodic: Double?
    private var lastAny: Double?
    private var pending: KeyframeReason?

    public init(interval: Double, minimumEventSpacing: Double = 0.5) {
        self.interval = interval
        self.minimumEventSpacing = minimumEventSpacing
    }

    /// Ask for a keyframe on the next frame (for example on an event).
    public mutating func request(_ reason: KeyframeReason) {
        pending = reason
    }

    /// Call once per incoming video frame.
    public mutating func reason(at time: Double) -> KeyframeReason? {
        if lastPeriodic == nil {
            lastPeriodic = time
            lastAny = time
            pending = nil
            return .sessionStart
        }
        if let reason = pending, time - (lastAny ?? -.infinity) >= minimumEventSpacing {
            pending = nil
            lastAny = time
            return reason
        }
        if let last = lastPeriodic, time - last >= interval || time < last {
            lastPeriodic = time
            lastAny = time
            return .periodic
        }
        return nil
    }
}
