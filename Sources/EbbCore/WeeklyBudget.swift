import Foundation

/// A steady daily share of the weekly pool that lasts until its capped accounts reset, for the
/// weekly hover card: "About 14% a day lasts until Tue 22:00".
///
/// Only a pool where every account has a weekly cap gets one: the card's free share counts an
/// uncapped account as fully free, and a budget in capped terms would contradict it. The horizon
/// is the soonest reset that brings back a meaningful share of the pool, so a fresh Max 5x
/// resetting tomorrow doesn't cut a half-spent Max 20x's week short; the capacity of accounts
/// resetting later is paced toward that same horizon, and the line is worked out again once it passes.
public struct WeeklyBudget: Sendable, Equatable {
    /// Pool points still free on accounts with a weekly cap.
    public var freePercent: Double
    /// The soonest weekly reset that brings back `minimumShare` or more.
    public var resetsAt: Date

    /// A reset that brings back less of the pool than this isn't worth pacing toward.
    public static let minimumShare = 10.0
    /// Under this much capped capacity the pool is as good as empty, and there's nothing to pace.
    public static let minimumFree = 5.0
    /// A reset under a day away is better read from the refill line; a daily share until then is noise.
    public static let minimumDays = 1.0

    public init(freePercent: Double, resetsAt: Date) {
        self.freePercent = freePercent
        self.resetsAt = resetsAt
    }

    /// `totalWeight` is the pool's weekly weight. `nil` with an uncapped account, or without a
    /// reset ahead that brings back a meaningful share.
    public static func of(_ accounts: [AccountUsage], totalWeight: Double, now: Date) -> WeeklyBudget? {
        guard totalWeight > 0 else { return nil }
        var free = 0.0
        var horizon: Date?
        for account in accounts {
            guard let limit = account.limits.first(where: { $0.kind == .weeklyAll }) else { return nil }
            let used = limit.used(at: now)
            free += account.weight.weekly * (100 - used) / totalWeight
            if let resetsAt = limit.resetsAt, resetsAt > now, account.weight.weekly * used / totalWeight >= minimumShare, resetsAt < horizon ?? .distantFuture {
                horizon = resetsAt
            }
        }
        guard let horizon else { return nil }
        return WeeklyBudget(freePercent: free, resetsAt: horizon)
    }

    /// The whole percent of the pool a day that lasts exactly until the reset: the capped free
    /// share over the days left. `nil` under a day from the reset, or with nearly nothing free.
    public func percentPerDay(at now: Date) -> Int? {
        let days = resetsAt.timeIntervalSince(now) / 86400
        guard days >= Self.minimumDays, freePercent >= Self.minimumFree else { return nil }
        return Int((freePercent / days).rounded())
    }
}
