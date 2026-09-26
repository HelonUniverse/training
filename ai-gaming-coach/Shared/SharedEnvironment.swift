import Foundation
import CoachCore

/// What the main app and the broadcast extension share. They are separate
/// sandboxed processes; the App Group container and its UserDefaults suite
/// are the only storage both can reach. Identifiers come from Info.plist
/// (filled from build settings in project.yml) so nothing is hard-coded twice.
struct SharedEnvironment {
    enum SetupError: LocalizedError {
        case missingInfoKey(String)
        case appGroupUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .missingInfoKey(let key):
                return "Build configuration error: \(key) is missing from Info.plist."
            case .appGroupUnavailable(let group):
                return "App Group \(group) is not available. Check that both targets have the App Groups capability with this identifier."
            }
        }
    }

    static let appGroupInfoKey = "CoachAppGroupIdentifier"
    static let extensionBundleIDInfoKey = "CoachBroadcastExtensionBundleIdentifier"

    let appGroupIdentifier: String
    let containerURL: URL
    let defaults: UserDefaults
    let store: SessionStore

    static func current(bundle: Bundle = .main) throws -> SharedEnvironment {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty else {
            throw SetupError.missingInfoKey(appGroupInfoKey)
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let defaults = UserDefaults(suiteName: group)
        else {
            throw SetupError.appGroupUnavailable(group)
        }
        return SharedEnvironment(
            appGroupIdentifier: group,
            containerURL: container,
            defaults: defaults,
            store: SessionStore(rootURL: container.appendingPathComponent("Coach", isDirectory: true))
        )
    }

    var settingsStore: CaptureSettingsStore { CaptureSettingsStore(defaults: defaults) }

    /// Game chosen on the Home screen; stamped on each new session.
    var selectedGameID: String {
        get { defaults.string(forKey: "coach.selectedGame") ?? GameID.fortnite.rawValue }
        nonmutating set { defaults.set(newValue, forKey: "coach.selectedGame") }
    }
}

/// Darwin notifications cross the process boundary but carry no payload;
/// they only say "look at the shared container again".
enum CoachNotification {
    static let sessionUpdated = "com.aigamingcoach.session.updated"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }
}

/// Observes one Darwin notification and calls `handler` on the main queue.
final class DarwinNotificationObserver {
    private let name: String
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let this = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { this.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
