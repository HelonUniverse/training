import Foundation

/// A captured video frame, normalized across capture providers.
///
/// `Payload` is the platform's native image container (`CMSampleBuffer` on
/// Apple platforms), passed through untouched so no provider converts or
/// copies pixels. Everything else is provider-independent metadata: the
/// pipeline, rolling buffer and event engine never learn which provider
/// produced the frame except through `source`, which is recorded for the
/// provider comparison and nothing else.
public struct GameplayFrame<Payload> {
    /// Increases by one per delivered frame within a capture session.
    public var sequenceNumber: Int64
    /// Presentation time in seconds on the provider's clock (the host clock
    /// on iOS for both ReplayKit and ScreenCaptureKit).
    public var timestamp: Double
    public var width: Int
    public var height: Int
    /// EXIF-style orientation of the pixels (1 = up, 6 = right, 8 = left, 3 = down).
    public var orientation: Int
    public var source: CaptureProviderKind
    public var payload: Payload

    public init(sequenceNumber: Int64, timestamp: Double, width: Int, height: Int, orientation: Int,
                source: CaptureProviderKind, payload: Payload) {
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.width = width
        self.height = height
        self.orientation = orientation
        self.source = source
        self.payload = payload
    }
}

extension GameplayFrame: Sendable where Payload: Sendable {}

/// Lifecycle of a capture provider, as reported to the session.
public enum CaptureProviderStatus: Equatable, Sendable {
    /// The system's content-sharing UI is on screen, waiting for the user.
    case awaitingUserSelection
    case starting
    case running
    /// Capture is alive but not producing frames (e.g. the shared content
    /// went away); it may come back.
    case interrupted(String)
    case stopped(StopReason)
    case failed(String)

    public enum StopReason: String, Equatable, Sendable {
        /// Stopped from our own UI.
        case userInApp
        /// Stopped from system UI (status-bar indicator, Control Center).
        case userSystemUI
        /// The user dismissed the system picker without starting.
        case cancelled
        /// The system ended capture.
        case system
    }

    public var isTerminal: Bool {
        switch self {
        case .stopped, .failed: return true
        default: return false
        }
    }

    /// Compact label for timeline metadata and the debug screen.
    public var label: String {
        switch self {
        case .awaitingUserSelection: return "awaitingUserSelection"
        case .starting: return "starting"
        case .running: return "running"
        case .interrupted(let reason): return "interrupted: \(reason)"
        case .stopped(let reason): return "stopped: \(reason.rawValue)"
        case .failed(let message): return "failed: \(message)"
        }
    }
}

/// A source of gameplay frames (ReplayKit, ScreenCaptureKit; later Android
/// MediaProjection, a PC capture agent, a capture card…).
///
/// A provider is single-use: `start()` asks the user for consent through
/// the platform's own UI and begins delivering frames; both streams finish
/// when capture ends for any reason. The session layer consumes `frames`
/// and turns them into `CaptureSessionController` calls, so nothing past
/// this protocol depends on the provider.
///
/// Note: ReplayKit delivers frames to a separate extension process, so its
/// provider lives inside that process. The main app never sees its frames.
public protocol GameplayCaptureProvider: AnyObject {
    associatedtype Payload

    var kind: CaptureProviderKind { get }
    /// Delivered frames. Providers buffer at most a frame or two here so a
    /// slow consumer drops frames (reported) instead of hoarding buffers.
    var frames: AsyncStream<GameplayFrame<Payload>> { get }
    var statuses: AsyncStream<CaptureProviderStatus> { get }

    /// Presents the platform consent UI and returns once capture is running.
    /// Throws if the user cancels or capture cannot start.
    func start() async throws
    /// Ends capture. Idempotent.
    func stop() async
}

public enum CaptureProviderError: Error, Equatable, LocalizedError {
    case cancelledByUser
    case unavailable(String)
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .cancelledByUser: return "Screen sharing was cancelled."
        case .unavailable(let reason): return "Screen capture is unavailable: \(reason)"
        case .failedToStart(let reason): return "Screen capture failed to start: \(reason)"
        }
    }
}
