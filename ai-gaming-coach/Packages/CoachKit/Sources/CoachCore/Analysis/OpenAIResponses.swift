import Foundation

/// Arbitrary JSON, used for JSON Schemas in requests.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
}

/// Request body for OpenAI's Responses API (`POST /v1/responses`), limited
/// to what the match analysis uses: instructions, one user message of text
/// and images, and a strict JSON Schema for the answer.
public struct ResponsesRequest: Encodable, Sendable {
    public struct Message: Encodable, Sendable {
        public var role = "user"
        public var content: [Content]
    }

    public enum Content: Encodable, Sendable {
        case text(String)
        /// `detail` is "low", "high", "auto" or "original".
        case image(dataURL: String, detail: String)

        private enum Keys: String, CodingKey { case type, text, image_url, detail }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let text):
                try container.encode("input_text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let url, let detail):
                try container.encode("input_image", forKey: .type)
                try container.encode(url, forKey: .image_url)
                try container.encode(detail, forKey: .detail)
            }
        }
    }

    public struct TextFormat: Encodable, Sendable {
        public struct Format: Encodable, Sendable {
            public var type = "json_schema"
            public var name: String
            public var schema: JSONValue
            public var strict = true
        }
        public var format: Format
    }

    public struct Reasoning: Encodable, Sendable {
        public var effort: String
    }

    public var model: String
    public var instructions: String
    public var input: [Message]
    public var text: TextFormat
    public var reasoning: Reasoning?
    public var max_output_tokens: Int
    /// Don't keep the request on OpenAI's side for later retrieval.
    public var store = false

    public init(model: String, instructions: String, content: [Content], schemaName: String, schema: JSONValue, maxOutputTokens: Int) {
        self.model = model
        self.instructions = instructions
        self.input = [Message(content: content)]
        self.text = TextFormat(format: .init(name: schemaName, schema: schema))
        // Reasoning models (gpt-5 family, o-series) accept an effort level;
        // others reject the parameter, so it is only sent to them.
        let lower = model.lowercased()
        self.reasoning = (lower.hasPrefix("gpt-5") || lower.hasPrefix("gpt-6") || lower.hasPrefix("o")) ? Reasoning(effort: "low") : nil
        self.max_output_tokens = maxOutputTokens
    }
}

/// The parts of a Responses API reply the analysis needs.
public struct ResponsesReply: Decodable, Sendable {
    public struct OutputItem: Decodable, Sendable {
        public struct Content: Decodable, Sendable {
            public var type: String
            public var text: String?
        }
        public var type: String
        public var content: [Content]?
    }

    public struct Usage: Decodable, Sendable {
        public var input_tokens: Int?
        public var output_tokens: Int?
    }

    public struct ErrorBody: Decodable, Sendable {
        public var message: String?
        public var code: String?
    }

    public struct IncompleteDetails: Decodable, Sendable {
        public var reason: String?
    }

    public var status: String?
    public var output: [OutputItem]?
    public var output_text: String?
    public var usage: Usage?
    public var error: ErrorBody?
    public var incomplete_details: IncompleteDetails?

    /// Concatenated `output_text` parts of the assistant message(s).
    public var text: String? {
        if let output_text, !output_text.isEmpty { return output_text }
        let parts = (output ?? [])
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
        return parts.isEmpty ? nil : parts.joined()
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(inputTokens: usage?.input_tokens ?? 0, outputTokens: usage?.output_tokens ?? 0)
    }
}

/// Sends a request and returns the parsed reply. The iOS app implements it
/// with URLSession; tests use a fake.
public protocol ResponsesClient: Sendable {
    func send(_ request: ResponsesRequest) async throws -> ResponsesReply
}

public enum AnalysisError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case modelUnavailable(String)
    case rateLimited(String)
    case server(Int, String)
    case emptyAnswer(String)
    case malformedAnswer(String)
    case noFrames

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your OpenAI API key in Settings first."
        case .invalidAPIKey: return "OpenAI rejected the API key. Check it in Settings."
        case .modelUnavailable(let model): return "The model \"\(model)\" isn't available to your OpenAI account. Change it in Settings."
        case .rateLimited(let message): return "OpenAI limit or credit reached: \(message)"
        case .server(let status, let message): return "OpenAI error \(status): \(message)"
        case .emptyAnswer(let reason): return "OpenAI returned no answer (\(reason))."
        case .malformedAnswer(let detail): return "OpenAI's answer couldn't be read: \(detail)"
        case .noFrames: return "This session has no video or keyframes to analyse."
        }
    }
}
