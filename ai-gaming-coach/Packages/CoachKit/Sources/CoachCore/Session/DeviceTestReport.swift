import Foundation

/// An observation only a person holding the phone can make.
public enum ManualObservation: String, Codable, CaseIterable, Sendable {
    case yes
    case no
    case notTested

    public var label: String {
        switch self {
        case .yes: return "yes"
        case .no: return "no"
        case .notTested: return "not tested"
        }
    }
}

/// What the tester records by hand for one session. Stored next to the
/// session as `device-test.json`.
public struct DeviceTestNotes: Codable, Hashable, Sendable {
    /// Marketing name, e.g. "iPhone 15 Pro" (the report also carries the
    /// hardware identifier recorded automatically).
    public var iPhoneModelName: String = ""
    public var fortniteVersion: String = ""
    public var fortniteFrameRateDegraded: ManualObservation = .notTested
    public var fortniteAudioNormal: ManualObservation = .notTested
    public var survivedOpeningFortnite: ManualObservation = .notTested
    public var survivedJoiningMatch: ManualObservation = .notTested
    public var survivedCombat: ManualObservation = .notTested
    public var survivedAppSwitching: ManualObservation = .notTested
    public var survivedReturningToCoach: ManualObservation = .notTested
    public var broadcastStoppedUnexpectedly: ManualObservation = .notTested
    public var deviceNoticeablyHot: ManualObservation = .notTested
    public var fortnitePerformanceNotes: String = ""
    public var notes: String = ""

    public init() {}
}

