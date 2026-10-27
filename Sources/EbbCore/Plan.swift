import Foundation

/// An account's subscription, as its provider reports it.
public enum Plan: Sendable, Equatable {
    /// Paying; `weight` is the plan's size relative to the provider's base plan.
    case paid(weight: Double)
    /// The subscription is not active any more.
    case inactive
    /// Active, but the plan's size can't be read; left out of the pool rather than guessed.
    case unknown

    public var weight: Double {
        if case let .paid(weight) = self { weight } else { 0 }
    }
}

/// A plan check worth keeping between launches, cached as `<hash of email>.plan.json`.
public struct PlanProfile: Codable, Sendable, Equatable {
    private var status: String
    private var weight: Double
    /// The provider's own name for the plan, kept for troubleshooting.
    public var tier: String?

    public init(plan: Plan, tier: String?) {
        switch plan {
        case let .paid(weight):
            status = "paid"
            self.weight = weight
        case .inactive:
            status = "inactive"
            weight = 0
        case .unknown:
            status = "unknown"
            weight = 0
        }
        self.tier = tier
    }

    public var plan: Plan {
        switch status {
        case "paid": .paid(weight: weight)
        case "inactive": .inactive
        default: .unknown
        }
    }
}

public enum ProfilePlan {
    public static let activeInterval: TimeInterval = 6 * 60 * 60
    public static let retiredInterval: TimeInterval = 24 * 60 * 60
    /// A first "inactive" answer is re-checked this soon before anything is retired.
    public static let confirmationInterval: TimeInterval = 15 * 60

    public static func isDue(lastCheck: Date?, plan: Plan?, isRetired: Bool, now: Date) -> Bool {
        guard let lastCheck, let plan else { return true }
        let interval = if isRetired {
            retiredInterval
        } else if plan == .inactive {
            confirmationInterval
        } else {
            activeInterval
        }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}
