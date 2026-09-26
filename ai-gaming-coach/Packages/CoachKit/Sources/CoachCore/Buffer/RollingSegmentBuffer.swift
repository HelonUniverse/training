import Foundation

/// One encoded chunk of gameplay video on disk. Times are session seconds.
public struct VideoSegment: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var fileName: String
    public var start: Double
    public var end: Double
    public var frameCount: Int
    public var byteCount: Int64

    public init(id: Int, fileName: String, start: Double, end: Double, frameCount: Int, byteCount: Int64) {
        self.id = id
        self.fileName = fileName
        self.start = start
        self.end = end
        self.frameCount = frameCount
        self.byteCount = byteCount
    }

    public var duration: Double { max(0, end - start) }

    func overlaps(_ from: Double, _ to: Double) -> Bool {
        start < to && end > from
    }
}

/// A request to keep the video around an event, e.g. 15 s before a fight
/// through 10 s after it ends. Open-ended until `to` is known.
public struct ClipRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var reason: String
    public var from: Double
    public var to: Double

    public init(id: UUID = UUID(), reason: String, from: Double, to: Double) {
        self.id = id
        self.reason = reason
        self.from = from
        self.to = to
    }
}

/// A finished preserved clip: the list of segments that cover a request.
public struct PreservedClip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var reason: String
    public var requestedFrom: Double
    public var requestedTo: Double
    public var segmentFileNames: [String]
    /// What was actually available. Can start later than requested if the
    /// buffer had already evicted the earliest part.
    public var coveredFrom: Double?
    public var coveredTo: Double?
}

/// Bookkeeping for the circular video buffer. Video lives on disk as short
/// segments; this type only decides which files to keep, evict or preserve.
/// It never touches pixel data, so memory stays flat however long the match.
public struct RollingSegmentBuffer: Sendable {
    public struct Update: Equatable, Sendable {
        /// Segments that fell out of the window. Delete their files.
        public var evicted: [VideoSegment] = []
        /// Segments to copy/link into preserved storage before eviction.
        public var toPreserve: [VideoSegment] = []
        /// Clip requests whose time range is now fully covered.
        public var completedClips: [PreservedClip] = []
    }

    public let capacity: Double
    public private(set) var segments: [VideoSegment] = []
    public private(set) var openRequests: [ClipRequest] = []
    private var preservedIDs: Set<Int> = []
    private var coverage: [UUID: [VideoSegment]] = [:]

    public init(capacity: Double) {
        self.capacity = capacity
    }

    public var bufferedDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    public var oldestTime: Double? { segments.first?.start }
    public var newestTime: Double? { segments.last?.end }

    /// Adds a finished segment and evicts old ones while keeping at least
    /// `capacity` seconds of video.
    public mutating func append(_ segment: VideoSegment) -> Update {
        var update = Update()
        segments.append(segment)
        segments.sort { $0.start < $1.start }
        matchOpenRequests(with: [segment], into: &update)
        completeRequests(into: &update)

        while let oldest = segments.first, bufferedDuration - oldest.duration >= capacity {
            segments.removeFirst()
            update.evicted.append(oldest)
        }
        return update
    }

    /// Starts preserving video for `request`. Segments already buffered that
    /// overlap it are preserved immediately; future ones as they arrive.
    public mutating func preserve(_ request: ClipRequest) -> Update {
        var update = Update()
        openRequests.append(request)
        coverage[request.id] = []
        matchOpenRequests(with: segments, into: &update)
        completeRequests(into: &update)
        return update
    }

    /// Closes every open request with whatever has been captured, e.g. when
    /// the session ends before a clip's post-event window elapsed.
    public mutating func closeAllRequests() -> [PreservedClip] {
        let clips = openRequests.map(makeClip)
        openRequests.removeAll()
        coverage.removeAll()
        return clips
    }

    private mutating func matchOpenRequests(with candidates: [VideoSegment], into update: inout Update) {
        for request in openRequests {
            for segment in candidates where segment.overlaps(request.from, request.to) {
                if !(coverage[request.id]?.contains(where: { $0.id == segment.id }) ?? false) {
                    coverage[request.id, default: []].append(segment)
                }
                if preservedIDs.insert(segment.id).inserted {
                    update.toPreserve.append(segment)
                }
            }
        }
    }

    private mutating func completeRequests(into update: inout Update) {
        guard let newest = newestTime else { return }
        let done = openRequests.filter { newest >= $0.to }
        for request in done {
            update.completedClips.append(makeClip(request))
            coverage[request.id] = nil
        }
        openRequests.removeAll { newest >= $0.to }
    }

    private func makeClip(_ request: ClipRequest) -> PreservedClip {
        let covered = (coverage[request.id] ?? []).sorted { $0.start < $1.start }
        return PreservedClip(
            id: request.id,
            reason: request.reason,
            requestedFrom: request.from,
            requestedTo: request.to,
            segmentFileNames: covered.map(\.fileName),
            coveredFrom: covered.first?.start,
            coveredTo: covered.last?.end
        )
    }
}
