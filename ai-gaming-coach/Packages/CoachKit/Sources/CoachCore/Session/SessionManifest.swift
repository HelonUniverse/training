import Foundation

/// Describes where frames came from, so analysis never has to assume iOS.
public struct CaptureSourceInfo: Codable, Hashable, Sendable {
    /// "iOS", "Android", "Windows", "PlayStation", …
    public var platform: String
    /// e.g. "ReplayKit.BroadcastUploadExtension".
    public var mechanism: String
    public var deviceModel: String?
    public var osVersion: String?
    public var appVersion: String?

    public init(platform: String, mechanism: String, deviceModel: String? = nil, osVersion: String? = nil, appVersion: String? = nil) {
        self.platform = platform
        self.mechanism = mechanism
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case paused
    case finished
    case failed
}

public struct KeyframeRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var frameIndex: Int64
    public var timestamp: Double
    public var reason: KeyframeReason
    public var fileName: String
    public var width: Int
    public var height: Int
    public var byteCount: Int64

    public init(id: String, frameIndex: Int64, timestamp: Double, reason: KeyframeReason, fileName: String, width: Int, height: Int, byteCount: Int64) {
        self.id = id
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.reason = reason
        self.fileName = fileName
        self.width = width
        self.height = height
        self.byteCount = byteCount
    }
}

/// The session's single source of truth, rewritten atomically about once a
/// second while capture runs. The main app treats `updatedAt` as the
/// heartbeat that proves the capture process is alive.
public struct SessionManifest: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var gameID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var failureReason: String?
    public var source: CaptureSourceInfo
    public var settings: CaptureSettings
    public var statistics: SessionStatistics
    /// Rolling video currently on disk, oldest first.
    public var bufferedSegments: [VideoSegment]
    public var preservedClips: [PreservedClip]
    public var eventCount: Int
    /// True once video files were removed under "Don't Save Video" or by the user.
    public var videoPurged: Bool
    public var keyframesPurged: Bool

    public init(id: UUID = UUID(), gameID: String, createdAt: Date, source: CaptureSourceInfo, settings: CaptureSettings) {
        self.id = id
        self.gameID = gameID
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = .running
        self.source = source
        self.settings = settings
        self.statistics = SessionStatistics()
        self.bufferedSegments = []
        self.preservedClips = []
        self.eventCount = 0
        self.videoPurged = false
        self.keyframesPurged = false
    }

    /// Wall-clock duration of the session.
    public func wallDuration(now: Date = Date()) -> Double {
        (endedAt ?? (status == .running || status == .paused ? now : updatedAt)).timeIntervalSince(createdAt)
    }

    /// Whether the capture process wrote recently enough to be alive.
    public func isLive(now: Date = Date(), tolerance: Double = 4) -> Bool {
        (status == .running || status == .paused) && now.timeIntervalSince(updatedAt) <= tolerance
    }
}
