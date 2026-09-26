import Foundation

/// What the platform layer should do with one incoming video frame.
public struct FrameDecision: Equatable, Sendable {
    public var frameIndex: Int64
    /// Seconds since the first video frame of the session.
    public var sessionTime: Double
    public var analyze: Bool
    public var keyframe: KeyframeReason?
}

/// Source-independent brain of a capture session.
///
/// The platform layer (the iOS broadcast extension today; Android or a PC
/// capture agent later) owns the pixels and the encoders. It reports what
/// happened to each frame, and this controller owns everything else:
/// session clock, throttling, keyframe scheduling, the rolling-buffer
/// bookkeeping, statistics, the event timeline and persistence.
///
/// Thread safety: state is guarded by a lock so frame callbacks, encoder
/// completions and analysis completions may arrive on different queues.
/// All file I/O happens on one serial queue, off the frame-delivery thread.
public final class CaptureSessionController: @unchecked Sendable {
    public let directory: SessionDirectory
    public var sessionID: UUID { directory.id }

    /// Called on the I/O queue after each manifest write (e.g. to post a
    /// Darwin notification so the app refreshes immediately).
    public var onManifestWritten: (@Sendable (SessionManifest) -> Void)?

    private let store: SessionStore
    private let now: @Sendable () -> Date
    private let metricsSampler: @Sendable () -> ProcessMetricsSample
    private let hostClock: @Sendable () -> Double?
    private let fileManager: FileManager
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "coach.capture.io", qos: .utility)

    private var manifest: SessionManifest
    private var frameGate: FrameGate
    private var keyframes: KeyframeScheduler
    private var buffer: RollingSegmentBuffer
    private var receivedMeter = RateMeter()
    private var analyzedMeter = RateMeter()
    private var originPTS: Double?
    private var lastSessionTime: Double = 0
    private var frameCounter: Int64 = 0
    private var segmentCounter = 0
    private var pausedAt: Date?
    private var lastManifestWrite: Date = .distantPast
    private var lowMemoryReported = false
    private var finished = false

    public static let manifestWriteInterval: Double = 1
    public static let nearBlackLuma: Double = 0.02
    public static let lowMemoryThresholdBytes: Int64 = 12 * 1024 * 1024

    public init(
        store: SessionStore,
        gameID: String,
        source: CaptureSourceInfo,
        settings: CaptureSettings,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        metricsSampler: @escaping @Sendable () -> ProcessMetricsSample = { ProcessMetrics.sample() },
        hostClock: @escaping @Sendable () -> Double? = { HostClock.now() }
    ) {
        let settings = settings.sanitized()
        let manifest = SessionManifest(gameID: gameID, createdAt: now(), source: source, settings: settings)
        self.store = store
        self.now = now
        self.metricsSampler = metricsSampler
        self.hostClock = hostClock
        self.fileManager = fileManager
        self.manifest = manifest
        self.directory = store.directory(for: manifest.id)
        frameGate = FrameGate(targetFPS: settings.analysisFPS)
        keyframes = KeyframeScheduler(interval: settings.keyframeIntervalSeconds)
        buffer = RollingSegmentBuffer(capacity: settings.rollingBufferSeconds)
    }

    public var settings: CaptureSettings { manifest.settings }

    /// Creates the session on disk. Call before feeding frames.
    public func start() throws {
        let snapshot = locked { manifest }
        try store.create(snapshot)
        record(MatchEvent(timestamp: 0, wallClock: snapshot.createdAt, type: .captureStarted, confidence: 1, origin: .pipeline,
                          metadata: ["source": snapshot.source.mechanism, "game": snapshot.gameID]))
    }

    // MARK: Frames

    public func videoFrame(pts: Double, width: Int, height: Int, orientation: Int) -> FrameDecision {
        let hostNow = hostClock()
        let (decision, formatEvent) = locked { () -> (FrameDecision, MatchEvent?) in
            if originPTS == nil { originPTS = pts }
            let time = max(0, pts - (originPTS ?? pts))
            lastSessionTime = time
            frameCounter += 1

            var stats = manifest.statistics
            stats.videoFramesReceived += 1
            stats.mediaDuration = time
            receivedMeter.record(at: time)
            stats.receivedFPS = receivedMeter.rate(at: time)
            stats.analyzedFPS = analyzedMeter.rate(at: time)
            if let hostNow { stats.recordLatency(hostNow - pts) }

            var formatEvent: MatchEvent?
            if stats.videoWidth != width || stats.videoHeight != height || stats.videoOrientation != orientation {
                if stats.videoWidth != 0 {
                    formatEvent = MatchEvent(timestamp: time, wallClock: now(), type: .videoFormatChanged, confidence: 1, origin: .pipeline,
                                             metadata: ["from": "\(stats.videoWidth)x\(stats.videoHeight)@\(stats.videoOrientation)",
                                                        "to": "\(width)x\(height)@\(orientation)"],
                                             relatedFrameIDs: [frameCounter])
                }
                stats.videoWidth = width
                stats.videoHeight = height
                stats.videoOrientation = orientation
            }

            let analyze = pausedAt == nil && frameGate.shouldAccept(at: time)
            if !analyze { stats.framesSkippedByThrottle += 1 }
            manifest.statistics = stats
            let keyframe = pausedAt == nil ? keyframes.reason(at: time) : nil
            return (FrameDecision(frameIndex: frameCounter, sessionTime: time, analyze: analyze, keyframe: keyframe), formatEvent)
        }
        if let formatEvent { record(formatEvent) }
        flushIfNeeded()
        return decision
    }

    public func audioSample(_ kind: AudioSourceKind) {
        locked {
            switch kind {
            case .app: manifest.statistics.audioAppSamples += 1
            case .microphone: manifest.statistics.audioMicSamples += 1
            }
        }
    }

    public func analysisCompleted(frameIndex: Int64, sessionTime: Double, duration: Double, luma: Double?) {
        locked {
            var stats = manifest.statistics
            stats.framesAnalyzed += 1
            stats.totalAnalysisSeconds += duration
            stats.maxAnalysisSeconds = max(stats.maxAnalysisSeconds, duration)
            if let luma {
                stats.lastFrameLuma = luma
                if luma < Self.nearBlackLuma { stats.nearBlackFrames += 1 }
            }
            analyzedMeter.record(at: sessionTime)
            stats.analyzedFPS = analyzedMeter.rate(at: max(sessionTime, lastSessionTime))
            manifest.statistics = stats
        }
    }

    /// A frame the source delivered without image content (for example a
    /// ScreenCaptureKit `idle` or `blank` frame). Not a received frame.
    public func sourceFrameSkipped(status: String) {
        locked {
            var counts = manifest.statistics.sourceFrameStatus ?? [:]
            counts[status, default: 0] += 1
            manifest.statistics.sourceFrameStatus = counts
        }
    }

    public func frameEncoded() {
        locked { manifest.statistics.framesEncoded += 1 }
    }

    public func frameDropped(_ reason: FrameDropReason) {
        locked { manifest.statistics.drops[reason.rawValue, default: 0] += 1 }
    }

    /// Available process memory as reported by the OS. Emits a single
    /// `memoryPressure` event when headroom first falls below the threshold.
    public func updateMemory(availableBytes: Int64) {
        let event: MatchEvent? = locked {
            manifest.statistics.memoryAvailableBytes = availableBytes
            let minimum = manifest.statistics.minimumMemoryAvailableBytes ?? availableBytes
            manifest.statistics.minimumMemoryAvailableBytes = min(minimum, availableBytes)
            if availableBytes < Self.lowMemoryThresholdBytes, !lowMemoryReported {
                lowMemoryReported = true
                return MatchEvent(timestamp: lastSessionTime, wallClock: now(), type: .memoryPressure, confidence: 1, origin: .pipeline,
                                  metadata: ["availableMB": String(format: "%.1f", Double(availableBytes) / 1_048_576)])
            }
            if availableBytes > Self.lowMemoryThresholdBytes * 2 { lowMemoryReported = false }
            return nil
        }
        if let event { record(event) }
    }

    // MARK: Rolling buffer

    /// File for the next encoded segment.
    public func nextSegmentFile() -> (id: Int, fileName: String, url: URL) {
        let id: Int = locked {
            segmentCounter += 1
            return segmentCounter
        }
        let name = String(format: "seg-%05ld.mp4", id)
        return (id, name, directory.segmentURL(name))
    }

    /// Converts a source timestamp to session seconds.
    public func sessionTime(forPTS pts: Double) -> Double {
        locked { max(0, pts - (originPTS ?? pts)) }
    }

    /// Reports a finished segment. Evicts and preserves files as needed.
    public func segmentFinished(id: Int, fileName: String, startPTS: Double, endPTS: Double, frameCount: Int, byteCount: Int64) {
        let (update, clipEvents) = locked { () -> (RollingSegmentBuffer.Update, [MatchEvent]) in
            let origin = originPTS ?? startPTS
            let segment = VideoSegment(id: id, fileName: fileName, start: max(0, startPTS - origin), end: max(0, endPTS - origin),
                                       frameCount: frameCount, byteCount: byteCount)
            let update = buffer.append(segment)
            var stats = manifest.statistics
            stats.segmentsWritten += 1
            stats.segmentsEvicted += Int64(update.evicted.count)
            stats.bytesEncoded += byteCount
            stats.rollingBufferSeconds = buffer.bufferedDuration
            stats.rollingBufferSegments = buffer.segments.count
            let bufferBytes = buffer.segments.reduce(Int64(0)) { $0 + $1.byteCount }
            stats.rollingBufferBytes = bufferBytes
            stats.peakRollingBufferBytes = max(stats.peakRollingBufferBytes ?? 0, bufferBytes)
            manifest.statistics = stats
            manifest.bufferedSegments = buffer.segments
            manifest.preservedClips.append(contentsOf: update.completedClips)
            return (update, update.completedClips.map(clipEvent))
        }
        applyFileOperations(update)
        clipEvents.forEach(record)
    }

    /// Keeps the video from `before` seconds ahead of `time` to `after`
    /// seconds past it, e.g. 15 s before a fight through 10 s after it.
    @discardableResult
    public func preserveClip(reason: String, around time: Double, before: Double, after: Double) -> UUID {
        let request = ClipRequest(reason: reason, from: max(0, time - before), to: time + after)
        let update = locked { buffer.preserve(request) }
        locked { manifest.preservedClips.append(contentsOf: update.completedClips) }
        applyFileOperations(update)
        update.completedClips.map(clipEvent).forEach(record)
        return request.id
    }

    private func clipEvent(_ clip: PreservedClip) -> MatchEvent {
        MatchEvent(timestamp: clip.requestedTo, wallClock: now(), type: .clipPreserved, confidence: 1, origin: .pipeline,
                   metadata: ["reason": clip.reason, "segments": "\(clip.segmentFileNames.count)",
                              "from": SessionTimeFormatter.string(clip.coveredFrom ?? clip.requestedFrom),
                              "to": SessionTimeFormatter.string(clip.coveredTo ?? clip.requestedTo)])
    }

    private func applyFileOperations(_ update: RollingSegmentBuffer.Update) {
        guard !update.toPreserve.isEmpty || !update.evicted.isEmpty else { return }
        let dir = directory
        let fm = fileManager
        ioQueue.async { [weak self] in
            var failures: Int64 = 0
            // Preserve first: an evicted segment may also need preserving.
            for segment in update.toPreserve {
                let source = dir.segmentURL(segment.fileName)
                let target = dir.preservedURL(segment.fileName)
                guard !fm.fileExists(atPath: target.path) else { continue }
                do {
                    // A hard link costs no extra disk and survives the
                    // deletion of the rolling copy.
                    try fm.linkItem(at: source, to: target)
                } catch {
                    do { try fm.copyItem(at: source, to: target) } catch { failures += 1 }
                }
            }
            for segment in update.evicted {
                do { try fm.removeItem(at: dir.segmentURL(segment.fileName)) } catch { failures += 1 }
            }
            if failures > 0 { self?.locked { self?.manifest.statistics.storageErrors += failures } }
        }
    }

    // MARK: Keyframes

    public func keyframeFile(frameIndex: Int64) -> (id: String, fileName: String, url: URL) {
        let id = String(format: "kf-%08lld", frameIndex)
        let name = id + ".jpg"
        return (id, name, directory.keyframeURL(name))
    }

    public func keyframeSaved(_ record: KeyframeRecord) {
        locked { manifest.statistics.keyframesSaved += 1 }
        let store = store
        let id = sessionID
        ioQueue.async { [weak self] in
            do { try store.append(record, to: id) } catch { self?.countStorageError() }
        }
    }

    public func requestKeyframe(_ reason: KeyframeReason) {
        locked { keyframes.request(reason) }
    }

    // MARK: Events

    public func record(_ event: MatchEvent) {
        locked { manifest.eventCount += 1 }
        let store = store
        let id = sessionID
        ioQueue.async { [weak self] in
            do { try store.append(event, to: id) } catch { self?.countStorageError() }
        }
    }

    /// Current session time, for events raised outside the frame callback.
    public var currentSessionTime: Double { locked { lastSessionTime } }

    // MARK: Lifecycle

    public func pause() {
        let time: Double? = locked {
            guard pausedAt == nil else { return nil }
            pausedAt = now()
            manifest.status = .paused
            return lastSessionTime
        }
        if let time { record(MatchEvent(timestamp: time, wallClock: now(), type: .capturePaused, confidence: 1, origin: .pipeline)) }
        flush()
    }

    public func resume() {
        let time: Double? = locked {
            guard let pausedAt else { return nil }
            manifest.statistics.pausedDuration += now().timeIntervalSince(pausedAt)
            self.pausedAt = nil
            manifest.status = .running
            return lastSessionTime
        }
        if let time { record(MatchEvent(timestamp: time, wallClock: now(), type: .captureResumed, confidence: 1, origin: .pipeline)) }
        flush()
    }

    /// Ends the session, applies the privacy settings and blocks until
    /// everything is on disk. Safe to call more than once.
    @discardableResult
    public func finish(failureReason: String? = nil) -> SessionManifest {
        let result: (SessionManifest, [PreservedClip])? = locked {
            guard !finished else { return nil }
            finished = true
            if let pausedAt {
                manifest.statistics.pausedDuration += now().timeIntervalSince(pausedAt)
                self.pausedAt = nil
            }
            let clips = buffer.closeAllRequests()
            manifest.preservedClips.append(contentsOf: clips)
            manifest.status = failureReason == nil ? .finished : .failed
            manifest.failureReason = failureReason
            manifest.endedAt = now()
            return (manifest, clips)
        }
        guard let (snapshot, clips) = result else { return locked { manifest } }

        clips.map(clipEvent).forEach(record)
        let stats = snapshot.statistics
        record(MatchEvent(
            timestamp: stats.mediaDuration, wallClock: now(),
            type: failureReason == nil ? .captureFinished : .captureFailed, confidence: 1, origin: .pipeline,
            metadata: [
                "framesReceived": "\(stats.videoFramesReceived)",
                "framesAnalyzed": "\(stats.framesAnalyzed)",
                "keyframes": "\(stats.keyframesSaved)",
                "dropped": "\(stats.droppedFrames)",
                "reason": failureReason ?? "",
            ]
        ))

        // Wait for queued preserve/evict/append work before purging.
        ioQueue.sync {}
        let settings = snapshot.settings
        if settings.dontSaveVideo {
            do { try store.purgeVideo(for: sessionID) } catch { countStorageError() }
            locked {
                manifest.videoPurged = true
                manifest.bufferedSegments = []
                manifest.preservedClips = manifest.preservedClips.map { var c = $0; c.segmentFileNames = []; return c }
            }
        }
        if !settings.keepKeyframes {
            do { try store.purgeKeyframes(for: sessionID) } catch { countStorageError() }
            locked { manifest.keyframesPurged = true }
        }
        flush()
        ioQueue.sync {}
        return locked { manifest }
    }

    // MARK: Persistence

    public func snapshot() -> SessionManifest { locked { manifest } }

    /// Writes the manifest if the last write is older than the interval.
    public func flushIfNeeded() {
        let due: Bool = locked {
            let current = now()
            guard current.timeIntervalSince(lastManifestWrite) >= Self.manifestWriteInterval else { return false }
            lastManifestWrite = current
            return true
        }
        guard due else { return }
        sampleProcessMetrics()
        flush()
    }

    /// Records memory, CPU and thermal state; emits an event when the
    /// thermal state changes. Runs at the manifest cadence (1 Hz).
    private func sampleProcessMetrics() {
        let sample = metricsSampler()
        let event: MatchEvent? = locked {
            let previous = manifest.statistics.thermalState
            manifest.statistics.record(sample)
            guard let current = sample.thermalState, let previous, current != previous else { return nil }
            return MatchEvent(timestamp: lastSessionTime, wallClock: now(), type: .thermalStateChanged, confidence: 1, origin: .pipeline,
                              metadata: ["from": previous.rawValue, "to": current.rawValue])
        }
        if let event { record(event) }
    }

    public func flush() {
        let snapshot: SessionManifest = locked {
            manifest.updatedAt = now()
            lastManifestWrite = manifest.updatedAt
            return manifest
        }
        let store = store
        ioQueue.async { [weak self] in
            do {
                try store.write(snapshot)
                self?.onManifestWritten?(snapshot)
            } catch {
                self?.countStorageError()
            }
        }
    }

    /// Blocks until queued file operations complete. For tests and shutdown.
    public func waitForPendingWrites() {
        ioQueue.sync {}
    }

    /// For platform-side write failures (e.g. a keyframe JPEG).
    public func reportStorageError() {
        countStorageError()
    }

    private func countStorageError() {
        locked { manifest.statistics.storageErrors += 1 }
    }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
