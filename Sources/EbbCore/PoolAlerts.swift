import CryptoKit
import Foundation

/// One counted account of a pool, as the ledger and the alerts see it.
public struct PoolAccount: Sendable, Equatable {
    /// Stable within its pool: an email or an auth file name. Never shown or saved as is.
    public var id: String
    public var weight: PlanWeight
    public var limits: [UsageLimit]
    public var readAt: Date

    public init(id: String, weight: PlanWeight, limits: [UsageLimit], readAt: Date) {
        self.id = id
        self.weight = weight
        self.limits = limits
        self.readAt = readAt
    }
}

/// A notification Ebb wants to show. Its `id` is also the system identifier.
public struct PoolAlert: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String

    public init(id: String, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// Shows alerts. The app's wraps UserNotifications; tests use a fake, so nothing ever asks
/// for permission while developing.
public protocol Notifier: Sendable {
    /// `nil` until the user has been asked.
    func isAuthorized() async -> Bool?
    func requestAuthorization() async -> Bool
    func post(_ alert: PoolAlert) async
}

/// Posts alerts while the user wants them, asking for permission only in context: when the
/// first alert is due, or when the user turns alerts on. Never at launch.
@MainActor
public final class AlertDelivery {
    private let notifier: any Notifier
    private let isEnabled: () -> Bool

    public init(notifier: any Notifier, isEnabled: @escaping () -> Bool) {
        self.notifier = notifier
        self.isEnabled = isEnabled
    }

    public func deliver(_ alerts: [PoolAlert]) async {
        guard !alerts.isEmpty, isEnabled(), await isAllowed() else { return }
        for alert in alerts {
            await notifier.post(alert)
        }
    }

    /// The user turned alerts on: ask now, if nobody has yet. False when alerts can't show.
    public func enable() async -> Bool {
        await isAllowed()
    }

    private func isAllowed() async -> Bool {
        if let isAuthorized = await notifier.isAuthorized() { return isAuthorized }
        return await notifier.requestAuthorization()
    }
}

/// Decides which alerts are due, each once. Saved between launches, so a relaunch never
/// repeats one.
///
/// "Weekly back" is decided per account, never from the pool total, which also moves when
/// accounts join, leave or get read again. Each case below shipped as a false or duplicate
/// "refilled" somewhere: a reset seen twice, a reset time drifting by seconds (syrtis#367),
/// a stale pre-refill value bouncing back after the refill (CodexBar#2230), one bogus low
/// sample (CodexBar#2222), an old reading followed by a fresh one, a clock jump, and an
/// account rejoining.
public struct AlertTracker: Codable, Sendable, Equatable {
    /// A 5-hour run-out this close, as one time or a range that ends this soon, is worth an alert.
    public static let runOutWithin: TimeInterval = 30 * 60
    /// Weekly capacity coming back, in pool points, worth an alert.
    public static let minimumWeeklyReturn = 10.0
    /// A reset that landed longer ago than this, while Ebb was asleep or hidden, isn't news.
    public static let returnFreshness: TimeInterval = 6 * 60 * 60
    /// An account's refill is announced at most once in this long.
    static let announceQuiet: TimeInterval = 24 * 60 * 60

    /// An account missing from this many polls in a row left the pool, and starts over if it
    /// comes back; fewer is a glitch in the listing. Polls, not time: none run while asleep.
    static let missedPollsToLeave = 3
    /// Wall-clock and continuous time apart by more than this means the clock was changed.
    static let clockSlack: TimeInterval = 2 * 60

    struct Week: Codable, Sendable, Equatable {
        var used: Double
        var resetsAt: Date?
        var readAt: Date
        /// The level before a big fall within the window, until a second reading confirms it.
        var fellFrom: Double?
        var announcedAt: Date?
        /// Polls in a row the account was missing from.
        var missedPolls: Int?
    }

    struct Return: Codable, Sendable, Equatable {
        var points: Double
        var at: Date
    }

    struct Moment: Codable, Sendable, Equatable {
        var wall: Date
        var uptime: TimeInterval
    }

    /// Each pool's run-out alert stays quiet until this, until its pace says it lasts, or
    /// until capacity comes back.
    private var runOutQuietUntil: [String: Date] = [:]
    /// The pool's 5-hour free share when its run-out alert fired.
    private var runOutFree: [String: Double] = [:]
    /// Returns not announced yet, by pool and account: too small alone, or with more due in minutes.
    private var gathering: [String: [String: Return]] = [:]
    /// Each account's weekly window, by `pool/hashed id`.
    private var weeks: [String: Week] = [:]
    private var lastSeen: [String: Moment] = [:]

    public init() {}

    /// Alerts for one pool. `title` names the provider, `short` its shorter window, and
    /// `uptime` is time since boot including sleep, to tell a changed clock from a sleep.
    public mutating func alerts(
        pool: String, title: String, short: ShortWindow, summary: PoolSummary, forecast: PoolForecast?,
        accounts: [PoolAccount], now: Date, uptime: TimeInterval, locale: Locale = .autoupdatingCurrent
    ) -> [PoolAlert] {
        var alerts: [PoolAlert] = []
        if let free = runOutFree[pool], summary.session.freePercent >= free + DemandLedger.bigDrop {
            runOutQuietUntil[pool] = nil
            runOutFree[pool] = nil
        }
        switch forecast?.session?.outlook {
        case let .runsOut(_, within) where within.upperBound <= Self.runOutWithin:
            if now >= runOutQuietUntil[pool] ?? .distantPast, let forecast = forecast?.session {
                runOutQuietUntil[pool] = now + short.horizon
                runOutFree[pool] = summary.session.freePercent
                alerts.append(PoolAlert(
                    id: "runout.\(pool).\(Int(now.timeIntervalSince1970))",
                    title: short == .day
                        ? Localization.text("\(title) daily pool about to run out", locale: locale)
                        : Localization.text("\(title) 5-hour pool about to run out", locale: locale),
                    body: PaceText.sentence(forecast, window: .session, short: short, now: now, locale: locale) + "."
                ))
            }
        case .lasts:
            runOutQuietUntil[pool] = nil
            runOutFree[pool] = nil
        default:
            break
        }

        let isClockChanged = lastSeen[pool].map { last in
            uptime >= last.uptime && abs(now.timeIntervalSince(last.wall) - (uptime - last.uptime)) > Self.clockSlack
        } ?? false
        lastSeen[pool] = Moment(wall: now, uptime: uptime)
        let back = weeklyReturn(pool: pool, accounts: accounts, totalWeight: summary.totalWeight.weekly, now: now, isClockChanged: isClockChanged)
        let points = Int(back.rounded())
        if Double(points) >= Self.minimumWeeklyReturn {
            alerts.append(PoolAlert(
                id: "weekly.\(pool).\(Int(now.timeIntervalSince1970))",
                title: Localization.text("\(title) weekly back +\(points)%", locale: locale),
                body: Localization.text("\(Int(summary.weekly.freePercent.rounded()))% of the weekly pool is free.", locale: locale)
            ))
        }
        return alerts
    }

    /// Pool points of weekly capacity that came back since the last call, across accounts, in
    /// weekly weights: `totalWeight` is the pool's weekly weight.
    private mutating func weeklyReturn(pool: String, accounts: [PoolAccount], totalWeight: Double, now: Date, isClockChanged: Bool) -> Double {
        let keys = Dictionary(accounts.map { ("\(pool)/\(AccountKey.hashed($0.id))", $0) }) { first, _ in first }
        for key in weeks.keys where key.hasPrefix("\(pool)/") && keys[key] == nil {
            let missed = (weeks[key]?.missedPolls ?? 0) + 1
            // An account that left starts over when it comes back, so rejoining is never a refill.
            weeks[key] = missed >= Self.missedPollsToLeave ? nil : weeks[key].map { week in
                var week = week
                week.missedPolls = missed
                return week
            }
        }
        var pending = (gathering[pool] ?? [:]).filter { now.timeIntervalSince($0.value.at) <= Self.returnFreshness }
        for (key, account) in keys {
            let limit = account.limits.first { $0.kind == .weeklyAll }
            let hasEnded = limit?.resetsAt.map { $0 <= now } ?? false
            let reading = Week(
                used: hasEnded ? 0 : limit?.used(at: account.readAt) ?? 0,
                resetsAt: hasEnded ? nil : limit?.resetsAt,
                readAt: account.readAt
            )
            guard var week = weeks[key] else {
                weeks[key] = reading
                continue
            }
            week.missedPolls = nil
            let back = Self.advance(&week, to: reading, now: now)
            if back > 0, !isClockChanged, week.announcedAt.map({ now.timeIntervalSince($0) > Self.announceQuiet }) ?? true, totalWeight > 0 {
                pending[key] = Return(points: account.weight.weekly * back / totalWeight, at: now)
            }
            weeks[key] = week
        }
        let points = pending.values.reduce(0) { $0 + $1.points }
        // Resets within minutes of each other are one return, as the pool's own line reads them.
        let isMoreComing = weeks.contains { key, week in
            key.hasPrefix("\(pool)/") && week.resetsAt.map { $0 > now && $0.timeIntervalSince(now) <= Pool.mergeWindow } == true
        }
        guard !isMoreComing, points.rounded() >= Self.minimumWeeklyReturn else {
            gathering[pool] = pending
            return 0
        }
        for key in pending.keys {
            weeks[key]?.announcedAt = now
        }
        gathering[pool] = nil
        return points
    }

    /// Moves an account's window to `reading` and returns the percentage points that came back.
    private static func advance(_ week: inout Week, to reading: Week, now: Date) -> Double {
        let isNewer = reading.readAt > week.readAt
        if isNewer, let old = week.resetsAt, let new = reading.resetsAt, abs(new.timeIntervalSince(old)) <= DemandLedger.resetDrift {
            week.resetsAt = new
        }
        var back = 0.0
        if let old = week.resetsAt, old <= now {
            if now.timeIntervalSince(old) <= returnFreshness { back = week.used }
            week.used = 0
            week.resetsAt = nil
            week.fellFrom = nil
        }
        guard isNewer else { return back }

        if let old = week.resetsAt, let new = reading.resetsAt, new > old + DemandLedger.cycleShift {
            // The window restarted early. An old reading followed by a fresh one isn't news.
            if reading.readAt.timeIntervalSince(week.readAt) <= returnFreshness { back += max(0, week.used - reading.used) }
            week.used = reading.used
            week.resetsAt = new
            week.fellFrom = nil
        } else if week.resetsAt != nil, reading.resetsAt == week.resetsAt {
            if let from = week.fellFrom {
                // Back near the level before the fall: that fall was a bogus sample.
                if reading.used < from - DemandLedger.bigDrop { back += from - reading.used }
                week.fellFrom = nil
            } else if reading.used <= week.used - DemandLedger.bigDrop {
                // A refill that keeps its reset time, or a bogus low sample: wait for the next reading.
                week.fellFrom = week.used
            }
            week.used = reading.used
        } else {
            week.used = reading.used
            week.resetsAt = reading.resetsAt
            week.fellFrom = nil
        }
        week.readAt = reading.readAt
        return back
    }
}

/// An account's id as the trackers save it: hashed, so no email ever lands in UserDefaults.
enum AccountKey {
    static func hashed(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
