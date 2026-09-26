import Foundation

/// A value inferred from video. Vision output is never stored as a bare
/// fact: it always carries the confidence and the moment it was observed.
public struct Estimate<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value
    public var confidence: Double
    public var observedAt: Double

    public init(_ value: Value, confidence: Double, observedAt: Double) {
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
        self.observedAt = observedAt
    }
}

public enum WeaponCategory: String, Codable, CaseIterable, Sendable {
    case shotgun, smg, ar, pistol, sniper, explosive, mobility, heal, shield, unknown
}

public enum PlayerMovementState: String, Codable, Sendable {
    case stationary, walking, sprinting, airborne, gliding, vehicle, unknown
}

public enum StormState: String, Codable, Sendable {
    case outsideStorm, insideStorm, stormShrinking, unknown
}

public struct InventorySlot: Codable, Hashable, Sendable {
    public var index: Int
    public var category: Estimate<WeaponCategory>?
    public var isEmpty: Estimate<Bool>?

    public init(index: Int, category: Estimate<WeaponCategory>? = nil, isEmpty: Estimate<Bool>? = nil) {
        self.index = index
        self.category = category
        self.isEmpty = isEmpty
    }
}

/// Current best estimate of the game, rebuilt by a `GameAdapter` from frames.
/// Populated from Milestone 2; in Milestone 1 it stays empty.
public struct GameState: Codable, Hashable, Sendable {
    public var health: Estimate<Int>?
    public var shield: Estimate<Int>?
    public var selectedWeaponSlot: Estimate<Int>?
    public var inventorySlots: [InventorySlot]
    public var currentWeapon: Estimate<WeaponCategory>?
    public var enemyVisible: Estimate<Bool>?
    public var fightActive: Estimate<Bool>?
    public var estimatedEnemyDistance: Estimate<Double>?
    public var playerMovementState: Estimate<PlayerMovementState>?
    public var stormState: Estimate<StormState>?
    /// Confidence that the frame shows this game's HUD at all.
    public var confidence: Double

    public init() {
        inventorySlots = []
        confidence = 0
    }
}
