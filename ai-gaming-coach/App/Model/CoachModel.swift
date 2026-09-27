import CoachCore
import Foundation
import Observation
import UIKit

/// App-side view of the shared container. With ReplayKit the app never
/// receives frames: it reads what the broadcast extension persisted and
/// reacts to its Darwin notifications while in the foreground. With the
/// ScreenCaptureKit prototype (iOS 27+) capture runs in this process, but
/// sessions land in the same store and are read back the same way.
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

    /// Capture providers the user can pick between while both are tested.
    enum ProviderChoice: String, CaseIterable, Identifiable {
        case replayKit
        case screenCaptureKit
        var id: String { rawValue }
    }

    enum InAppCaptureState: Equatable {
        case idle
        case awaitingUser
        case running
        case stopping
    }

    /// iOS 27+ and the system reports screen recording as available.
    private(set) var screenCaptureKitAvailable = false
    var providerChoice: ProviderChoice {
        didSet { UserDefaults.standard.set(providerChoice.rawValue, forKey: providerChoiceKey) }
    }
    private(set) var inAppCaptureState: InAppCaptureState = .idle
    private(set) var captureError: String?
    @ObservationIgnored private var inAppSession: AnyObject?
    @ObservationIgnored private let providerChoiceKey = "coach.captureProvider"

    // MARK: AI analysis state

    enum AnalysisState: Equatable {
        case idle
        case extracting(done: Int, total: Int)
        case analyzing(done: Int, total: Int)
        case summarizing
        case failed(String)
    }

    static let defaultOpenAIModel = "gpt-5-mini"
    private(set) var hasOpenAIKey = OpenAIKeyStore.read() != nil
    var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "coach.openAIModel") }
    }
    private(set) var analysisStates: [UUID: AnalysisState] = [:]
    /// Bumped when an analysis is saved so views reload it.
    private(set) var analysisRevision = 0

    init() {
        // ScreenCaptureKit is the preferred provider to test where it exists;
        // the user's explicit choice is remembered either way.
        providerChoice = UserDefaults.standard.string(forKey: "coach.captureProvider")
            .flatMap(ProviderChoice.init(rawValue:)) ?? .screenCaptureKit
        openAIModel = UserDefaults.standard.string(forKey: "coach.openAIModel") ?? Self.defaultOpenAIModel
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
        refreshProviderAvailability()
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

    // MARK: Capture provider

    /// The provider Start Coaching will use: ReplayKit below iOS 27.
    var activeProvider: ProviderChoice {
        screenCaptureKitAvailable ? providerChoice : .replayKit
    }

    private func refreshProviderAvailability() {
        #if canImport(ScreenCaptureKit)
        if #available(iOS 27.0, *) {
            screenCaptureKitAvailable = ScreenCaptureKitCaptureProvider.isAvailable
        }
        #endif
    }

    /// Presents Apple's content-sharing picker and runs capture in-app.
    func startScreenCaptureKit() {
        guard inAppCaptureState == .idle, let environment else { return }
        captureError = nil
        #if canImport(ScreenCaptureKit)
        guard #available(iOS 27.0, *) else { return }
        let session: ScreenCaptureKitSession
        do {
            session = try ScreenCaptureKitSession(environment: environment)
        } catch {
            captureError = error.localizedDescription
            return
        }
        inAppSession = session
        inAppCaptureState = .awaitingUser
        Task {
            do {
                try await session.start()
                inAppCaptureState = .running
                reloadAll()
                await session.waitUntilFinished()
            } catch CaptureProviderError.cancelledByUser {
                // The user closed the picker: nothing was recorded.
            } catch {
                captureError = error.localizedDescription
            }
            inAppSession = nil
            inAppCaptureState = .idle
            reloadAll()
        }
        #endif
    }

    func stopScreenCaptureKit() {
        #if canImport(ScreenCaptureKit)
        guard #available(iOS 27.0, *), let session = inAppSession as? ScreenCaptureKitSession else { return }
        inAppCaptureState = .stopping
        Task { await session.stop() }
        #endif
    }

    // MARK: AI match analysis

    func saveOpenAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasOpenAIKey = OpenAIKeyStore.save(trimmed)
    }

    func removeOpenAIKey() {
        OpenAIKeyStore.delete()
        hasOpenAIKey = false
    }

    func analysis(for id: UUID) -> MatchAnalysis? {
        _ = analysisRevision
        return store?.analysis(for: id)
    }

    func analysisState(for id: UUID) -> AnalysisState { analysisStates[id] ?? .idle }

    private func frameExtractor(for id: UUID) -> VideoFrameExtractor? {
        guard let store, let manifest = sessions.first(where: { $0.id == id }) else { return nil }
        return VideoFrameExtractor(directory: store.directory(for: id), manifest: manifest, keyframes: store.keyframes(for: id))
    }

    func estimatedAnalysisFrames(for id: UUID) -> Int { frameExtractor(for: id)?.estimatedFrameCount ?? 0 }

    /// Extracts frames on the device, sends them to OpenAI and saves the
    /// result as the session's analysis.json. Keeps the screen awake while
    /// it runs, since leaving the app would pause the network requests.
    func analyze(_ id: UUID) {
        switch analysisState(for: id) {
        case .extracting, .analyzing, .summarizing: return
        default: break
        }
        guard let key = OpenAIKeyStore.read() else {
            analysisStates[id] = .failed(AnalysisError.missingAPIKey.localizedDescription)
            return
        }
        guard let store, let extractor = frameExtractor(for: id),
              let manifest = sessions.first(where: { $0.id == id }) else { return }

        let model = openAIModel.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultOpenAIModel : openAIModel
        analysisStates[id] = .extracting(done: 0, total: extractor.estimatedFrameCount)
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let frames = await extractor.extract { done, total in
                    Task { @MainActor in self.analysisStates[id] = .extracting(done: done, total: total) }
                }
                let analyzer = MatchAnalyzer(client: OpenAIHTTPClient(apiKey: key), model: model, language: "es")
                let analysis = try await analyzer.analyze(frames: frames, manifest: manifest) { progress in
                    Task { @MainActor in
                        self.analysisStates[id] = progress.writingSummary
                            ? .summarizing
                            : .analyzing(done: progress.segmentsDone, total: progress.segmentsTotal)
                    }
                }
                try store.save(analysis, for: id)
                analysisRevision += 1
                analysisStates[id] = .idle
            } catch {
                analysisStates[id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Device testing

    func deviceTestNotes(for id: UUID) -> DeviceTestNotes { store?.deviceTestNotes(for: id) ?? DeviceTestNotes() }

    func saveDeviceTestNotes(_ notes: DeviceTestNotes, for id: UUID) {
        try? store?.save(notes, for: id)
    }

    func providerComparison() -> ProviderComparison {
        let entries = sessions.map { (manifest: $0, notes: deviceTestNotes(for: $0.id)) }
        return ProviderComparison(sessions: entries, now: now)
    }

    func deviceTestReport(for id: UUID, notes: DeviceTestNotes) -> DeviceTestReport? {
        guard let manifest = sessions.first(where: { $0.id == id }) else { return nil }
        return DeviceTestReport(manifest: manifest, notes: notes, now: now)
    }
}
