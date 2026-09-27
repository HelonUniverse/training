import Foundation

/// User-tunable pipeline settings. The main app writes them to the shared
/// App Group defaults; the capture process reads a snapshot when a session
/// starts, so a session is never reconfigured mid-flight.
public struct CaptureSettings: Codable, Hashable, Sendable {
    /// Seconds of recent gameplay kept in the rolling video buffer.
    public var rollingBufferSeconds: Double
    /// Length of each encoded segment. Eviction happens a segment at a time.
    public var segmentSeconds: Double
    /// Frames per second handed to analysis (vision). Encoding is separate.
    public var analysisFPS: Double
    /// Seconds between periodic keyframes.
    public var keyframeIntervalSeconds: Double
    public var keyframeMaxDimension: Int
    public var keyframeJPEGQuality: Double
    public var videoMaxDimension: Int
    public var videoBitrate: Int
    /// "Don't Save Video": rolling video is deleted when the session ends.
    public var dontSaveVideo: Bool
    /// Keep keyframes after the session ends.
    public var keepKeyframes: Bool
    /// Keep the whole match on disk (up to `fullMatchMaxSeconds`) instead of
    /// only the rolling window, so the match can be analysed afterwards.
    public var keepFullMatchVideo: Bool

    public static let fullMatchMaxSeconds: Double = 3600

    /// Seconds of video the buffer keeps before evicting.
    public var effectiveBufferSeconds: Double {
        keepFullMatchVideo ? Self.fullMatchMaxSeconds : rollingBufferSeconds
    }

    public static let rollingBufferRange: ClosedRange<Double> = 30...300
    public static let analysisFPSRange: ClosedRange<Double> = 1...30
    public static let keyframeIntervalRange: ClosedRange<Double> = 1...60

    public static let `default` = CaptureSettings(
        rollingBufferSeconds: 90,
        segmentSeconds: 5,
        analysisFPS: 10,
        keyframeIntervalSeconds: 5,
        keyframeMaxDimension: 960,
        keyframeJPEGQuality: 0.7,
        videoMaxDimension: 1280,
        videoBitrate: 2_000_000,
        dontSaveVideo: false,
        keepKeyframes: true,
        keepFullMatchVideo: true
    )

    public init(
        rollingBufferSeconds: Double,
        segmentSeconds: Double,
        analysisFPS: Double,
        keyframeIntervalSeconds: Double,
        keyframeMaxDimension: Int,
        keyframeJPEGQuality: Double,
        videoMaxDimension: Int,
        videoBitrate: Int,
        dontSaveVideo: Bool,
        keepKeyframes: Bool,
        keepFullMatchVideo: Bool = true
    ) {
        self.rollingBufferSeconds = rollingBufferSeconds
        self.segmentSeconds = segmentSeconds
        self.analysisFPS = analysisFPS
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.keyframeMaxDimension = keyframeMaxDimension
        self.keyframeJPEGQuality = keyframeJPEGQuality
        self.videoMaxDimension = videoMaxDimension
        self.videoBitrate = videoBitrate
        self.dontSaveVideo = dontSaveVideo
        self.keepFullMatchVideo = keepFullMatchVideo
        self.keepKeyframes = keepKeyframes
    }

    /// Clamps values a corrupted or hand-edited defaults entry could break.
    public func sanitized() -> CaptureSettings {
        var copy = self
        copy.rollingBufferSeconds = rollingBufferSeconds.clamped(to: Self.rollingBufferRange)
        copy.segmentSeconds = segmentSeconds.clamped(to: 1...15)
        copy.analysisFPS = analysisFPS.clamped(to: Self.analysisFPSRange)
        copy.keyframeIntervalSeconds = keyframeIntervalSeconds.clamped(to: Self.keyframeIntervalRange)
        copy.keyframeMaxDimension = keyframeMaxDimension.clamped(to: 240...2048)
        copy.keyframeJPEGQuality = keyframeJPEGQuality.clamped(to: 0.3...0.95)
        copy.videoMaxDimension = videoMaxDimension.clamped(to: 480...2560)
        copy.videoBitrate = videoBitrate.clamped(to: 500_000...20_000_000)
        return copy
    }
}

/// Persists `CaptureSettings` in a `UserDefaults` suite (the App Group suite
/// on iOS). JSON-encoded under one key so both processes agree on the shape.
public struct CaptureSettingsStore {
    public static let key = "coach.captureSettings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> CaptureSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(CaptureSettings.self, from: data)
        else { return .default }
        return settings.sanitized()
    }

    public func save(_ settings: CaptureSettings) {
        guard let data = try? JSONEncoder().encode(settings.sanitized()) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CaptureSettings {
    private enum CodingKeys: String, CodingKey {
        case rollingBufferSeconds, segmentSeconds, analysisFPS, keyframeIntervalSeconds, keyframeMaxDimension
        case keyframeJPEGQuality, videoMaxDimension, videoBitrate, dontSaveVideo, keepKeyframes, keepFullMatchVideo
    }

    /// Settings saved by earlier builds lack `keepFullMatchVideo`; they
    /// decode with the new default instead of failing (which would drop
    /// the user's settings and make old session manifests unreadable).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            rollingBufferSeconds: try c.decode(Double.self, forKey: .rollingBufferSeconds),
            segmentSeconds: try c.decode(Double.self, forKey: .segmentSeconds),
            analysisFPS: try c.decode(Double.self, forKey: .analysisFPS),
            keyframeIntervalSeconds: try c.decode(Double.self, forKey: .keyframeIntervalSeconds),
            keyframeMaxDimension: try c.decode(Int.self, forKey: .keyframeMaxDimension),
            keyframeJPEGQuality: try c.decode(Double.self, forKey: .keyframeJPEGQuality),
            videoMaxDimension: try c.decode(Int.self, forKey: .videoMaxDimension),
            videoBitrate: try c.decode(Int.self, forKey: .videoBitrate),
            dontSaveVideo: try c.decode(Bool.self, forKey: .dontSaveVideo),
            keepKeyframes: try c.decode(Bool.self, forKey: .keepKeyframes),
            keepFullMatchVideo: try c.decodeIfPresent(Bool.self, forKey: .keepFullMatchVideo) ?? true
        )
    }
}
