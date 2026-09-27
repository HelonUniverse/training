import AVFoundation
import CoachCore
import CoreImage
import Foundation
import ImageIO

/// Turns a recorded session into upright JPEG frames for analysis:
/// one frame per second from the recorded video, plus the 5-second
/// keyframes for any stretch that has no video (for example sessions that
/// only kept the last 90 s).
struct VideoFrameExtractor {
    var directory: SessionDirectory
    var manifest: SessionManifest
    var keyframes: [KeyframeRecord]
    var interval: Double = 1
    var maxDimension: CGFloat = 768
    var jpegQuality: Double = 0.6
    var maxFrames = 3600

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Frames the extraction will produce, for the cost prompt.
    var estimatedFrameCount: Int {
        let video = manifest.videoPurged ? 0 : manifest.bufferedSegments.reduce(0) { $0 + Int(($1.duration / interval).rounded(.up)) }
        let uncovered = keyframes.filter { !covered($0.timestamp) }.count
        return min(maxFrames, video + uncovered)
    }

    func extract(progress: @escaping (Int, Int) -> Void) async -> [AnalysisImage] {
        let total = estimatedFrameCount
        var frames: [AnalysisImage] = []
        let rotate = manifest.source.needsLegacyRotation

        if !manifest.videoPurged {
            for segment in manifest.bufferedSegments.sorted(by: { $0.start < $1.start }) {
                let asset = AVURLAsset(url: directory.segmentURL(segment.fileName))
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
                let tolerance = CMTime(seconds: 0.3, preferredTimescale: 600)
                generator.requestedTimeToleranceBefore = tolerance
                generator.requestedTimeToleranceAfter = tolerance

                var local = 0.0
                while local < segment.duration, frames.count < maxFrames {
                    let time = CMTime(seconds: local, preferredTimescale: 600)
                    if let image = try? await generator.image(at: time).image,
                       let jpeg = encode(CIImage(cgImage: image), rotate: rotate) {
                        frames.append(AnalysisImage(time: segment.start + local, jpeg: jpeg, fromVideo: true))
                        progress(frames.count, total)
                    }
                    local += interval
                }
            }
        }

        for keyframe in keyframes where !covered(keyframe.timestamp) && frames.count < maxFrames {
            guard let image = CIImage(contentsOf: directory.keyframeURL(keyframe.fileName)),
                  let jpeg = encode(image, rotate: rotate) else { continue }
            frames.append(AnalysisImage(time: keyframe.timestamp, jpeg: jpeg, fromVideo: false))
            progress(frames.count, total)
        }
        return frames.sorted { $0.time < $1.time }
    }

    private func covered(_ time: Double) -> Bool {
        guard !manifest.videoPurged else { return false }
        return manifest.bufferedSegments.contains { time >= $0.start && time < $0.end }
    }

    private func encode(_ input: CIImage, rotate: Bool) -> Data? {
        var image = rotate ? input.oriented(.down) : input
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality,
        ]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}
