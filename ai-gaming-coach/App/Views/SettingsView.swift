import CoachCore
import SwiftUI

struct SettingsView: View {
    @Environment(CoachModel.self) private var model
    @State private var confirmDeleteAll = false
    @State private var apiKeyDraft = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Rolling buffer: \(Int(model.settings.rollingBufferSeconds)) s")
                    Slider(value: $model.settings.rollingBufferSeconds, in: CaptureSettings.rollingBufferRange, step: 10)
                }
                Stepper("Analysis rate: \(Int(model.settings.analysisFPS)) fps",
                        value: $model.settings.analysisFPS, in: CaptureSettings.analysisFPSRange, step: 1)
                Stepper("Keyframe every \(Int(model.settings.keyframeIntervalSeconds)) s",
                        value: $model.settings.keyframeIntervalSeconds, in: CaptureSettings.keyframeIntervalRange, step: 1)
            } header: {
                Text("Capture")
            } footer: {
                Text("Changes apply to the next session.")
            }

            Section {
                if model.hasOpenAIKey {
                    LabeledContent("API key", value: "Saved on this iPhone ✓")
                    Button("Remove API key", role: .destructive) { model.removeOpenAIKey() }
                } else {
                    SecureField("Paste your OpenAI API key (sk-…)", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save API key") {
                        model.saveOpenAIKey(apiKeyDraft)
                        apiKeyDraft = ""
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                LabeledContent("Model") {
                    TextField(CoachModel.defaultOpenAIModel, text: $model.openAIModel)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Keep full match video", isOn: $model.settings.keepFullMatchVideo)
            } header: {
                Text("AI analysis (OpenAI)")
            } footer: {
                Text("The key is stored in this iPhone's Keychain only. Analysis sends about one frame per second of the match to OpenAI, only when you tap Analyze; usage is billed to your OpenAI account. \"Keep full match video\" saves the whole match (up to 60 min, ~150 MB per 10 min) so every minute can be analysed; turn it off to keep only the last \(Int(model.settings.rollingBufferSeconds)) s.")
            }

            Section {
                Toggle("Don't Save Video", isOn: $model.settings.dontSaveVideo)
                Toggle("Keep keyframes", isOn: $model.settings.keepKeyframes)
            } header: {
                Text("Privacy")
            } footer: {
                Text("With Don't Save Video on, gameplay video is deleted when the session ends; only events and metrics are kept. Nothing is uploaded: in this version all data stays on this iPhone.")
            }

            Section {
                Button("Delete All Gameplay Data", role: .destructive) { confirmDeleteAll = true }
            } footer: {
                Text("Removes every session: video, keyframes, events and metrics.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Delete all gameplay data? This can't be undone.", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.deleteAllGameplayData() }
        }
    }
}

struct SessionsView: View {
    @Environment(CoachModel.self) private var model

    var body: some View {
        List {
            ForEach(model.sessions) { session in
                NavigationLink {
                    SessionSummaryView(sessionID: session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.createdAt, format: .dateTime.day().month().hour().minute())
                            .font(.headline)
                        Text("\(session.status.rawValue) · \(SessionTimeFormatter.duration(session.wallDuration(now: model.now))) · \(session.statistics.videoFramesReceived) frames")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .deleteDisabled(session.isLive(now: model.now))
            }
            .onDelete { offsets in
                let ids = offsets.map { model.sessions[$0].id }
                ids.forEach(model.deleteSession)
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "gamecontroller")
            }
        }
        .navigationTitle("Sessions")
    }
}
