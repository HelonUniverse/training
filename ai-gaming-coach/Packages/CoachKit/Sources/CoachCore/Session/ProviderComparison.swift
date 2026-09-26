import Foundation

/// A/B aggregate of real capture sessions per provider, for the decision
/// gate between ReplayKit and ScreenCaptureKit. Built only from recorded
/// sessions. With no sessions for a provider, every metric is nil and the
/// UI says so, so there are no placeholder or example numbers.
public struct ProviderComparison: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var provider: CaptureProviderKind
        public var sessions: Int
        public var totalActiveSeconds: Double
        /// Duration-weighted means across sessions.
        public var inputFPS: Double?
        public var processedFPS: Double?
        public var droppedPercent: Double?
        public var blackFramePercent: Double?
        public var peakMemoryBytes: Int64?
        public var averageMemoryBytes: Double?
        public var averageCPUPercent: Double?
        public var worstThermalState: ThermalState?
        public var averageLatency: Double?
        public var maxLatency: Double?
        public var finishedNormally: Int
        public var failed: Int
        public var terminated: Int
        public var failureReasons: [String]
        public var fortniteDegradedYes: Int
        public var fortniteDegradedNo: Int
        public var fortniteAudioIssues: Int
        public var captureSurvivalFailures: Int
        public var performanceNotes: [String]

        public var hasData: Bool { sessions > 0 }
    }

    public var columns: [Column]

    /// Sessions that received no frames (e.g. a picker that was dismissed)
    /// or are still running are ignored.
    public init(sessions: [(manifest: SessionManifest, notes: DeviceTestNotes)],
                providers: [CaptureProviderKind] = [.replayKit, .screenCaptureKit],
                now: Date = Date()) {
        columns = providers.map { provider in
            let relevant = sessions.filter {
                CaptureProviderKind(mechanism: $0.manifest.source.mechanism) == provider
                    && $0.manifest.statistics.videoFramesReceived > 0
                    && !$0.manifest.isLive(now: now)
            }
            return Self.column(provider, relevant, now: now)
        }
    }

    public func column(_ provider: CaptureProviderKind) -> Column? {
        columns.first { $0.provider == provider }
    }

    private static func column(_ provider: CaptureProviderKind, _ sessions: [(manifest: SessionManifest, notes: DeviceTestNotes)], now: Date) -> Column {
        let stats = sessions.map(\.manifest.statistics)
        let weights = stats.map(\.activeDuration)
        let totalSeconds = weights.reduce(0, +)

        func weighted(_ values: [Double?]) -> Double? {
            let pairs = zip(values, weights).compactMap { value, weight in value.map { ($0, weight) } }
            let weightSum = pairs.reduce(0) { $0 + $1.1 }
            guard !pairs.isEmpty, weightSum > 0 else { return nil }
            return pairs.reduce(0) { $0 + $1.0 * $1.1 } / weightSum
        }

        let received = stats.reduce(Int64(0)) { $0 + $1.videoFramesReceived }
        let dropped = stats.reduce(Int64(0)) { $0 + $1.droppedFrames }
        let probed = stats.filter { $0.blackFramePercent != nil }
        let probedFrames = probed.reduce(Int64(0)) { $0 + $1.framesAnalyzed }
        let blackFrames = probed.reduce(Int64(0)) { $0 + $1.nearBlackFrames }
        let latencySamples = stats.compactMap(\.captureLatencySamples).reduce(0, +)
        let latencySum = stats.compactMap(\.captureLatencySum).reduce(0, +)
        let notes = sessions.map(\.notes)
        let survival: [KeyPath<DeviceTestNotes, ManualObservation>] = [
            \.survivedOpeningFortnite, \.survivedJoiningMatch, \.survivedCombat,
            \.survivedAppSwitching, \.survivedReturningToCoach,
        ]

        return Column(
            provider: provider,
            sessions: sessions.count,
            totalActiveSeconds: totalSeconds,
            inputFPS: weighted(stats.map { $0.averageReceivedFPS }),
            processedFPS: weighted(stats.map { $0.averageProcessingFPS }),
            droppedPercent: received > 0 ? Double(dropped) / Double(received) * 100 : nil,
            blackFramePercent: probedFrames > 0 ? Double(blackFrames) / Double(probedFrames) * 100 : nil,
            peakMemoryBytes: stats.compactMap(\.peakMemoryFootprintBytes).max(),
            averageMemoryBytes: weighted(stats.map(\.averageMemoryFootprintBytes)),
            averageCPUPercent: weighted(stats.map(\.averageCPUPercent)),
            worstThermalState: stats.compactMap(\.worstThermalState).max(),
            averageLatency: latencySamples > 0 ? latencySum / Double(latencySamples) : nil,
            maxLatency: stats.compactMap(\.maxCaptureLatency).max(),
            finishedNormally: sessions.filter { $0.manifest.status == .finished }.count,
            failed: sessions.filter { $0.manifest.status == .failed }.count,
            terminated: sessions.filter { $0.manifest.status == .running || $0.manifest.status == .paused }.count,
            failureReasons: sessions.compactMap(\.manifest.failureReason),
            fortniteDegradedYes: notes.filter { $0.fortniteFrameRateDegraded == .yes }.count,
            fortniteDegradedNo: notes.filter { $0.fortniteFrameRateDegraded == .no }.count,
            fortniteAudioIssues: notes.filter { $0.fortniteAudioNormal == .no }.count,
            captureSurvivalFailures: notes.reduce(0) { count, note in
                count + survival.filter { note[keyPath: $0] == .no }.count + (note.broadcastStoppedUnexpectedly == .yes ? 1 : 0)
            },
            performanceNotes: notes.map(\.fortnitePerformanceNotes).filter { !$0.isEmpty }
        )
    }

    /// CAPTURE PROVIDER COMPARISON block for the decision gate.
    public func text() -> String {
        var lines = ["CAPTURE PROVIDER COMPARISON (real device sessions only)"]
        for column in columns {
            lines.append("")
            lines.append("\(column.provider.displayName):")
            guard column.hasData else {
                lines.append("  no completed device session recorded")
                continue
            }
            func value(_ number: Double?, _ format: String) -> String {
                number.map { String(format: format, $0) } ?? "not measured"
            }
            lines += [
                "  sessions: \(column.sessions) (\(SessionTimeFormatter.duration(column.totalActiveSeconds)) of capture)",
                "  stability: \(column.finishedNormally) finished, \(column.failed) failed, \(column.terminated) terminated\(column.failureReasons.isEmpty ? "" : " — " + column.failureReasons.joined(separator: "; "))",
                "  input FPS: \(value(column.inputFPS, "%.1f")) · processed FPS: \(value(column.processedFPS, "%.1f"))",
                "  dropped: \(value(column.droppedPercent, "%.2f %%")) · black frames: \(value(column.blackFramePercent, "%.2f %%"))",
                "  memory: peak \(value(column.peakMemoryBytes.map { Double($0) / 1_048_576 }, "%.1f MB")), avg \(value(column.averageMemoryBytes.map { $0 / 1_048_576 }, "%.1f MB"))",
                "  CPU avg: \(value(column.averageCPUPercent, "%.0f %%")) · worst thermal: \(column.worstThermalState?.rawValue ?? "not measured")",
                "  capture latency: avg \(value(column.averageLatency.map { $0 * 1000 }, "%.1f ms")), max \(value(column.maxLatency.map { $0 * 1000 }, "%.1f ms"))",
                "  Fortnite frame rate degraded: yes \(column.fortniteDegradedYes), no \(column.fortniteDegradedNo) · audio issues: \(column.fortniteAudioIssues) · capture survival failures: \(column.captureSurvivalFailures)",
            ]
            if !column.performanceNotes.isEmpty {
                lines.append("  notes: " + column.performanceNotes.joined(separator: " | "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
