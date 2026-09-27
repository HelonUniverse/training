import AVKit
import CoachCore
import SwiftUI

/// Milestone 1 Session Summary: proof that frames arrived and flowed
/// through buffer, keyframes and the timeline.
struct SessionSummaryView: View {
    @Environment(CoachModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var confirmDelete = false

    var body: some View {
        if let manifest = model.sessions.first(where: { $0.id == sessionID }) {
            content(manifest)
        } else {
            ContentUnavailableView("Session deleted", systemImage: "trash")
        }
    }

    private func content(_ manifest: SessionManifest) -> some View {
        let stats = manifest.statistics
        return List {
            if manifest.status == .failed {
                Section {
                    Label(manifest.failureReason ?? "The capture ended with an error.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Session") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                    BigStat(title: "Duration", value: SessionTimeFormatter.duration(manifest.wallDuration()))
                    BigStat(title: "Frames received", value: "\(stats.videoFramesReceived)")
                    BigStat(title: "Frames processed", value: "\(stats.framesAnalyzed)")
                    BigStat(title: "Keyframes generated", value: "\(stats.keyframesSaved)")
                    BigStat(title: "Dropped frames", value: "\(stats.droppedFrames)")
                    BigStat(title: "Avg processing FPS", value: String(format: "%.1f", stats.averageProcessingFPS))
                }
                .padding(.vertical, 4)
            }

            Section("Pipeline") {
                LabeledContent("Avg received FPS", value: String(format: "%.1f", stats.averageReceivedFPS))
                LabeledContent("Skipped by analysis throttle", value: "\(stats.framesSkippedByThrottle)")
                LabeledContent("Frames encoded to buffer", value: "\(stats.framesEncoded)")
                ForEach(FrameDropReason.allCases, id: \.self) { reason in
                    if stats.dropCount(reason) > 0 {
                        LabeledContent("Dropped: \(reason.rawValue)", value: "\(stats.dropCount(reason))")
                    }
                }
                LabeledContent("Avg analysis time", value: String(format: "%.2f ms", stats.averageAnalysisMilliseconds))
                LabeledContent("Video", value: "\(stats.videoWidth)×\(stats.videoHeight), orientation \(stats.videoOrientation)")
                LabeledContent("Near-black frames", value: stats.blackFramePercent.map { String(format: "%lld (%.2f %%)", stats.nearBlackFrames, $0) } ?? "not measured")
                LabeledContent("Peak / avg memory", value: MetricFormat.memory(peak: stats.peakMemoryFootprintBytes, average: stats.averageMemoryFootprintBytes))
                LabeledContent("CPU avg / peak", value: MetricFormat.cpu(average: stats.averageCPUPercent, peak: stats.peakCPUPercent))
                LabeledContent("Thermal (worst / end)", value: MetricFormat.thermal(worst: stats.worstThermalState, current: stats.thermalState))
                LabeledContent("Capture latency avg / max", value: MetricFormat.latency(average: stats.averageCaptureLatency, max: stats.maxCaptureLatency))
                LabeledContent("Audio samples (app / mic)", value: "\(stats.audioAppSamples) / \(stats.audioMicSamples)")
                if let minimum = stats.minimumMemoryAvailableBytes {
                    LabeledContent("Lowest memory headroom", value: ByteCountFormatter.string(fromByteCount: minimum, countStyle: .memory))
                }
                if stats.storageErrors > 0 {
                    LabeledContent("Storage errors", value: "\(stats.storageErrors)")
                }
                LabeledContent("Source", value: manifest.source.mechanism)
                if let device = manifest.source.deviceModel {
                    LabeledContent("Device", value: device)
                }
            }

            Section {
                LabeledContent("Segments written / evicted", value: "\(stats.segmentsWritten) / \(stats.segmentsEvicted)")
                LabeledContent("Encoded", value: ByteCountFormatter.string(fromByteCount: stats.bytesEncoded, countStyle: .file))
                LabeledContent("Buffer on disk (peak)", value: stats.peakRollingBufferBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "not measured")
                if manifest.videoPurged {
                    Label("Video deleted after the session (Don't Save Video).", systemImage: "eye.slash")
                } else {
                    LabeledContent("Kept at end", value: String(format: "%.0f s in %ld segments", stats.rollingBufferSeconds, manifest.bufferedSegments.count))
                    NavigationLink("Play rolling buffer") {
                        SegmentListView(sessionID: manifest.id, segments: manifest.bufferedSegments)
                    }
                    .disabled(manifest.bufferedSegments.isEmpty)
                }
            } header: {
                Text("Rolling video buffer")
            } footer: {
                Text("Only the last \(Int(manifest.settings.rollingBufferSeconds)) s of video are kept on disk while capturing; older segments are deleted continuously.")
            }

            Section("Keyframes") {
                if manifest.keyframesPurged {
                    Label("Keyframes deleted after the session.", systemImage: "eye.slash")
                } else {
                    KeyframeGrid(sessionID: manifest.id)
                }
            }

            MatchAnalysisSection(sessionID: manifest.id)

            Section {
                NavigationLink("Device test result") { DeviceTestReportView(sessionID: manifest.id) }
            } footer: {
                Text("Record the physical-device checklist for this session and copy it as one block.")
            }

            Section("Timeline") {
                NavigationLink("Event timeline (\(manifest.eventCount))") {
                    EventTimelineView(sessionID: manifest.id)
                }
            }

            Section {
                if !manifest.videoPurged {
                    Button("Delete video only") { model.deleteVideo(manifest.id) }
                }
                Button("Delete session", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("On disk: \(ByteCountFormatter.string(fromByteCount: model.diskUsage(for: manifest.id), countStyle: .file))")
            }
        }
        .navigationTitle("Session Summary")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this session, including its video, keyframes and events?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.deleteSession(manifest.id)
                dismiss()
            }
        }
    }
}

struct BigStat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct KeyframeGrid: View {
    @Environment(CoachModel.self) private var model
    let sessionID: UUID

    var body: some View {
        let keyframes = model.keyframes(for: sessionID)
        if keyframes.isEmpty {
            Text("No keyframes").foregroundStyle(.secondary)
        } else if let directory = model.directory(for: sessionID) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(keyframes) { keyframe in
                        VStack(alignment: .leading, spacing: 4) {
                            KeyframeImage(url: directory.keyframeURL(keyframe.fileName))
                                .frame(width: 180, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("\(SessionTimeFormatter.string(keyframe.timestamp))  \(keyframe.reason.rawValue)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 124)
        }
    }
}

struct KeyframeImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 360, height: 200))
            }.value
        }
    }
}

struct SegmentListView: View {
    @Environment(CoachModel.self) private var model
    let sessionID: UUID
    let segments: [VideoSegment]
    @State private var player = AVPlayer()
    @State private var selected: Int?

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
            List(segments) { segment in
                Button {
                    selected = segment.id
                } label: {
                    HStack {
                        Text("\(SessionTimeFormatter.string(segment.start)) – \(SessionTimeFormatter.string(segment.end))")
                            .font(.body.monospacedDigit())
                        Spacer()
                        Text("\(segment.frameCount) fr").foregroundStyle(.secondary)
                        if selected == segment.id {
                            Image(systemName: "play.fill").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Rolling buffer")
        .onChange(of: selected) { _, id in
            guard let id, let segment = segments.first(where: { $0.id == id }),
                  let directory = model.directory(for: sessionID) else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: directory.segmentURL(segment.fileName)))
            player.play()
        }
        .onAppear { selected = segments.last?.id }
    }
}
