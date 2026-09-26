import AVFoundation
import CoreMedia
import ImageIO

/// Rolling-buffer encoder. Writes the broadcast as a chain of short,
/// independently playable H.264 MP4 files (default 5 s). The next segment
/// starts on the frame that closes the previous one, so segments are
/// contiguous. Pixels go straight from ReplayKit to the hardware encoder;
/// nothing is copied or accumulated in RAM.
///
/// Called only from the ReplayKit sample-handler thread (serial), except for
/// `finishWriting` completions, which report through `onFinished`.
final class SegmentWriter {
    struct Configuration {
        var segmentSeconds: Double
        var maxDimension: Int
        var bitrate: Int
    }

    struct FinishedSegment {
        var id: Int
        var fileName: String
        var startPTS: Double
        var endPTS: Double
        var frameCount: Int
        var byteCount: Int64
    }

    enum AppendResult {
        case appended
        case notReady
        case failed
    }

    enum WriterError: LocalizedError {
        case cannotAddInput
        case cannotStart(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "The video encoder rejected the output settings."
            case .cannotStart(let error): return "The video encoder failed to start: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    private final class Segment {
        let id: Int
        let fileName: String
        let url: URL
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let startPTS: CMTime
        let width: Int
        let height: Int
        let orientation: CGImagePropertyOrientation
        var lastPTS: CMTime
        var frameCount = 0

        init(id: Int, fileName: String, url: URL, writer: AVAssetWriter, input: AVAssetWriterInput,
             startPTS: CMTime, width: Int, height: Int, orientation: CGImagePropertyOrientation) {
            self.id = id
            self.fileName = fileName
            self.url = url
            self.writer = writer
            self.input = input
            self.startPTS = startPTS
            self.width = width
            self.height = height
            self.orientation = orientation
            self.lastPTS = startPTS
        }
    }

    private let configuration: Configuration
    private let makeFile: () -> (id: Int, fileName: String, url: URL)
    private let onFinished: (FinishedSegment) -> Void
    private let onError: (Error) -> Void
    private let pending = DispatchGroup()
    private var current: Segment?

    init(
        configuration: Configuration,
        makeFile: @escaping () -> (id: Int, fileName: String, url: URL),
        onFinished: @escaping (FinishedSegment) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.configuration = configuration
        self.makeFile = makeFile
        self.onFinished = onFinished
        self.onError = onError
    }

    func append(_ sampleBuffer: CMSampleBuffer, width: Int, height: Int, orientation: CGImagePropertyOrientation) -> AppendResult {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if let segment = current {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, segment.startPTS))
            let formatChanged = segment.width != width || segment.height != height || segment.orientation != orientation
            if elapsed >= configuration.segmentSeconds || elapsed < 0 || formatChanged || segment.writer.status == .failed {
                close(segment, at: elapsed < 0 ? segment.lastPTS : pts)
                current = nil
            }
        }

        if current == nil {
            do {
                current = try startSegment(at: pts, sampleBuffer: sampleBuffer, width: width, height: height, orientation: orientation)
            } catch {
                onError(error)
                return .failed
            }
        }
        guard let segment = current else { return .failed }
        guard segment.input.isReadyForMoreMediaData else { return .notReady }
        guard segment.input.append(sampleBuffer) else {
            onError(segment.writer.error ?? WriterError.cannotStart(nil))
            segment.writer.cancelWriting()
            try? FileManager.default.removeItem(at: segment.url)
            current = nil
            return .failed
        }
        segment.lastPTS = pts
        segment.frameCount += 1
        return .appended
    }

    /// Closes the open segment and waits (bounded) for every pending file to
    /// finalize. Used when the broadcast ends, before the process exits.
    func finishAll(timeout: TimeInterval) {
        if let segment = current {
            close(segment, at: segment.lastPTS)
            current = nil
        }
        _ = pending.wait(timeout: .now() + timeout)
    }

    private func startSegment(at pts: CMTime, sampleBuffer: CMSampleBuffer, width: Int, height: Int,
                              orientation: CGImagePropertyOrientation) throws -> Segment {
        let file = makeFile()
        try? FileManager.default.removeItem(at: file.url)
        let writer = try AVAssetWriter(outputURL: file.url, fileType: .mp4)

        var settings = Self.outputSettings(width: width, height: height, configuration: configuration, scaled: true)
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings = Self.outputSettings(width: width, height: height, configuration: configuration, scaled: false)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings,
                                       sourceFormatHint: CMSampleBufferGetFormatDescription(sampleBuffer))
        input.expectsMediaDataInRealTime = true
        input.transform = Self.transform(for: orientation)
        guard writer.canAdd(input) else { throw WriterError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw WriterError.cannotStart(writer.error) }
        writer.startSession(atSourceTime: pts)
        return Segment(id: file.id, fileName: file.fileName, url: file.url, writer: writer, input: input,
                       startPTS: pts, width: width, height: height, orientation: orientation)
    }

    private func close(_ segment: Segment, at endPTS: CMTime) {
        segment.input.markAsFinished()
        guard segment.frameCount > 0, segment.writer.status == .writing else {
            segment.writer.cancelWriting()
            try? FileManager.default.removeItem(at: segment.url)
            return
        }
        if CMTimeCompare(endPTS, segment.startPTS) > 0 {
            segment.writer.endSession(atSourceTime: endPTS)
        }
        pending.enter()
        let onFinished = onFinished
        let onError = onError
        segment.writer.finishWriting { [pending] in
            defer { pending.leave() }
            guard segment.writer.status == .completed else {
                onError(segment.writer.error ?? WriterError.cannotStart(nil))
                try? FileManager.default.removeItem(at: segment.url)
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: segment.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            onFinished(FinishedSegment(
                id: segment.id,
                fileName: segment.fileName,
                startPTS: CMTimeGetSeconds(segment.startPTS),
                endPTS: CMTimeGetSeconds(CMTimeCompare(endPTS, segment.startPTS) > 0 ? endPTS : segment.lastPTS),
                frameCount: segment.frameCount,
                byteCount: size
            ))
        }
    }

    private static func outputSettings(width: Int, height: Int, configuration: Configuration, scaled: Bool) -> [String: Any] {
        var outWidth = width
        var outHeight = height
        let longest = max(width, height)
        if scaled, longest > configuration.maxDimension {
            let scale = Double(configuration.maxDimension) / Double(longest)
            outWidth = Int((Double(width) * scale / 2).rounded()) * 2
            outHeight = Int((Double(height) * scale / 2).rounded()) * 2
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                // A keyframe every second lets clips be cut close to any event.
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        if outWidth != width || outHeight != height {
            settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspect
        }
        return settings
    }

    /// Display transform for ReplayKit's orientation attachment, so players
    /// show landscape gameplay upright without re-encoding.
    static func transform(for orientation: CGImagePropertyOrientation) -> CGAffineTransform {
        switch orientation {
        case .right, .rightMirrored: return CGAffineTransform(rotationAngle: .pi / 2)
        case .left, .leftMirrored: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down, .downMirrored: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }
}
