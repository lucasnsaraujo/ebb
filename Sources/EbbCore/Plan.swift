import Foundation

/// A plan's size in each window, relative to its provider's base plan. The two differ:
/// Max 20x gets four times Max 5x's 5-hour session but only about twice its week.
public struct PlanWeight: Sendable, Equatable {
    /// The short window's size: 5 hours, or a day for Devin.
    public var session: Double
    public var weekly: Double

    public init(session: Double, weekly: Double) {
        self.session = session
        self.weekly = weekly
    }

    /// The same size in both windows, for plans whose windows aren't known to differ.
    public init(_ weight: Double) {
        self.init(session: weight, weekly: weight)
    }

    public static let zero = PlanWeight(0)

    /// Sized in both windows, so it counts in the pool.
    public var isPositive: Bool {
        session > 0 && weekly > 0
    }

    public static func + (lhs: PlanWeight, rhs: PlanWeight) -> PlanWeight {
        PlanWeight(session: lhs.session + rhs.session, weekly: lhs.weekly + rhs.weekly)
    }
}

/// An account's subscription, as its provider reports it.
public enum Plan: Sendable, Equatable {
    /// Paying; `weight` is the plan's size relative to the provider's base plan.
    case paid(weight: PlanWeight)
    /// The subscription is not active any more.
    case inactive
    /// Active, but the plan's size can't be read; left out of the pool rather than guessed.
    case unknown

    public var weight: PlanWeight {
        if case let .paid(weight) = self { weight } else { .zero }
    }
}

/// A plan check worth keeping between launches, cached as `<hash of email>.plan.json`.
public struct PlanProfile: Codable, Sendable, Equatable {
    private var status: String
    private var weight: Double
    /// Missing from caches written before plans had a weekly size: those count `weight` in both windows.
    private var weeklyWeight: Double?
    /// The provider's own name for the plan, kept for troubleshooting.
    public var tier: String?

    public init(plan: Plan, tier: String?) {
        switch plan {
        case let .paid(weight):
            status = "paid"
            self.weight = weight.session
            weeklyWeight = weight.weekly
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
        case "paid": .paid(weight: PlanWeight(session: weight, weekly: weeklyWeight ?? weight))
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
