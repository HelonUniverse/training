import CoachCore
import SwiftUI
import UIKit

/// Physical-device validation form. Measured values are filled in from the
/// session; the tester records what only a person can observe, then copies
/// one DEVICE TEST RESULT block to compare runs across phones and providers.
struct DeviceTestReportView: View {
    @Environment(CoachModel.self) private var model
    let sessionID: UUID
    @State private var notes = DeviceTestNotes()
    @State private var loaded = false
    @State private var copied = false

    var body: some View {
        Form {
            Section("Tester") {
                TextField("iPhone model (e.g. iPhone 15 Pro)", text: $notes.iPhoneModelName)
                TextField("Fortnite version (Settings → bottom of the menu)", text: $notes.fortniteVersion)
            }

            Section {
                ObservationPicker("Fortnite frame rate visibly degraded", $notes.fortniteFrameRateDegraded)
                ObservationPicker("Fortnite audio normal", $notes.fortniteAudioNormal)
                ObservationPicker("Device noticeably hot", $notes.deviceNoticeablyHot)
                TextField("Fortnite performance notes", text: $notes.fortnitePerformanceNotes, axis: .vertical)
            } header: {
                Text("Fortnite")
            }

            Section {
                ObservationPicker("Opening Fortnite", $notes.survivedOpeningFortnite)
                ObservationPicker("Joining a match", $notes.survivedJoiningMatch)
                ObservationPicker("Combat", $notes.survivedCombat)
                ObservationPicker("App switching", $notes.survivedAppSwitching)
                ObservationPicker("Returning to the Coach app", $notes.survivedReturningToCoach)
                ObservationPicker("Stopped unexpectedly", $notes.broadcastStoppedUnexpectedly)
            } header: {
                Text("Did capture survive…")
            } footer: {
                Text("\"Yes\" means frames kept arriving through that step: check that the frame counter kept rising, or that the timeline shows no gap.")
            }

            Section("Notes") {
                TextField("Anything else", text: $notes.notes, axis: .vertical)
            }

            if let report = model.deviceTestReport(for: sessionID, notes: notes) {
                Section {
                    Button(copied ? "Copied" : "Copy DEVICE TEST RESULT") {
                        UIPasteboard.general.string = report.text()
                        copied = true
                    }
                    ShareLink("Share as text", item: report.text())
                    ShareLink("Share as JSON", item: report.json())
                }
                Section("Preview") {
                    Text(report.text())
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Device Test Result")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            notes = model.deviceTestNotes(for: sessionID)
            loaded = true
        }
        .onChange(of: notes) { _, newValue in
            guard loaded else { return }
            copied = false
            model.saveDeviceTestNotes(newValue, for: sessionID)
        }
    }
}

private struct ObservationPicker: View {
    let title: String
    @Binding var value: ManualObservation

    init(_ title: String, _ value: Binding<ManualObservation>) {
        self.title = title
        _value = value
    }

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(ManualObservation.allCases, id: \.self) { observation in
                Text(observation.label).tag(observation)
            }
        }
    }
}
