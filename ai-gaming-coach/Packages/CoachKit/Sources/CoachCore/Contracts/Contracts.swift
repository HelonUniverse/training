import Foundation

// Seams for later milestones. Declared now so the capture pipeline is built
// against them from day one; Milestone 1 ships no implementation beyond the
// mock backend.

/// Identifies a supported game. Adapters register under this ID.
public struct GameID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let fortnite = GameID(rawValue: "fortnite")
}

/// A frame as the vision layer sees it, independent of CVPixelBuffer,
/// Android `Image` or a PC capture surface. The platform layer supplies the
/// pixels through `pixels`.
public struct AnalysisFrame: Sendable {
    public var index: Int64
    public var sessionTime: Double
    public var width: Int
    public var height: Int
    /// EXIF-style orientation of the pixels.
    public var orientation: Int

    public init(index: Int64, sessionTime: Double, width: Int, height: Int, orientation: Int) {
        self.index = index
        self.sessionTime = sessionTime
        self.width = width
        self.height = height
        self.orientation = orientation
    }
}

/// Game-specific knowledge (HUD layout, inventory, event rules). The engine
/// calls it; it never calls into the engine. Milestone 2 adds
/// `FortniteAdapter`; `CallOfDutyAdapter`, `ApexAdapter` and others follow
/// the same contract.
public protocol GameAdapter: Sendable {
    var gameID: GameID { get }
    /// Updates the estimated game state from one analysed frame.
    func updateState(_ state: GameState, with observation: FrameObservation) -> GameState
    /// Derives timeline events from a state transition.
    func events(from previous: GameState, to current: GameState, at time: Double) -> [MatchEvent]
}

/// Raw vision output for one frame (region crops classified, OCR digits…).
/// Filled by the platform's vision layer, interpreted by a `GameAdapter`.
public struct FrameObservation: Sendable {
    public var frame: AnalysisFrame
    public var values: [String: Estimate<String>]

    public init(frame: AnalysisFrame, values: [String: Estimate<String>] = [:]) {
        self.frame = frame
        self.values = values
    }
}

/// Deep-reasoning backend (OpenAI, Anthropic, Google, a local model…).
/// The app never talks to a provider directly.
public protocol AIBackend: Sendable {
    var name: String { get }
    func status() async -> AIBackendStatus
    func analyzeFight(_ request: FightAnalysisRequest) async throws -> FightAnalysis
}

public enum AIBackendStatus: Equatable, Sendable {
    case connected
    case mock
    case unavailable(String)
}

public struct FightAnalysisRequest: Codable, Sendable {
    public var sessionID: UUID
    public var gameID: String
    public var fightStart: Double
    public var fightEnd: Double
    public var events: [MatchEvent]
    public var keyframeFileNames: [String]
    public var clipSegmentFileNames: [String]
    public var gameState: GameState?

    public init(sessionID: UUID, gameID: String, fightStart: Double, fightEnd: Double, events: [MatchEvent],
                keyframeFileNames: [String] = [], clipSegmentFileNames: [String] = [], gameState: GameState? = nil) {
        self.sessionID = sessionID
        self.gameID = gameID
        self.fightStart = fightStart
        self.fightEnd = fightEnd
        self.events = events
        self.keyframeFileNames = keyframeFileNames
        self.clipSegmentFileNames = clipSegmentFileNames
        self.gameState = gameState
    }
}

/// Structured coaching output. Observations, inferences and recommendations
/// stay separate so the UI never presents an inference as a fact.
public struct FightAnalysis: Codable, Hashable, Sendable {
    public struct Moment: Codable, Hashable, Sendable {
        public var timestamp: Double
        public var description: String
    }

    public var observations: [String]
    public var inferences: [String]
    public var strengths: [String]
    public var improvementAreas: [String]
    public var criticalMoment: Moment?
    public var recommendation: String
    public var confidence: Double
}

/// Offline stand-in until a real provider is wired in (Milestone 4).
public struct MockAIBackend: AIBackend {
    public init() {}
    public var name: String { "Mock" }
    public func status() async -> AIBackendStatus { .mock }

    public func analyzeFight(_ request: FightAnalysisRequest) async throws -> FightAnalysis {
        FightAnalysis(
            observations: ["\(request.events.count) events recorded between \(SessionTimeFormatter.string(request.fightStart)) and \(SessionTimeFormatter.string(request.fightEnd))."],
            inferences: [],
            strengths: [],
            improvementAreas: [],
            criticalMoment: nil,
            recommendation: "Mock backend: no analysis performed.",
            confidence: 0
        )
    }
}
