import CoachCore
import SwiftUI

/// Development dashboard. Refreshes with every manifest the extension
/// writes (about once a second) while the app is in the foreground — for
/// example when viewed on an iPad or after switching back mid-session.
struct DebugView: View {
    @Environment(CoachModel.self) private var model

    var body: some View {
        List {
            if let manifest = model.latest {
                captureSection(manifest)
                visionSection
                aiSection
                Section("Event timeline — latest session") {
                    TimelineRows(events: model.latestEvents)
                }
                Section {
                    NavigationLink("Keyframes") { KeyframeGrid(sessionID: manifest.id).padding() }
                    NavigationLink("Session summary") { SessionSummaryView(sessionID: manifest.id) }
                }
            } else {
                ContentUnavailableView("No sessions yet", systemImage: "waveform.slash",
                                       description: Text("Start coaching to see live pipeline data here."))
            }
        }
        .navigationTitle("Debug")
        .font(.callout)
    }

    private func captureSection(_ manifest: SessionManifest) -> some View {
        let stats = manifest.statistics
        let heartbeatAge = model.now.timeIntervalSince(manifest.updatedAt)
        return Section("Capture") {
            DebugRow("Status", manifest.status.rawValue + (manifest.isLive(now: model.now) ? " (live)" : ""))
            DebugRow("Heartbeat age", String(format: "%.1f s", max(0, heartbeatAge)))
            DebugRow("FPS received", String(format: "%.1f (avg %.1f)", stats.receivedFPS, stats.averageReceivedFPS))
            DebugRow("FPS analysed", String(format: "%.1f (avg %.1f)", stats.analyzedFPS, stats.averageProcessingFPS))
            DebugRow("Frames received", "\(stats.videoFramesReceived)")
            DebugRow("Frames processed", "\(stats.framesAnalyzed)")
            DebugRow("Skipped (throttle)", "\(stats.framesSkippedByThrottle)")
            DebugRow("Dropped", dropsDescription(stats))
            DebugRow("Buffer duration", String(format: "%.1f s / %ld segments", stats.rollingBufferSeconds, stats.rollingBufferSegments))
            DebugRow("Keyframes", "\(stats.keyframesSaved)")
            DebugRow("Video", "\(stats.videoWidth)×\(stats.videoHeight) · orient \(stats.videoOrientation)")
            DebugRow("Last luma", stats.lastFrameLuma.map { String(format: "%.3f", $0) } ?? "—")
            DebugRow("Near-black frames", "\(stats.nearBlackFrames)")
            DebugRow("Analysis time", String(format: "avg %.2f ms · max %.2f ms", stats.averageAnalysisMilliseconds, stats.maxAnalysisSeconds * 1000))
            DebugRow("Memory headroom", memoryDescription(stats))
            DebugRow("Memory footprint", MetricFormat.memory(peak: stats.peakMemoryFootprintBytes, average: stats.averageMemoryFootprintBytes, current: stats.memoryFootprintBytes))
            DebugRow("CPU", MetricFormat.cpu(average: stats.averageCPUPercent, peak: stats.peakCPUPercent, current: stats.cpuPercent))
            DebugRow("Thermal", MetricFormat.thermal(worst: stats.worstThermalState, current: stats.thermalState))
            DebugRow("Capture latency", MetricFormat.latency(average: stats.averageCaptureLatency, max: stats.maxCaptureLatency, current: stats.lastCaptureLatency))
            DebugRow("Black frames", stats.blackFramePercent.map { String(format: "%.2f %%", $0) } ?? "—")
            DebugRow("Buffer on disk", stats.rollingBufferBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
            DebugRow("Audio app / mic", "\(stats.audioAppSamples) / \(stats.audioMicSamples)")
            DebugRow("Storage errors", "\(stats.storageErrors)")
        }
    }

    /// Placeholders so the layout is ready for Milestone 2 detections.
    private var visionSection: some View {
        Section {
            DebugRow("Detected game", "—")
            DebugRow("Fight state", "—")
            DebugRow("Health", "—")
            DebugRow("Shield", "—")
            DebugRow("Selected slot", "—")
            DebugRow("Inventory", "—")
        } header: {
            Text("Vision")
        } footer: {
            Text("Game-state detection arrives in Milestone 2. Every value will show its confidence.")
        }
    }

    private var aiSection: some View {
        Section("AI") {
            DebugRow("Backend", model.backend.name)
            DebugRow("Requests", "0")
            DebugRow("Network latency", "—")
        }
    }

    private func dropsDescription(_ stats: SessionStatistics) -> String {
        let parts = FrameDropReason.allCases.compactMap { reason -> String? in
            let count = stats.dropCount(reason)
            return count > 0 ? "\(reason.rawValue) \(count)" : nil
        }
        return parts.isEmpty ? "0" : "\(stats.droppedFrames) (" + parts.joined(separator: ", ") + ")"
    }

    private func memoryDescription(_ stats: SessionStatistics) -> String {
        guard let current = stats.memoryAvailableBytes else { return "—" }
        let now = ByteCountFormatter.string(fromByteCount: current, countStyle: .memory)
        let low = stats.minimumMemoryAvailableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—"
        return "\(now) (min \(low))"
    }
}

struct DebugRow: View {
    var title: String
    var value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

struct EventTimelineView: View {
    @Environment(CoachModel.self) private var model
    let sessionID: UUID

    var body: some View {
        List {
            TimelineRows(events: model.events(for: sessionID))
        }
        .navigationTitle("Event timeline")
    }
}

/// `13:20.440 fightStarted 0.91` — one line per event, newest last.
struct TimelineRows: View {
    var events: [MatchEvent]

    var body: some View {
        if events.isEmpty {
            Text("No events").foregroundStyle(.secondary)
        } else {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(SessionTimeFormatter.string(event.timestamp))
                        Text(event.type.rawValue).fontWeight(.semibold)
                        Spacer()
                        Text(String(format: "%.2f", event.confidence))
                        Text(event.origin.rawValue).foregroundStyle(.secondary)
                    }
                    if !event.metadata.isEmpty {
                        Text(event.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.monospaced())
            }
        }
    }
}