/// DEVICE TEST RESULT: one flat record per physical-device session, so
/// results from different phones, builds and capture providers can be
/// pasted side by side. Measured values come from the session manifest;
/// anything not measured is nil and renders as "not measured".
public struct DeviceTestReport: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var sessionID: UUID
    public var recordedAt: Date
    public var captureProvider: String
    public var appVersion: String?
    // 1–3
    public var iPhoneModelName: String
    public var hardwareIdentifier: String?
    public var iOSVersion: String?
    public var fortniteVersion: String
    // 4–12
    public var sessionStatus: String
    public var failureReason: String?
    public var durationSeconds: Double
    public var framesReceived: Int64
    public var averageInputFPS: Double
    public var framesProcessed: Int64
    public var averageProcessingFPS: Double
    public var droppedFrames: Int64
    public var droppedPercent: Double
    public var droppedByReason: [String: Int64]
    public var sourceFramesWithoutImage: [String: Int64]
    public var blackFramePercent: Double?
    public var peakMemoryMB: Double?
    public var averageMemoryMB: Double?
    public var lowestMemoryHeadroomMB: Double?
    public var peakRollingBufferMB: Double?
    public var rollingBufferMBAtEnd: Double?
    public var encodedMB: Double
    public var averageCPUPercent: Double?
    public var peakCPUPercent: Double?
    public var averageCaptureLatencyMs: Double?
    public var maxCaptureLatencyMs: Double?
    // 13
    public var worstThermalState: String?
    public var thermalStateAtEnd: String?
    // 14–17
    public var notes: DeviceTestNotes
    // 18
    public var keyframes: Int64
    public var segmentsWritten: Int64
    public var videoResolution: String
    public var storageErrors: Int64

    public init(manifest: SessionManifest, notes: DeviceTestNotes, now: Date = Date()) {
        let stats = manifest.statistics
        let mb = { (bytes: Int64) in Double(bytes) / 1_048_576 }
        schemaVersion = Self.schemaVersion
        sessionID = manifest.id
        recordedAt = now
        captureProvider = CaptureProviderKind(mechanism: manifest.source.mechanism).displayName
        appVersion = manifest.source.appVersion
        iPhoneModelName = notes.iPhoneModelName
        hardwareIdentifier = manifest.source.deviceModel
        iOSVersion = manifest.source.osVersion
        fortniteVersion = notes.fortniteVersion
        sessionStatus = Self.stability(of: manifest, now: now)
        failureReason = manifest.failureReason
        durationSeconds = manifest.wallDuration(now: now)
        framesReceived = stats.videoFramesReceived
        averageInputFPS = stats.averageReceivedFPS
        framesProcessed = stats.framesAnalyzed
        averageProcessingFPS = stats.averageProcessingFPS
        droppedFrames = stats.droppedFrames
        droppedPercent = stats.droppedPercent
        droppedByReason = stats.drops
        sourceFramesWithoutImage = stats.sourceFrameStatus ?? [:]
        blackFramePercent = stats.blackFramePercent
        peakMemoryMB = stats.peakMemoryFootprintBytes.map(mb)
        averageMemoryMB = stats.averageMemoryFootprintBytes.map { $0 / 1_048_576 }
        lowestMemoryHeadroomMB = stats.minimumMemoryAvailableBytes.map(mb)
        peakRollingBufferMB = stats.peakRollingBufferBytes.map(mb)
        rollingBufferMBAtEnd = stats.rollingBufferBytes.map(mb)
        encodedMB = mb(stats.bytesEncoded)
        averageCPUPercent = stats.averageCPUPercent
        peakCPUPercent = stats.peakCPUPercent
        averageCaptureLatencyMs = stats.averageCaptureLatency.map { $0 * 1000 }
        maxCaptureLatencyMs = stats.maxCaptureLatency.map { $0 * 1000 }
        worstThermalState = stats.worstThermalState?.rawValue
        thermalStateAtEnd = stats.thermalState?.rawValue
        self.notes = notes
        keyframes = stats.keyframesSaved
        segmentsWritten = stats.segmentsWritten
        videoResolution = "\(stats.videoWidth)x\(stats.videoHeight) orientation \(stats.videoOrientation)"
        storageErrors = stats.storageErrors
    }

    /// "finished", "failed", or — for a manifest still marked running with
    /// no heartbeat — a note that the capture process died without ending
    /// the session (e.g. killed for exceeding its memory limit).
    static func stability(of manifest: SessionManifest, now: Date) -> String {
        switch manifest.status {
        case .finished: return "finished normally"
        case .failed: return "failed"
        case .running, .paused:
            return manifest.isLive(now: now) ? "still running" : "ended without finishing (capture process terminated?)"
        }
    }

    // MARK: Rendering

    /// Plain-text block for pasting into an issue, chat or spreadsheet notes.
    public func text() -> String {
        func value(_ number: Double?, _ format: String) -> String {
            number.map { String(format: format, $0) } ?? "not measured"
        }
        func text(_ string: String) -> String { string.isEmpty ? "not recorded" : string }
        func counts(_ dict: [String: Int64]) -> String {
            dict.isEmpty ? "none" : dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        let lines: [String] = [
            "DEVICE TEST RESULT (schema \(schemaVersion))",
            "session: \(sessionID.uuidString)",
            "recorded: \(ISO8601DateFormatter().string(from: recordedAt))",
            "capture provider: \(captureProvider)",
            "app version: \(appVersion ?? "unknown")",
            "",
            "1. iPhone model: \(text(iPhoneModelName)) (\(hardwareIdentifier ?? "identifier unknown"))",
            "2. iOS version: \(iOSVersion ?? "unknown")",
            "3. Fortnite version: \(text(fortniteVersion))",
            "4. session duration: \(SessionTimeFormatter.duration(durationSeconds)) (\(String(format: "%.0f", durationSeconds)) s) — \(sessionStatus)\(failureReason.map { ": \($0)" } ?? "")",
            "5. frames received: \(framesReceived)",
            "6. average input FPS: \(String(format: "%.1f", averageInputFPS))",
            "7. frames processed: \(framesProcessed) (avg \(String(format: "%.1f", averageProcessingFPS)) fps)",
            "8. dropped frames: \(droppedFrames) (\(String(format: "%.2f", droppedPercent)) %) — \(counts(droppedByReason))",
            "   source frames without image: \(counts(sourceFramesWithoutImage))",
            "9. black frames: \(value(blackFramePercent, "%.2f %%"))",
            "10. peak memory (capture process): \(value(peakMemoryMB, "%.1f MB")) · lowest headroom \(value(lowestMemoryHeadroomMB, "%.1f MB"))",
            "11. average memory (capture process): \(value(averageMemoryMB, "%.1f MB"))",
            "12. rolling-buffer disk: peak \(value(peakRollingBufferMB, "%.1f MB")), at end \(value(rollingBufferMBAtEnd, "%.1f MB")); total encoded \(String(format: "%.1f MB", encodedMB))",
            "13. thermal state: worst \(worstThermalState ?? "not measured"), at end \(thermalStateAtEnd ?? "not measured"); felt hot: \(notes.deviceNoticeablyHot.label)",
            "    CPU (capture process): avg \(value(averageCPUPercent, "%.0f %%")), peak \(value(peakCPUPercent, "%.0f %%"))",
            "    capture latency: avg \(value(averageCaptureLatencyMs, "%.1f ms")), max \(value(maxCaptureLatencyMs, "%.1f ms"))",
            "14. Fortnite frame rate visibly degraded: \(notes.fortniteFrameRateDegraded.label)",
            "15. Fortnite audio normal: \(notes.fortniteAudioNormal.label)",
            "16. capture survived — opening Fortnite: \(notes.survivedOpeningFortnite.label); joining a match: \(notes.survivedJoiningMatch.label); combat: \(notes.survivedCombat.label); app switching: \(notes.survivedAppSwitching.label); returning to Coach: \(notes.survivedReturningToCoach.label)",
            "17. broadcast stopped unexpectedly: \(notes.broadcastStoppedUnexpectedly.label)",
            "18. session summary: keyframes \(keyframes), segments \(segmentsWritten), video \(videoResolution), storage errors \(storageErrors)",
            "Fortnite performance notes: \(text(notes.fortnitePerformanceNotes))",
            "notes: \(text(notes.notes))",
        ]
        return lines.joined(separator: "\n")
    }

    /// Machine-readable form of the same record.
    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
