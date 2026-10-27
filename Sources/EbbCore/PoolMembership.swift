import Foundation

/// A pool's logins as the membership alerts see them.
public struct PoolRoster: Sendable, Equatable {
    /// One login, named by its plan only: never by email.
    public struct Account: Sendable, Equatable {
        /// Stable within its pool: an email or an auth file name. Never shown or saved as is.
        public var id: String
        /// The plan's title, "Max 20x" or "Team"; `nil` when there's no name worth saying.
        public var plan: String?

        public init(id: String, plan: String?) {
            self.id = id
            self.plan = plan
        }
    }

    public var pool: String
    public var title: String
    /// Every login Ebb sees in the pool, read or not, enabled or not.
    public var present: [String]
    /// The logins counted right now: paying, enabled, with a reading.
    public var counted: [Account]
    /// Logins Ebb disabled because their plan ended.
    public var retired: [String]

    public init(pool: String, title: String, present: [String], counted: [Account], retired: [String] = []) {
        self.pool = pool
        self.title = title
        self.present = present
        self.counted = counted
        self.retired = retired
    }
}

/// Says when an account joins a pool, leaves it because its plan ended, or comes back, each once
/// per account and change. Saved between launches, so a relaunch never repeats one.
///
/// The logins present up to the first call that counts one are a baseline, not news: a first
/// run, an upgrade with no saved state, or a first login during onboarding would otherwise be
/// announced. Joining is counting for the first time, so a login that was present but unread at
/// the baseline never joins, and one the listing drops for a poll or two never joins twice; gone
/// for longer, it's forgotten, and its return is news. Leaving and coming back are Ebb's own
/// retirements, and only once the proxy accepted them; a login that merely goes missing is never "gone".
public struct MembershipTracker: Codable, Sendable, Equatable {
    /// A login missing from this many polls in a row is forgotten; fewer is a glitch in the listing.
    public static let missedPollsToLeave = AlertTracker.missedPollsToLeave

    /// `pool/hashed id` of every login seen, counted or not.
    private var known: Set<String> = []
    /// `pool/hashed id` of the logins Ebb retired and hasn't put back.
    private var retired: Set<String> = []
    /// Polls in a row each known or retired login was missing from.
    private var missedPolls: [String: Int] = [:]
    private var hasBaseline = false

    public init() {}

    /// "Joined" alerts, from every pool at once so the baseline covers them all. Each roster also
    /// brings Ebb's record of retirements up to date: one the user re-enabled by hand is retired
    /// no more, so retiring it again is news, and one retired before this tracker existed can come back.
    public mutating func alerts(rosters: [PoolRoster], locale: Locale = .autoupdatingCurrent) -> [PoolAlert] {
        forgetGone(rosters)
        var alerts: [PoolAlert] = []
        for roster in rosters {
            let retiredKeys = Set(roster.retired.map { Self.key(roster.pool, $0) })
            for key in roster.present.map({ Self.key(roster.pool, $0) }) {
                if retiredKeys.contains(key) { retired.insert(key) } else { retired.remove(key) }
            }
            for account in roster.counted {
                let key = Self.key(roster.pool, account.id)
                if hasBaseline, !known.contains(key) {
                    alerts.append(PoolAlert(
                        id: "membership.\(roster.pool).joined.\(AccountKey.hashed(account.id))",
                        title: Self.localizedPlan(account.plan, locale: locale)
                            .map { Localization.text("\(roster.title): a new \($0) account joined the pool", locale: locale) }
                            ?? Localization.text("\(roster.title): a new account joined the pool", locale: locale),
                        body: Localization.text("The pool now has \(roster.counted.count) accounts.", locale: locale)
                    ))
                }
            }
            if !hasBaseline { known.formUnion(roster.present.map { Self.key(roster.pool, $0) }) }
            known.formUnion(roster.counted.map { Self.key(roster.pool, $0.id) })
        }
        if rosters.contains(where: { !$0.counted.isEmpty }) { hasBaseline = true }
        return alerts
    }

    /// Counts each known or retired login's polls away, and drops one gone for `missedPollsToLeave`.
    private mutating func forgetGone(_ rosters: [PoolRoster]) {
        let present = Set(rosters.flatMap { roster in (roster.present + roster.counted.map(\.id)).map { Self.key(roster.pool, $0) } })
        missedPolls = missedPolls.filter { !present.contains($0.key) }
        for key in known.union(retired).subtracting(present) {
            let missed = missedPolls[key, default: 0] + 1
            guard missed >= Self.missedPollsToLeave else {
                missedPolls[key] = missed
                continue
            }
            known.remove(key)
            retired.remove(key)
            missedPolls[key] = nil
        }
    }

    /// After the proxy answered Ebb's retire or reinstate: an alert when it accepted, once per change.
    public mutating func alert(
        after action: Retirement.Action, accepted: Bool, pool: String, title: String, account: PoolRoster.Account,
        now: Date, locale: Locale = .autoupdatingCurrent
    ) -> PoolAlert? {
        guard accepted else { return nil }
        let key = Self.key(pool, account.id)
        let plan = Self.localizedPlan(account.plan, locale: locale)
        switch action {
        case .retire:
            guard retired.insert(key).inserted else { return nil }
            known.insert(key)
            let heading = switch plan {
            case let plan? where Self.takesAn(plan): Localization.text("\(title): an \(plan) account left the pool", locale: locale)
            case let plan?: Localization.text("\(title): a \(plan) account left the pool", locale: locale)
            case nil: Localization.text("\(title): an account left the pool", locale: locale)
            }
            return PoolAlert(
                id: "membership.\(pool).left.\(AccountKey.hashed(account.id)).\(Int(now.timeIntervalSince1970))",
                title: heading,
                body: Localization.text("Its plan ended, so Ebb disabled it in the proxy. It's enabled again if the plan renews.", locale: locale)
            )
        case .reinstate:
            guard retired.remove(key) != nil else { return nil }
            known.insert(key)
            let heading = switch plan {
            case let plan? where Self.takesAn(plan): Localization.text("\(title): an \(plan) account is back in the pool", locale: locale)
            case let plan?: Localization.text("\(title): a \(plan) account is back in the pool", locale: locale)
            case nil: Localization.text("\(title): an account is back in the pool", locale: locale)
            }
            return PoolAlert(
                id: "membership.\(pool).back.\(AccountKey.hashed(account.id)).\(Int(now.timeIntervalSince1970))",
                title: heading,
                body: Localization.text("Its plan is active again, so Ebb enabled it in the proxy.", locale: locale)
            )
        case .keep:
            return nil
        }
    }

    private static func key(_ pool: String, _ id: String) -> String {
        "\(pool)/\(AccountKey.hashed(id))"
    }

    /// Titles from the weight table are catalog keys; coined names like "Max 5x" read as they are.
    private static func localizedPlan(_ plan: String?, locale: Locale) -> String? {
        plan.map { Localization.text(String.LocalizationValue($0), locale: locale) }
    }

    /// English says "an Edu account" and "a Max 20x account"; the catalog carries both forms.
    private static func takesAn(_ plan: String) -> Bool {
        plan.first.map { "aeiouAEIOU".contains($0) } ?? false
    }
}
