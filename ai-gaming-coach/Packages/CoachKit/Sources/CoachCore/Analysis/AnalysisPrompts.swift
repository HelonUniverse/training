import Foundation

/// Instructions and JSON Schemas for the two kinds of calls: one per stretch
/// of frames ("segment notes"), then one to write the match analysis from
/// all the notes. Kept here, platform-free, so they are unit-tested.
public enum AnalysisPrompts {
    public static let categories = [
        "Combat", "Weapon Selection", "Positioning", "Movement",
        "Healing", "Inventory", "Decision Making", "Awareness",
    ]

    public static let eventTypes = [
        "matchStarted", "busJump", "landing", "looting", "enemyDetected", "fightStarted", "fightEnded",
        "shotFired", "weaponChanged", "damageReceived", "damageDealt", "shieldBroken", "healing",
        "elimination", "knocked", "playerDeath", "spectating", "stormEvent", "rotation", "vehicle",
        "inventoryChanged", "menuOrLobby", "other",
    ]

    static func languageName(_ code: String) -> String {
        code.lowercased().hasPrefix("es") ? "Spanish" : "English"
    }

    // MARK: Segment call

    public static func segmentInstructions(language: String) -> String {
        """
        You are an expert Fortnite coach reviewing screen captures from a player's iPhone. The mode is usually \
        Zero Build. You receive frames in time order, sampled about once per second (sometimes every 5 s). Each \
        frame is preceded by its timestamp in the session, as "t=MM:SS (N s)".

        Describe what happens in this stretch of the session, reading the HUD where it is legible: health and \
        shield bars, the selected hotbar slot and item, ammo, eliminations counter, storm timer, minimap, kill \
        feed, damage numbers, and on-screen prompts. Frames may be low resolution: when something can't be read, \
        say so instead of guessing. Some frames show menus, the lobby, the coaching app or the iPhone home screen; \
        label those phases instead of inventing gameplay.

        Rules:
        - Report only what is visible or directly implied by consecutive frames. Never invent events.
        - Use the timestamps given (seconds) for every event.
        - confidence is 0–1: how sure you are that the event happened as described.
        - Write all free text in \(languageName(language)).
        """
    }

    public static func segmentHeader(start: Double, end: Double, frameCount: Int) -> String {
        "Stretch \(SessionTimeFormatter.clock(start))–\(SessionTimeFormatter.clock(end)) of the session, \(frameCount) frames."
    }

    public static func frameLabel(_ t: Double) -> String {
        "t=\(SessionTimeFormatter.clock(t)) (\(Int(t.rounded())) s)"
    }

    public static let segmentSchema: JSONValue = object([
        "phase": .object(["type": .string("string"),
                          "description": .string("Main phase: menu/lobby, bus, landing, looting, rotating, fighting, healing, spectating, not in game, mixed.")]),
        "summary": .object(["type": .string("string")]),
        "events": .object([
            "type": .string("array"),
            "items": object([
                "t": .object(["type": .string("number"), "description": .string("Session time in seconds.")]),
                "type": .object(["type": .string("string"), "enum": .array(eventTypes.map(JSONValue.string))]),
                "description": .object(["type": .string("string")]),
                "confidence": .object(["type": .string("number")]),
            ]),
        ]),
        "notes_for_coach": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
    ])

    // MARK: Final call

    public static func matchInstructions(language: String) -> String {
        """
        You are an expert Fortnite coach. You receive notes written by a vision model that watched a player's \
        match from screen captures, stretch by stretch, plus session facts. Write evidence-based coaching.

        Rules:
        - Every point must cite timestamps (MM:SS) and what was seen. Avoid generic advice such as "improve \
        your aim" unless the notes show concrete evidence.
        - Keep OBSERVATION (what the notes say was seen), INFERENCE (what probably happened or why) and \
        RECOMMENDATION (what to practise or do differently) separate.
        - Never state causation when you only have correlation; say "may have" or "appears to".
        - If the notes show little gameplay (menus, lobby, low-resolution frames), say so in limitations and \
        lower your confidence instead of filling gaps.
        - categories must contain exactly these, in this order: \(categories.joined(separator: ", ")). When a \
        category has no evidence, say so and use a low confidence.
        - critical_moments: at most 6, ordered by time; t in seconds.
        - confidence values are 0–1.
        - Write all free text in \(languageName(language)).
        """
    }

    public static let matchSchema: JSONValue = {
        let insight = object([
            "title": .object(["type": .string("string")]),
            "observation": .object(["type": .string("string")]),
            "inference": .object(["type": .string("string")]),
            "recommendation": .object(["type": .string("string")]),
            "confidence": .object(["type": .string("number")]),
        ])
        let moment = object([
            "t": .object(["type": .string("number")]),
            "title": .object(["type": .string("string")]),
            "observation": .object(["type": .string("string")]),
            "inference": .object(["type": .string("string")]),
            "recommendation": .object(["type": .string("string")]),
            "confidence": .object(["type": .string("number")]),
        ])
        let category = object([
            "category": .object(["type": .string("string"), "enum": .array(categories.map(JSONValue.string))]),
            "observation": .object(["type": .string("string")]),
            "inference": .object(["type": .string("string")]),
            "recommendation": .object(["type": .string("string")]),
            "confidence": .object(["type": .string("number")]),
        ])
        let strings = JSONValue.object(["type": .string("array"), "items": .object(["type": .string("string")])])
        return object([
            "overall_observations": strings,
            "top_strength": insight,
            "primary_improvement_area": insight,
            "critical_moments": .object(["type": .string("array"), "items": moment]),
            "repeated_patterns": strings,
            "categories": .object(["type": .string("array"), "items": category]),
            "next_practice_focus": .object(["type": .string("string")]),
            "limitations": strings,
            "confidence": .object(["type": .string("number")]),
        ])
    }()

    /// A strict-mode object: every property required, nothing extra allowed.
    static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }
}

extension SessionTimeFormatter {
    /// `125.4` → `"02:05"`.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%02ld:%02ld", total / 60, total % 60)
    }
}
