import Foundation

/// File layout of one session inside the shared container:
///
///     Sessions/<uuid>/
///       manifest.json     SessionManifest, rewritten atomically
///       events.jsonl      MatchEvent per line, append-only
///       keyframes.jsonl   KeyframeRecord per line, append-only
///       keyframes/        JPEG files
///       segments/         rolling-buffer MP4 segments
///       preserved/        segments kept around important moments
public struct SessionDirectory: Hashable, Sendable {
    public let id: UUID
    public let url: URL

    public var manifestURL: URL { url.appendingPathComponent("manifest.json") }
    public var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    public var keyframeIndexURL: URL { url.appendingPathComponent("keyframes.jsonl") }
    public var deviceTestNotesURL: URL { url.appendingPathComponent("device-test.json") }
    public var keyframesURL: URL { url.appendingPathComponent("keyframes", isDirectory: true) }
    public var segmentsURL: URL { url.appendingPathComponent("segments", isDirectory: true) }
    public var preservedURL: URL { url.appendingPathComponent("preserved", isDirectory: true) }

    public func segmentURL(_ fileName: String) -> URL { segmentsURL.appendingPathComponent(fileName) }
    public func preservedURL(_ fileName: String) -> URL { preservedURL.appendingPathComponent(fileName) }
    public func keyframeURL(_ fileName: String) -> URL { keyframesURL.appendingPathComponent(fileName) }
}

public enum SessionStoreError: Error, Equatable {
    case sessionNotFound(UUID)
}

/// Reads and writes sessions under a root directory. On iOS the root is the
/// App Group container, which is the only storage both the broadcast
/// extension and the main app can see.
///
/// Concurrency model: one writer (the capture process) and any number of
/// readers (the app). Manifests are written atomically (temp file + rename),
/// and JSONL readers skip a torn final line, so readers never need a lock.
public final class SessionStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let lineEncoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public var sessionsURL: URL { rootURL.appendingPathComponent("Sessions", isDirectory: true) }

    public func directory(for id: UUID) -> SessionDirectory {
        SessionDirectory(id: id, url: sessionsURL.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    // MARK: Writing (capture process)

    @discardableResult
    public func create(_ manifest: SessionManifest) throws -> SessionDirectory {
        let dir = directory(for: manifest.id)
        for url in [dir.url, dir.keyframesURL, dir.segmentsURL, dir.preservedURL] {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try write(manifest)
        return dir
    }

    public func write(_ manifest: SessionManifest) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: directory(for: manifest.id).manifestURL, options: .atomic)
    }

    public func append(_ event: MatchEvent, to session: UUID) throws {
        try appendLine(event, to: directory(for: session).eventsURL)
    }

    public func append(_ keyframe: KeyframeRecord, to session: UUID) throws {
        try appendLine(keyframe, to: directory(for: session).keyframeIndexURL)
    }

    private func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try lineEncoder.encode(value)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: url.path) {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: Reading (app)

    public func manifest(for id: UUID) throws -> SessionManifest {
        let url = directory(for: id).manifestURL
        guard fileManager.fileExists(atPath: url.path) else { throw SessionStoreError.sessionNotFound(id) }
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: url))
    }

    /// All sessions, newest first. Unreadable directories are skipped.
    public func allManifests() -> [SessionManifest] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: sessionsURL.path) else { return [] }
        return entries
            .compactMap(UUID.init(uuidString:))
            .compactMap { try? manifest(for: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func latestManifest() -> SessionManifest? { allManifests().first }

    public func events(for id: UUID) -> [MatchEvent] {
        readLines(directory(for: id).eventsURL)
    }

    public func keyframes(for id: UUID) -> [KeyframeRecord] {
        readLines(directory(for: id).keyframeIndexURL)
    }

    private func readLines<T: Decodable>(_ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // A line still being appended fails to decode and is skipped.
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }

    // MARK: Device testing

    public func deviceTestNotes(for id: UUID) -> DeviceTestNotes {
        guard let data = try? Data(contentsOf: directory(for: id).deviceTestNotesURL),
              let notes = try? decoder.decode(DeviceTestNotes.self, from: data)
        else { return DeviceTestNotes() }
        return notes
    }

    public func save(_ notes: DeviceTestNotes, for id: UUID) throws {
        try encoder.encode(notes).write(to: directory(for: id).deviceTestNotesURL, options: .atomic)
    }

    public func deviceTestReport(for id: UUID, now: Date = Date()) throws -> DeviceTestReport {
        DeviceTestReport(manifest: try manifest(for: id), notes: deviceTestNotes(for: id), now: now)
    }

    // MARK: Privacy

    /// Deletes rolling and preserved video, keeping events and metrics.
    public func purgeVideo(for id: UUID) throws {
        let dir = directory(for: id)
        try removeContents(of: dir.segmentsURL)
        try removeContents(of: dir.preservedURL)
        if var manifest = try? manifest(for: id) {
            manifest.videoPurged = true
            manifest.bufferedSegments = []
            manifest.preservedClips = manifest.preservedClips.map {
                var clip = $0
                clip.segmentFileNames = []
                return clip
            }
            try write(manifest)
        }
    }

    public func purgeKeyframes(for id: UUID) throws {
        let dir = directory(for: id)
        try removeContents(of: dir.keyframesURL)
        if fileManager.fileExists(atPath: dir.keyframeIndexURL.path) {
            try fileManager.removeItem(at: dir.keyframeIndexURL)
        }
        if var manifest = try? manifest(for: id) {
            manifest.keyframesPurged = true
            try write(manifest)
        }
    }

    /// "Delete Match".
    public func deleteSession(_ id: UUID) throws {
        let url = directory(for: id).url
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// "Delete All Gameplay Data".
    public func deleteAll() throws {
        if fileManager.fileExists(atPath: sessionsURL.path) {
            try fileManager.removeItem(at: sessionsURL)
        }
    }

    /// Bytes on disk for one session (video + keyframes + metadata).
    public func diskUsage(for id: UUID) -> Int64 {
        let url = directory(for: id).url
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func removeContents(of directory: URL) throws {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try fileManager.removeItem(at: item) }
    }
}
