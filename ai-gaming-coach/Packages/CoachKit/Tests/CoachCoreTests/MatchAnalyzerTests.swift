import XCTest
@testable import CoachCore

/// Plays OpenAI: answers segment calls and the final call with canned JSON
/// and records what it was sent.
final class FakeResponsesClient: ResponsesClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [ResponsesRequest] = []
    var finalAnswer = FakeResponsesClient.validFinalAnswer

    func send(_ request: ResponsesRequest) async throws -> ResponsesReply {
        record(request)
        let json: String
        if request.text.format.name == "segment_notes" {
            let firstLabel = request.input[0].content.compactMap { content -> String? in
                if case .text(let text) = content, text.hasPrefix("t=") { return text }
                return nil
            }.first ?? ""
            json = #"{"phase":"fighting","summary":"Pelea en \#(firstLabel)","events":[{"t":65,"type":"fightStarted","description":"enemigo a corta distancia","confidence":0.7}],"notes_for_coach":["cambio de arma lento"]}"#
        } else {
            json = finalAnswer
        }
        let reply = #"{"status":"completed","output":[{"type":"reasoning","content":[]},{"type":"message","content":[{"type":"output_text","text":\#(String(decoding: try JSONEncoder().encode(json), as: UTF8.self))}]}],"usage":{"input_tokens":1000,"output_tokens":200}}"#
        return try JSONDecoder().decode(ResponsesReply.self, from: Data(reply.utf8))
    }

    private func record(_ request: ResponsesRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    static let validFinalAnswer: String = {
        let insight = #"{"title":"x","observation":"o","inference":"i","recommendation":"r","confidence":0.6}"#
        let categories = AnalysisPrompts.categories.map {
            #"{"category":"\#($0)","observation":"o","inference":"i","recommendation":"r","confidence":0.5}"#
        }.joined(separator: ",")
        return #"{"overall_observations":["a"],"top_strength":\#(insight),"primary_improvement_area":\#(insight),"critical_moments":[{"t":65,"title":"Pelea","observation":"o","inference":"i","recommendation":"r","confidence":0.7}],"repeated_patterns":[],"categories":[\#(categories)],"next_practice_focus":"practicar","limitations":["baja resolución"],"confidence":0.55}"#
    }()
}

final class MatchAnalyzerTests: XCTestCase {
    private func frames(_ count: Int) -> [AnalysisImage] {
        (0..<count).map { AnalysisImage(time: Double($0), jpeg: Data([0xFF, 0xD8, UInt8($0 % 255)]), fromVideo: $0 % 5 != 0) }
    }

    private var manifest: SessionManifest {
        var m = SessionManifest(gameID: "fortnite", createdAt: Date(), source: CaptureSourceInfo(platform: "iOS", mechanism: "x"), settings: .default)
        m.statistics.mediaDuration = 150
        return m
    }

    func testSplitsIntoMinuteStretchesAndCombines() async throws {
        let client = FakeResponsesClient()
        let analyzer = MatchAnalyzer(client: client, model: "gpt-5-mini", framesPerSegment: 60, maxConcurrentRequests: 2)
        let collected = ProgressLog()
        let analysis = try await analyzer.analyze(frames: frames(150).shuffled(), manifest: manifest) { collected.append($0) }

        XCTAssertEqual(client.requests.count, 4, "3 stretches (60+60+30) + 1 summary")
        let segmentRequests = client.requests.filter { $0.text.format.name == "segment_notes" }
        XCTAssertEqual(segmentRequests.map { $0.input[0].content.filter { if case .image = $0 { return true }; return false }.count }.sorted(),
                       [30, 60, 60])
        XCTAssertEqual(analysis.segments.map(\.start), [0, 60, 120], "notes stay in time order")
        XCTAssertEqual(analysis.framesAnalyzed, 150)
        XCTAssertEqual(analysis.framesFromKeyframes, 30)
        XCTAssertEqual(analysis.usage, TokenUsage(inputTokens: 4000, outputTokens: 800))
        XCTAssertEqual(analysis.content.categories.map(\.category), AnalysisPrompts.categories)
        XCTAssertEqual(analysis.content.critical_moments.first?.t, 65)
        XCTAssertEqual(collected.values.last, AnalysisProgress(segmentsDone: 3, segmentsTotal: 3, writingSummary: true))

        let final = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(final.text.format.name, "match_analysis")
        guard case .text(let input) = final.input[0].content[0] else { return XCTFail() }
        XCTAssertTrue(input.contains("Pelea en t=01:00 (60 s)"), "stretch notes reach the final call")
    }

