#if DEBUG
import CoachCore
import SwiftUI
import UIKit

/// DEBUG-only A/B page: ReplayKit vs ScreenCaptureKit, computed from real
/// sessions recorded on this device. Until a provider has a completed
/// session with frames, its column says so instead of showing numbers.
struct ProviderComparisonView: View {
    @Environment(CoachModel.self) private var model
    @State private var copied = false

    var body: some View {
        let comparison = model.providerComparison()
        List {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        ForEach(comparison.columns, id: \.provider) { column in
                            Text(shortName(column.provider)).font(.caption.weight(.bold))
                        }
                    }
                    Divider()
                    row("Sessions", comparison) { "\($0.sessions)" }
                    row("Input FPS", comparison) { format($0.inputFPS, "%.1f") }
                    row("Processed FPS", comparison) { format($0.processedFPS, "%.1f") }
                    row("Dropped", comparison) { format($0.droppedPercent, "%.2f %%") }
                    row("Black frames", comparison) { format($0.blackFramePercent, "%.2f %%") }
                    row("Memory peak", comparison) { format($0.peakMemoryBytes.map { Double($0) / 1_048_576 }, "%.1f MB") }
                    row("Memory avg", comparison) { format($0.averageMemoryBytes.map { $0 / 1_048_576 }, "%.1f MB") }
                    row("CPU avg", comparison) { format($0.averageCPUPercent, "%.0f %%") }
                    row("Thermal worst", comparison) { $0.hasData ? ($0.worstThermalState?.rawValue ?? "—") : "—" }
                    row("Latency avg", comparison) { format($0.averageLatency.map { $0 * 1000 }, "%.1f ms") }
                    row("Latency max", comparison) { format($0.maxLatency.map { $0 * 1000 }, "%.1f ms") }
                    row("Stability", comparison) { $0.hasData ? "\($0.finishedNormally) ok · \($0.failed) failed · \($0.terminated) killed" : "—" }
                    row("Fortnite degraded", comparison) { $0.hasData ? "yes \($0.fortniteDegradedYes) · no \($0.fortniteDegradedNo)" : "—" }
                }
                .font(.caption.monospacedDigit())
            } footer: {
                Text("Only completed sessions with frames count. \"—\" means not measured or no session yet; nothing here is estimated.")
            }

            ForEach(comparison.columns, id: \.provider) { column in
                if !column.performanceNotes.isEmpty || !column.failureReasons.isEmpty {
                    Section("\(shortName(column.provider)) notes") {
                        ForEach(column.failureReasons, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                        ForEach(column.performanceNotes, id: \.self) { Text($0) }
                    }
                }
            }

            Section {
                Button(copied ? "Copied" : "Copy CAPTURE PROVIDER COMPARISON") {
                    UIPasteboard.general.string = comparison.text()
                    copied = true
                }
            }
        }
        .navigationTitle("ReplayKit vs ScreenCaptureKit")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ comparison: ProviderComparison,
                     _ value: @escaping (ProviderComparison.Column) -> String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            ForEach(comparison.columns, id: \.provider) { column in
                Text(column.hasData ? value(column) : "—")
            }
        }
    }

    private func format(_ value: Double?, _ format: String) -> String {
        value.map { String(format: format, $0) } ?? "—"
    }

    private func shortName(_ provider: CaptureProviderKind) -> String {
        switch provider {
        case .replayKit: return "ReplayKit"
        case .screenCaptureKit: return "ScreenCaptureKit"
        default: return provider.rawValue
        }
    }
}
#endif
