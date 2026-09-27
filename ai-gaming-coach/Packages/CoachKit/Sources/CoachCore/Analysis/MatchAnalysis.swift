import Foundation

/// One coaching point. Observation, inference and recommendation stay
/// separate so the UI never presents a guess as a fact.
public struct CoachingInsight: Codable, Hashable, Sendable {
    public var title: String
    public var observation: String
    public var inference: String
    public var recommendation: String
    public var confidence: Double
}

public struct CriticalMoment: Codable, Hashable, Sendable {
    /// Session seconds.
    public var t: Double
    public var title: String
    public var observation: String
    public var inference: String
    public var recommendation: String
    public var confidence: Double
}

public struct CategoryAssessment: Codable, Hashable, Sendable {
    /// Combat, Weapon Selection, Positioning, Movement, Healing, Inventory,
    /// Decision Making, Awareness.
    public var category: String
    public var observation: String
    public var inference: String
    public var recommendation: String
    public var confidence: Double
}

/// The model's answer for the whole match (the JSON the final call returns).
public struct MatchAnalysisContent: Codable, Hashable, Sendable {
    public var overall_observations: [String]
    public var top_strength: CoachingInsight
    public var primary_improvement_area: CoachingInsight
    public var critical_moments: [CriticalMoment]
    public var repeated_patterns: [String]
    public var categories: [CategoryAssessment]
    public var next_practice_focus: String
    public var limitations: [String]
    public var confidence: Double
}

/// What the model saw in one stretch of the match (one chunk of frames).
public struct SegmentNotes: Codable, Hashable, Sendable {
    public struct Event: Codable, Hashable, Sendable {
        public var t: Double
        public var type: String
        public var description: String
        public var confidence: Double
    }

    public var start: Double
    public var end: Double
    public var phase: String
    public var summary: String
    public var events: [Event]
    public var notes_for_coach: [String]
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

/// A finished analysis, stored next to the session as `analysis.json`.
public struct MatchAnalysis: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var provider: String
    public var model: String
    public var framesAnalyzed: Int
    /// Frames taken from the full video vs from 5-second keyframes.
    public var framesFromVideo: Int
    public var framesFromKeyframes: Int
    public var secondsCovered: Double
    public var usage: TokenUsage
    public var segments: [SegmentNotes]
    public var content: MatchAnalysisContent
}
