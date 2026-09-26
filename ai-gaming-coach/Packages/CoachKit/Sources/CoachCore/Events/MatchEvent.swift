import Foundation

/// Open set of event types. Game adapters can declare their own types
/// (`MatchEventType("fortnite.stormPhase")`) without touching the core engine.
public struct MatchEventType: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

// MARK: - Capture pipeline events (emitted by the pipeline, not by vision)

public extension MatchEventType {
    static let captureStarted: MatchEventType = "captureStarted"
    static let capturePaused: MatchEventType = "capturePaused"
    static let captureResumed: MatchEventType = "captureResumed"
    static let captureFinished: MatchEventType = "captureFinished"
    static let captureFailed: MatchEventType = "captureFailed"
    static let videoFormatChanged: MatchEventType = "videoFormatChanged"
    static let clipPreserved: MatchEventType = "clipPreserved"
    static let memoryPressure: MatchEventType = "memoryPressure"
}

// MARK: - Gameplay events (produced by game adapters from Milestone 2 onward)

public extension MatchEventType {
    static let matchStarted: MatchEventType = "matchStarted"
    static let matchEnded: MatchEventType = "matchEnded"
    static let enemyDetected: MatchEventType = "enemyDetected"
    static let weaponSelected: MatchEventType = "weaponSelected"
    static let weaponChanged: MatchEventType = "weaponChanged"
    static let shotFired: MatchEventType = "shotFired"
    static let reloadStarted: MatchEventType = "reloadStarted"
    static let reloadCompleted: MatchEventType = "reloadCompleted"
    static let damageReceived: MatchEventType = "damageReceived"
    static let damageDealt: MatchEventType = "damageDealt"
    static let shieldChanged: MatchEventType = "shieldChanged"
    static let healthChanged: MatchEventType = "healthChanged"
    static let healStarted: MatchEventType = "healStarted"
    static let healCompleted: MatchEventType = "healCompleted"
    static let fightStarted: MatchEventType = "fightStarted"
    static let fightEnded: MatchEventType = "fightEnded"
    static let elimination: MatchEventType = "elimination"
    static let playerDeath: MatchEventType = "playerDeath"
    static let inventoryChanged: MatchEventType = "inventoryChanged"
    static let stormEvent: MatchEventType = "stormEvent"
    static let movementEvent: MatchEventType = "movementEvent"
    static let unknownImportantEvent: MatchEventType = "unknownImportantEvent"
}

/// Who produced an event. Lets the coach separate facts the pipeline knows
/// for certain (capture started) from visual inferences (enemy detected).
public enum EventOrigin: String, Codable, Sendable {
    case pipeline
    case vision
    case reasoning
    case user
}

/// One entry in the match timeline. `timestamp` is seconds since the first
/// video frame of the session, so it is independent of the capture source.
public struct MatchEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Double
    public var wallClock: Date
    public var type: MatchEventType
    public var confidence: Double
    public var origin: EventOrigin
    public var metadata: [String: String]
    public var relatedFrameIDs: [Int64]
    public var relatedKeyframeIDs: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Double,
        wallClock: Date = Date(),
        type: MatchEventType,
        confidence: Double,
        origin: EventOrigin,
        metadata: [String: String] = [:],
        relatedFrameIDs: [Int64] = [],
        relatedKeyframeIDs: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.wallClock = wallClock
        self.type = type
        self.confidence = min(max(confidence, 0), 1)
        self.origin = origin
        self.metadata = metadata
        self.relatedFrameIDs = relatedFrameIDs
        self.relatedKeyframeIDs = relatedKeyframeIDs
    }
}

public enum SessionTimeFormatter {
    /// `802.02` → `"13:22.020"`. Used by the debug timeline.
    public static func string(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let minutes = totalMillis / 60_000
        let secs = (totalMillis / 1000) % 60
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d.%03d", minutes, secs, millis)
    }

    /// `125` → `"2m 05s"`.
    public static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total >= 3600 {
            return String(format: "%dh %02dm %02ds", total / 3600, (total / 60) % 60, total % 60)
        }
        return String(format: "%dm %02ds", total / 60, total % 60)
    }
}
