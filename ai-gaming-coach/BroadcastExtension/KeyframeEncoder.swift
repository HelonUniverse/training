import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Downscales a frame and writes it as JPEG off the sample-handler thread.
/// At most `maxInFlight` frames are held at once so ReplayKit's buffer pool
/// is never starved; extra requests are refused and counted as drops.
final class KeyframeEncoder {
    struct Output {
        var width: Int
        var height: Int
        var byteCount: Int64
    }

    enum EncodeError: Error {
        case renderFailed
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let queue = DispatchQueue(label: "coach.keyframes", qos: .utility)
    private let lock = NSLock()
    private var inFlight = 0
    private let maxInFlight = 2

    /// Returns false when busy; the frame was not taken.
    func encode(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        maxDimension: Int,
        quality: Double,
        to url: URL,
        completion: @escaping (Result<Output, Error>) -> Void
    ) -> Bool {
        lock.lock()
        guard inFlight < maxInFlight else {
            lock.unlock()
            return false
        }
        inFlight += 1
        lock.unlock()

        queue.async { [self] in
            defer {
                lock.lock()
                inFlight -= 1
                lock.unlock()
            }
            autoreleasepool {
                var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                let longest = max(image.extent.width, image.extent.height)
                if longest > CGFloat(maxDimension) {
                    let scale = CGFloat(maxDimension) / longest
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                }
                let options: [CIImageRepresentationOption: Any] = [
                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
                ]
                guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
                    completion(.failure(EncodeError.renderFailed))
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    completion(.success(Output(width: Int(image.extent.width.rounded()),
                                               height: Int(image.extent.height.rounded()),
                                               byteCount: Int64(data.count))))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        return true
    }
}

/// Cheapest possible proof that analysis sees real pixels: mean luminance
/// over a 16×16 grid of the luma plane. Also flags black frames, which is
/// what the stream looks like when content is protected from capture.
enum FrameProbe {
    static func meanLuma(_ pixelBuffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let grid = 16
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var sum = 0
            for gy in 0..<grid {
                let y = (2 * gy + 1) * height / (2 * grid)
                for gx in 0..<grid {
                    let x = (2 * gx + 1) * width / (2 * grid)
                    sum += Int(pixels[y * stride + x])
                }
            }
            let mean = Double(sum) / Double(grid * grid)
            let videoRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            return videoRange ? min(max((mean - 16) / 219, 0), 1) : mean / 255

        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            var sum = 0.0
            for gy in 0..<grid {
                let y = (2 * gy + 1) * height / (2 * grid)
                for gx in 0..<grid {
                    let offset = y * stride + (2 * gx + 1) * width / (2 * grid) * 4
                    sum += 0.114 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.299 * Double(pixels[offset + 2])
                }
            }
            return sum / Double(grid * grid) / 255

        default:
            return nil
        }
    }
}
