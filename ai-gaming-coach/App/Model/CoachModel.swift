import CoachCore
import Foundation
import Observation

/// App-side view of the shared container. The app never receives frames:
/// it reads what the broadcast extension persisted and reacts to its
/// Darwin notifications while in the foreground.
@MainActor
@Observable
final class CoachModel {
    let environment: SharedEnvironment?
    let setupError: String?
    let extensionBundleID: String?
    let backend: AIBackend = MockAIBackend()

    private(set) var sessions: [SessionManifest] = []
    private(set) var latestEvents: [MatchEvent] = []
    private(set) var aiStatus: AIBackendStatus = .mock
    /// Bumped by the heartbeat timer so views re-evaluate `isCaptureLive`.
    private(set) var now = Date()
    var summaryToPresent: SessionManifest?

    var settings: CaptureSettings {
        didSet { environment?.settingsStore.save(settings) }
    }

    @ObservationIgnored private var observer: DarwinNotificationObserver?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let shownSummariesKey = "coach.shownSummaries"

    init() {
        extensionBundleID = Bundle.main.object(forInfoDictionaryKey: SharedEnvironment.extensionBundleIDInfoKey) as? String
        do {
            let environment = try SharedEnvironment.current()
            self.environment = environment
            settings = environment.settingsStore.load()
            setupError = nil
        } catch {
            environment = nil
            settings = .default
            setupError = error.localizedDescription
        }
    }

    var store: SessionStore? { environment?.store }
    var latest: SessionManifest? { sessions.first }
    var isCaptureLive: Bool { latest?.isLive(now: now) ?? false }

    // MARK: Lifecycle

    func activate() {
        reloadAll()
        observer = DarwinNotificationObserver(name: CoachNotification.sessionUpdated) { [weak self] in
            self?.reloadLatest()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        Task { aiStatus = await backend.status() }
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        observer = nil
    }

    private func heartbeat() {
        now = Date()
        // Darwin notifications are only delivered while we run, and are not
        // queued; polling the live session covers anything missed.
        if latest?.status == .running || latest?.status == .paused { reloadLatest() }
    }

    // MARK: Loading

    func reloadAll() {
        guard let store else { return }
        sessions = store.allManifests()
        reloadLatestEvents()
        presentSummaryIfNeeded()
    }

    private func reloadLatest() {
        // Cheap path: only the live session's files changed.
        guard let store, let current = latest, current.status == .running || current.status == .paused,
              let refreshed = try? store.manifest(for: current.id)
        else {
            // No live session known, so this is a new one: rescan.
            reloadAll()
            return
        }
        sessions[0] = refreshed
        if refreshed.status == .running || refreshed.status == .paused {
            reloadLatestEvents()
        } else {
            reloadAll()
        }
    }

    private func reloadLatestEvents() {
        guard let store, let latest else {
            latestEvents = []
            return
        }
        latestEvents = store.events(for: latest.id)
    }

    /// Shows the Session Summary once when the user comes back after a
    /// broadcast ends.
    private func presentSummaryIfNeeded() {
        guard let latest, latest.status == .finished || latest.status == .failed else { return }
        var shown = Set(UserDefaults.standard.stringArray(forKey: shownSummariesKey) ?? [])
        guard !shown.contains(latest.id.uuidString) else { return }
        shown.insert(latest.id.uuidString)
        UserDefaults.standard.set(Array(shown), forKey: shownSummariesKey)
        summaryToPresent = latest
    }

    func events(for id: UUID) -> [MatchEvent] { store?.events(for: id) ?? [] }
    func keyframes(for id: UUID) -> [KeyframeRecord] { store?.keyframes(for: id) ?? [] }
    func directory(for id: UUID) -> SessionDirectory? { store?.directory(for: id) }

    // MARK: Privacy

    func deleteSession(_ id: UUID) {
        try? store?.deleteSession(id)
        reloadAll()
    }

    func deleteVideo(_ id: UUID) {
        try? store?.purgeVideo(for: id)
        reloadAll()
    }

    func deleteAllGameplayData() {
        try? store?.deleteAll()
        UserDefaults.standard.removeObject(forKey: shownSummariesKey)
        reloadAll()
    }

    func diskUsage(for id: UUID) -> Int64 { store?.diskUsage(for: id) ?? 0 }
}
