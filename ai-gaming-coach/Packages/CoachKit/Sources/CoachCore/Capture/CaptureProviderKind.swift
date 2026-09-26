import Foundation

/// Which capture provider produced a session. Derived from the recorded
/// mechanism, so sessions from builds that predate the provider concept
/// are still classified.
public struct CaptureProviderKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let replayKit = CaptureProviderKind(rawValue: "ReplayKit.BroadcastUploadExtension")
    public static let screenCaptureKit = CaptureProviderKind(rawValue: "ScreenCaptureKit.SCStream")

    public init(mechanism: String) {
        self.rawValue = mechanism
    }

    public var displayName: String {
        switch self {
        case .replayKit: return "ReplayKit (Broadcast Upload Extension)"
        case .screenCaptureKit: return "ScreenCaptureKit (in-app, iOS 27+)"
        default: return rawValue
        }
    }
}