    func testRequestEncodesResponsesAPIShape() throws {
        let request = ResponsesRequest(model: "gpt-5-mini", instructions: "i",
                                       content: [.text("t=00:01 (1 s)"), .image(dataURL: "data:image/jpeg;base64,AAA", detail: "low")],
                                       schemaName: "segment_notes", schema: AnalysisPrompts.segmentSchema, maxOutputTokens: 100)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "gpt-5-mini")
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let content = ((json["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["detail"] as? String, "low")
        let format = (json["text"] as! [String: Any])["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)

        let plain = ResponsesRequest(model: "gpt-4.1", instructions: "i", content: [], schemaName: "s", schema: .object([:]), maxOutputTokens: 1)
        XCTAssertNil((try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any])["reasoning"])
    }

    func testStrictSchemasRequireEveryProperty() {
        func check(_ value: JSONValue, path: String) {
            guard case .object(let dict) = value else { return }
            if case .string("object") = dict["type"], case .object(let props)? = dict["properties"] {
                guard case .array(let required)? = dict["required"] else { return XCTFail("\(path) lacks required") }
                XCTAssertEqual(Set(required.compactMap { if case .string(let s) = $0 { return s }; return nil }), Set(props.keys), path)
                XCTAssertEqual(dict["additionalProperties"], .bool(false), path)
            }
            for (key, child) in dict { check(child, path: path + "." + key) }
        }
        check(AnalysisPrompts.segmentSchema, path: "segment")
        check(AnalysisPrompts.matchSchema, path: "match")
    }

    func testTruncatedAnswerIsReportedNotCrashed() async {
        let client = FakeResponsesClient()
        client.finalAnswer = #"{"overall_observations":["a"#
        let analyzer = MatchAnalyzer(client: client, model: "m")
        do {
            _ = try await analyzer.analyze(frames: frames(3), manifest: manifest)
            XCTFail("should throw")
        } catch let error as AnalysisError {
            guard case .malformedAnswer = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testNoFrames() async {
        do {
            _ = try await MatchAnalyzer(client: FakeResponsesClient(), model: "m").analyze(frames: [], manifest: manifest)
            XCTFail()
        } catch { XCTAssertEqual(error as? AnalysisError, .noFrames) }
    }

    func testAnalysisPersistsAndOldSettingsDecode() throws {
        // Settings written before keepFullMatchVideo existed still decode.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CaptureSettings.default)) as! [String: Any]
        json["keepFullMatchVideo"] = nil
        let old = try JSONDecoder().decode(CaptureSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.keepFullMatchVideo)
        XCTAssertEqual(CaptureSettings.default.effectiveBufferSeconds, CaptureSettings.fullMatchMaxSeconds)

        // Sessions from before the orientation fix are flagged for rotation.
        var source = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CaptureSourceInfo(platform: "iOS", mechanism: CaptureProviderKind.replayKit.rawValue))) as! [String: Any]
        XCTAssertFalse(try JSONDecoder().decode(CaptureSourceInfo.self, from: JSONSerialization.data(withJSONObject: source)).needsLegacyRotation)
        source["displayOrientationCorrected"] = nil
        XCTAssertTrue(try JSONDecoder().decode(CaptureSourceInfo.self, from: JSONSerialization.data(withJSONObject: source)).needsLegacyRotation)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [AnalysisProgress] = []
    func append(_ value: AnalysisProgress) { lock.lock(); values.append(value); lock.unlock() }
}
