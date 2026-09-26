import Foundation

/// Why a frame did not make it through a stage. Frames skipped on purpose
/// by the analysis throttle are counted separately and are not drops.
public enum FrameDropReason: String, Codable, CaseIterable, Sendable {
    /// The buffer had no image or its data was not ready.
    case invalidBuffer
    /// The encoder was not ready; the frame is missing from the rolling video.
    case encoderNotReady
    /// The encoder rejected the frame.
    case encoderFailed
    /// Analysis of the previous frame was still running.
    case analysisBusy
    /// Too many keyframes were already being encoded.
    case keyframeBusy
}

public enum AudioSourceKind: String, Codable, Sendable {
    case app
    case microphone
}

/// Counters for one capture session. Everything the Session Summary and the
/// Debug screen show comes from here.
public struct SessionStatistics: Codable, Hashable, Sendable {
    public var videoFramesReceived: Int64 = 0
    public var framesAnalyzed: Int64 = 0
    public var framesSkippedByThrottle: Int64 = 0
    public var framesEncoded: Int64 = 0
    public var drops: [String: Int64] = [:]
    public var audioAppSamples: Int64 = 0
    public var audioMicSamples: Int64 = 0
    public var keyframesSaved: Int64 = 0
    public var segmentsWritten: Int64 = 0
    public var segmentsEvicted: Int64 = 0
    public var bytesEncoded: Int64 = 0
    /// Seconds from the first to the latest video frame (source clock).
    public var mediaDuration: Double = 0
    /// Seconds spent paused, excluded from averages.
    public var pausedDuration: Double = 0
    public var totalAnalysisSeconds: Double = 0
    public var maxAnalysisSeconds: Double = 0
    public var receivedFPS: Double = 0
    public var analyzedFPS: Double = 0
    public var videoWidth: Int = 0
    public var videoHeight: Int = 0
    /// EXIF-style orientation (1 = up, 6 = right, 8 = left, 3 = down).
    public var videoOrientation: Int = 1
    public var lastFrameLuma: Double?
    /// Frames whose sampled luminance is ~0. A stream of black frames usually
    /// means the source app or the system is blanking protected content.
    public var nearBlackFrames: Int64 = 0
    public var memoryAvailableBytes: Int64?
    public var minimumMemoryAvailableBytes: Int64?
    public var rollingBufferSeconds: Double = 0
    public var rollingBufferSegments: Int = 0
    /// Failed writes to the shared container (disk full, container missing).
    public var storageErrors: Int64 = 0

    public init() {}

    public var droppedFrames: Int64 { drops.values.reduce(0, +) }

    public func dropCount(_ reason: FrameDropReason) -> Int64 { drops[reason.rawValue] ?? 0 }

    public var activeDuration: Double { max(0, mediaDuration - pausedDuration) }

    /// Frames that completed analysis per second of active capture.
    public var averageProcessingFPS: Double {
        activeDuration > 0 ? Double(framesAnalyzed) / activeDuration : 0
    }

    public var averageReceivedFPS: Double {
        activeDuration > 0 ? Double(videoFramesReceived) / activeDuration : 0
    }

    public var averageAnalysisMilliseconds: Double {
        framesAnalyzed > 0 ? totalAnalysisSeconds / Double(framesAnalyzed) * 1000 : 0
    }
}

/// Events-per-second over a sliding window, keyed on media time.
public struct RateMeter: Sendable {
    public let window: Double
    private var times: [Double] = []
    private var head = 0

    public init(window: Double = 1) {
        self.window = window
    }

    public mutating func record(at time: Double) {
        if let last = times.last, time < last { reset() }
        times.append(time)
        trim(now: time)
    }

    public func rate(at now: Double) -> Double {
        guard window > 0 else { return 0 }
        let count = times[head...].reduce(into: 0) { acc, t in if now - t < window { acc += 1 } }
        return Double(count) / window
    }

    private mutating func reset() {
        times.removeAll(keepingCapacity: true)
        head = 0
    }

    private mutating func trim(now: Double) {
        while head < times.count, now - times[head] >= window { head += 1 }
        // Compact occasionally so the array does not grow for a whole match.
        if head > 256 {
            times.removeFirst(head)
            head = 0
        }
    }
}
