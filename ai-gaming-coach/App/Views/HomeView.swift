import CoachCore
import SwiftUI

struct HomeView: View {
    @Environment(CoachModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("AI GAMING COACH")
                        .font(.largeTitle.weight(.black))
                        .tracking(1)

                    GroupBox {
                        LabeledContent("Game", value: "Fortnite")
                        LabeledContent("Platform", value: "iPhone")
                    }

                    if let error = model.setupError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    StartCoachingButton(preferredExtension: model.extensionBundleID, isLive: model.isCaptureLive)
                        .disabled(model.setupError != nil)

                    StatusPanel()

                    if model.isCaptureLive, let live = model.latest {
                        CaptureActiveBanner(manifest: live, now: model.now)
                    } else {
                        HowToCard()
                    }

                    if let last = model.sessions.first(where: { $0.status == .finished || $0.status == .failed }) {
                        NavigationLink {
                            SessionSummaryView(sessionID: last.id)
                        } label: {
                            Label("Last session summary", systemImage: "chart.bar.doc.horizontal")
                        }
                    }
                }
                .padding()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink { DebugView() } label: { Image(systemName: "ladybug") }
                        .accessibilityLabel("Debug")
                    NavigationLink { SessionsView() } label: { Image(systemName: "list.bullet.rectangle") }
                        .accessibilityLabel("Sessions")
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $model.summaryToPresent) { manifest in
                NavigationStack {
                    SessionSummaryView(sessionID: manifest.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { model.summaryToPresent = nil }
                            }
                        }
                }
            }
        }
    }
}

private struct StatusPanel: View {
    @Environment(CoachModel.self) private var model

    var body: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 10) {
                StatusRow(title: "Screen capture",
                          detail: model.isCaptureLive ? "Connected" : "Not connected",
                          level: model.isCaptureLive ? .ok : .off)
                StatusRow(title: "AI", detail: aiDetail, level: aiLevel)
                // Game/match detection is vision work: Milestone 2.
                StatusRow(title: "Match detected", detail: "Not available yet (Milestone 2)", level: .off)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aiDetail: String {
        switch model.aiStatus {
        case .connected: return "Connected (\(model.backend.name))"
        case .mock: return "Mock backend (offline)"
        case .unavailable(let reason): return reason
        }
    }

    private var aiLevel: StatusRow.Level {
        switch model.aiStatus {
        case .connected: return .ok
        case .mock: return .warning
        case .unavailable: return .error
        }
    }
}

struct StatusRow: View {
    enum Level { case ok, warning, error, off }

    var title: String
    var detail: String
    var level: Level

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch level {
        case .ok: return .green
        case .warning: return .yellow
        case .error: return .red
        case .off: return .gray
        }
    }
}

/// Privacy: whenever capture runs, the app says so plainly.
private struct CaptureActiveBanner: View {
    var manifest: SessionManifest
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen capture is active", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Everything on screen is being analysed until you stop the broadcast from the red status indicator or Control Center.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            let stats = manifest.statistics
            HStack {
                MiniStat(title: "Time", value: SessionTimeFormatter.duration(manifest.wallDuration(now: now)))
                MiniStat(title: "FPS in", value: String(format: "%.0f", stats.receivedFPS))
                MiniStat(title: "Frames", value: "\(stats.videoFramesReceived)")
                MiniStat(title: "Keyframes", value: "\(stats.keyframesSaved)")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MiniStat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HowToCard: View {
    var body: some View {
        GroupBox("How it works") {
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Tap Start Coaching.")
                step(2, "In the iOS sheet, check that AI Gaming Coach is selected and tap Start Broadcast.")
                step(3, "Open Fortnite and play normally. This app doesn't need to stay open.")
                step(4, "When you're done, tap the red status indicator (or open Control Center) and stop the broadcast.")
                step(5, "Come back here to see the session summary.")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }
}
