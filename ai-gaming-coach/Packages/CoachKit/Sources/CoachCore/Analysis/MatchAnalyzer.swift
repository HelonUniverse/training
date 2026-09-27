import Foundation

/// A frame prepared for analysis: an upright JPEG and its session time.
public struct AnalysisImage: Sendable {
    public var time: Double
    public var jpeg: Data
    public var fromVideo: Bool

    public init(time: Double, jpeg: Data, fromVideo: Bool) {
        self.time = time
        self.jpeg = jpeg
        self.fromVideo = fromVideo
    }
}

public struct AnalysisProgress: Equatable, Sendable {
    public var segmentsDone: Int
    public var segmentsTotal: Int
    public var writingSummary: Bool
}

/// Two-stage match analysis ("map, then reduce"):
/// 1. frames are split into stretches of about a minute; each stretch is
///    sent with its timestamps and the model returns `SegmentNotes`;
/// 2. all notes plus session facts go into one text-only call that returns
///    the `MatchAnalysisContent`.
/// Splitting keeps every request small, lets stretches run in parallel, and
/// keeps the timeline intact for the final call.
public struct MatchAnalyzer: Sendable {
    public var client: ResponsesClient
    public var model: String
    public var language: String
    public var framesPerSegment: Int
    public var maxConcurrentRequests: Int
    public var imageDetail: String

    public init(client: ResponsesClient, model: String, language: String = "es",
                framesPerSegment: Int = 60, maxConcurrentRequests: Int = 4, imageDetail: String = "low") {
        self.client = client
        self.model = model
        self.language = language
        self.framesPerSegment = max(1, framesPerSegment)
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.imageDetail = imageDetail
    }

    public func analyze(
        frames: [AnalysisImage],
        manifest: SessionManifest,
        progress: @escaping @Sendable (AnalysisProgress) -> Void = { _ in }
    ) async throws -> MatchAnalysis {
        let frames = frames.sorted { $0.time < $1.time }
        guard !frames.isEmpty else { throw AnalysisError.noFrames }

        let chunks = stride(from: 0, to: frames.count, by: framesPerSegment).map {
            Array(frames[$0..<min($0 + framesPerSegment, frames.count)])
        }
        progress(AnalysisProgress(segmentsDone: 0, segmentsTotal: chunks.count, writingSummary: false))

        // Stage 1, a few requests at a time.
        var notes = [SegmentNotes?](repeating: nil, count: chunks.count)
        var usage = TokenUsage()
        var done = 0
        try await withThrowingTaskGroup(of: (Int, SegmentNotes, TokenUsage).self) { group in
            var next = 0
            while next < chunks.count || done < chunks.count {
                // Keep up to maxConcurrentRequests stretches in flight.
                while next < chunks.count, next - done < maxConcurrentRequests {
                    let index = next
                    let chunk = chunks[index]
                    group.addTask {
                        let (note, used) = try await self.segmentNotes(for: chunk)
                        return (index, note, used)
                    }
                    next += 1
                }
                guard let (index, note, used) = try await group.next() else { break }
                notes[index] = note
                usage = usage + used
                done += 1
                progress(AnalysisProgress(segmentsDone: done, segmentsTotal: chunks.count, writingSummary: false))
            }
        }
        let segments = notes.compactMap { $0 }

        // Stage 2.
        progress(AnalysisProgress(segmentsDone: chunks.count, segmentsTotal: chunks.count, writingSummary: true))
        let request = ResponsesRequest(
            model: model,
            instructions: AnalysisPrompts.matchInstructions(language: language),
            content: [.text(matchInput(segments: segments, manifest: manifest, frames: frames))],
            schemaName: "match_analysis",
            schema: AnalysisPrompts.matchSchema,
            maxOutputTokens: 16_000
        )
        let reply = try await client.send(request)
        usage = usage + reply.tokenUsage
        let content: MatchAnalysisContent = try Self.decode(reply)

        return MatchAnalysis(
            generatedAt: Date(),
            provider: "OpenAI",
            model: model,
            framesAnalyzed: frames.count,
            framesFromVideo: frames.filter(\.fromVideo).count,
            framesFromKeyframes: frames.filter { !$0.fromVideo }.count,
            secondsCovered: (frames.last?.time ?? 0) - (frames.first?.time ?? 0),
            usage: usage,
            segments: segments,
            content: content
        )
    }

    private func segmentNotes(for chunk: [AnalysisImage]) async throws -> (SegmentNotes, TokenUsage) {
        let start = chunk.first?.time ?? 0
        let end = chunk.last?.time ?? start
        var content: [ResponsesRequest.Content] = [.text(AnalysisPrompts.segmentHeader(start: start, end: end, frameCount: chunk.count))]
        for frame in chunk {
            content.append(.text(AnalysisPrompts.frameLabel(frame.time)))
            content.append(.image(dataURL: "data:image/jpeg;base64," + frame.jpeg.base64EncodedString(), detail: imageDetail))
        }
        let request = ResponsesRequest(
            model: model,
            instructions: AnalysisPrompts.segmentInstructions(language: language),
            content: content,
            schemaName: "segment_notes",
            schema: AnalysisPrompts.segmentSchema,
            maxOutputTokens: 8_000
        )
        let reply = try await client.send(request)
        struct Body: Decodable {
            var phase: String
            var summary: String
            var events: [SegmentNotes.Event]
            var notes_for_coach: [String]
        }
        let body: Body = try Self.decode(reply)
        return (SegmentNotes(start: start, end: end, phase: body.phase, summary: body.summary,
                             events: body.events.sorted { $0.t < $1.t }, notes_for_coach: body.notes_for_coach),
                reply.tokenUsage)
    }

    func matchInput(segments: [SegmentNotes], manifest: SessionManifest, frames: [AnalysisImage]) -> String {
        let stats = manifest.statistics
        var facts = [
            "Game: \(manifest.gameID)",
            "Session length: \(SessionTimeFormatter.duration(stats.mediaDuration))",
            "Frames analysed: \(frames.count) (\(frames.filter(\.fromVideo).count) from video at ~1 fps, \(frames.filter { !$0.fromVideo }.count) from 5-second keyframes)",
            "Capture resolution during play: \(stats.videoWidth)x\(stats.videoHeight)",
        ]
        if let thermal = stats.worstThermalState { facts.append("Device thermal state reached: \(thermal.rawValue)") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let notesJSON = (try? encoder.encode(segments)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return "SESSION FACTS\n" + facts.joined(separator: "\n") + "\n\nSTRETCH NOTES (JSON, times in seconds)\n" + notesJSON
    }

    static func decode<T: Decodable>(_ reply: ResponsesReply) throws -> T {
        guard let text = reply.text, !text.isEmpty else {
            throw AnalysisError.emptyAnswer(reply.incomplete_details?.reason ?? reply.status ?? "unknown")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw AnalysisError.malformedAnswer(String(describing: error).prefix(200).description)
        }
    }
}
