import Foundation

/// How the menu bar item draws the pool, in the order Settings lists them.
public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case standard = "default"
    case ring
    case both
    case stacked
    case refillTime
    case numberOnly
    case bars
    case iconOnly

    public var id: Self { self }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .ring: "Ring"
        case .both: "Both"
        case .stacked: "Stacked"
        case .refillTime: "Refill time"
        case .numberOnly: "Number only"
        case .bars: "Bars"
        case .iconOnly: "Icon only"
        }
    }

    /// These already show both windows, so the Limit setting doesn't apply to them.
    public var showsBothWindows: Bool {
        switch self {
        case .ring, .both, .stacked, .bars: true
        case .standard, .refillTime, .numberOnly, .iconOnly: false
        }
    }
}

/// The window the single-value styles show.
public enum MenuBarLimit: String, CaseIterable, Identifiable, Sendable {
    case fiveHour, weekly, tighter

    public var id: Self { self }

    public var title: String {
        switch self {
        case .fiveHour: "5-Hour"
        case .weekly: "Weekly"
        case .tighter: "Tighter of the Two"
        }
    }

    /// Tighter picks the window with less free; on a tie, the 5-hour one.
    func pick(session: WindowReading, weekly: WindowReading) -> WindowReading {
        switch self {
        case .fiveHour: session
        case .weekly: weekly
        case .tighter: weekly.percent < session.percent ? weekly : session
        }
    }
}

/// How close a window is to empty. The thresholds are fixed; Settings has no control for them.
public enum LowState: Sendable, Equatable {
    /// More than 15% free: drawn in the menu bar's own colour.
    case normal
    /// 15% or less: orange.
    case low
    /// 5% or less: red. Text sits on a red capsule so it stays readable on any wallpaper.
    case critical

    public init(percent: Int) {
        switch percent {
        case ...5: self = .critical
        case ...15: self = .low
        default: self = .normal
        }
    }
}

/// One window as the menu bar shows it: whole percent free, and when capacity next comes back.
public struct WindowReading: Sendable, Equatable {
    public var window: PoolWindow
    public var percent: Int
    public var refillsAt: Date?
    /// Names the short window: five hours for most providers, a day for Devin.
    public var shortWindow: ShortWindow

    public init(window: PoolWindow, percent: Int, refillsAt: Date?, shortWindow: ShortWindow = .fiveHours) {
        self.window = window
        self.percent = min(max(percent, 0), 100)
        self.refillsAt = refillsAt
        self.shortWindow = shortWindow
    }

    public init(window: PoolWindow, summary: WindowSummary, shortWindow: ShortWindow, now: Date) {
        self.init(
            window: window,
            percent: Int(summary.freePercent.rounded()),
            refillsAt: summary.resets.first { $0.date > now }?.date,
            shortWindow: shortWindow
        )
    }

    /// "5h", "1d" or "W"; drawn in the same colour as the number.
    public var label: String { window == .session ? shortWindow.abbreviation : "W" }
    public var state: LowState { LowState(percent: percent) }

    var spokenTitle: String { window == .session ? shortWindow.title.lowercased() : "weekly" }
}

/// Everything the menu bar item draws from: one provider's two windows, which of its
/// accounts can take work, and when any of it was last read.
public struct MenuBarPool: Sendable, Equatable {
    public var session: WindowReading
    public var weekly: WindowReading
    /// One flag per account in the pool, true when it can take work.
    public var accounts: [Bool]
    public var lastReadAt: Date?

    public init(session: WindowReading, weekly: WindowReading, accounts: [Bool], lastReadAt: Date?) {
        self.session = session
        self.weekly = weekly
        self.accounts = accounts
        self.lastReadAt = lastReadAt
    }

    public init(summary: PoolSummary, shortWindow: ShortWindow, accounts: [Bool], lastReadAt: Date?, now: Date) {
        self.init(
            session: WindowReading(window: .session, summary: summary.session, shortWindow: shortWindow, now: now),
            weekly: WindowReading(window: .weekly, summary: summary.weekly, shortWindow: shortWindow, now: now),
            accounts: accounts,
            lastReadAt: lastReadAt
        )
    }
}

/// What the menu bar item shows, worked out from the pool and the chosen style and limit.
/// The app draws it; nothing here knows about pixels.
public struct MenuBarItem: Sendable, Equatable {
    public enum Part: Sendable, Equatable {
        /// The Tideline mark with its water at `percent`. Tinted only where the mark carries the value.
        case mark(percent: Int, state: LowState)
        /// Text on one line, the runs 4 pt apart.
        case line([Run])
        /// Two 10 pt rows, label on the left and value on the right.
        case stack([StackRow])
        case ring(Ring)
        /// Two upright capsules: 5-hour on the left, weekly on the right.
        case bars(session: Gauge, weekly: Gauge)
    }

    public struct Run: Sendable, Equatable {
        public var text: String
        public var state: LowState
        /// Separators and refill times, drawn in the secondary colour.
        public var isSecondary: Bool

        public init(_ text: String, state: LowState = .normal, isSecondary: Bool = false) {
            self.text = text
            self.state = state
            self.isSecondary = isSecondary
        }
    }

    public struct StackRow: Sendable, Equatable {
        public var label: String
        public var value: String
        public var state: LowState
        /// At 0%, when the window comes back: "· 1h 40m".
        public var refill: String?

        public init(label: String, value: String, state: LowState, refill: String? = nil) {
            self.label = label
            self.value = value
            self.state = state
            self.refill = refill
        }
    }

    public struct Gauge: Sendable, Equatable {
        public var percent: Int
        public var state: LowState

        public init(percent: Int, state: LowState) {
            self.percent = percent
            self.state = state
        }

        init(_ reading: WindowReading) {
            self.init(percent: reading.percent, state: reading.state)
        }
    }

    public struct Ring: Sendable, Equatable {
        /// The 5-hour window, written inside.
        public var number: Gauge
        /// The weekly window, as the arc.
        public var arc: Gauge
        /// One flag per account, true when it can take work.
        public var accounts: [Bool]

        public init(number: Gauge, arc: Gauge, accounts: [Bool]) {
            self.number = number
            self.arc = arc
            self.accounts = accounts
        }
    }

    public var parts: [Part]
    /// No reading, or none for over `staleAfter`: drawn at half opacity with no tint.
    public var isStale: Bool
    public var accessibilityLabel: String

    /// Older readings dim the item, so an old number isn't taken for a live one.
    public static let staleAfter: TimeInterval = 10 * 60
    /// The brand mark's water level, shown while there's nothing to read.
    public static let restPercent = 52

    /// True when some part draws in colour, so the image can't be a template.
    public var isTinted: Bool {
        parts.contains { $0.isTinted }
    }

    public init(style: MenuBarStyle, limit: MenuBarLimit, pool: MenuBarPool?, now: Date) {
        guard let pool else {
            parts = [.mark(percent: Self.restPercent, state: .normal)]
            isStale = true
            accessibilityLabel = "Ebb, no reading"
            return
        }
        let session = pool.session
        let weekly = pool.weekly
        let shown = limit.pick(session: session, weekly: weekly)

        func refill(_ reading: WindowReading) -> String? {
            reading.refillsAt.map { "· " + RefillText.until($0, now: now) }
        }
        /// "5h 88%", plus the refill time when the window is empty, since a bare 0 isn't actionable.
        func runs(_ reading: WindowReading) -> [Run] {
            let value = Run("\(reading.label) \(reading.percent)%", state: reading.state)
            guard reading.percent == 0, let time = refill(reading) else { return [value] }
            return [value, Run(time, isSecondary: true)]
        }
        func row(_ reading: WindowReading) -> StackRow {
            StackRow(label: reading.label, value: "\(reading.percent)%", state: reading.state, refill: reading.percent == 0 ? refill(reading) : nil)
        }

        switch style {
        case .standard:
            parts = [.mark(percent: shown.percent, state: .normal), .line(runs(shown))]
        case .ring:
            parts = [.ring(Ring(number: Gauge(session), arc: Gauge(weekly), accounts: pool.accounts))]
        case .both:
            parts = [.mark(percent: session.percent, state: .normal), .line(runs(session) + [Run("·", isSecondary: true)] + runs(weekly))]
        case .stacked:
            parts = [.mark(percent: session.percent, state: .normal), .stack([row(session), row(weekly)])]
        case .refillTime:
            let value = Run("\(shown.label) \(shown.percent)%", state: shown.state)
            parts = [.mark(percent: shown.percent, state: .normal), .line([value] + (refill(shown).map { [Run($0, isSecondary: true)] } ?? []))]
        case .numberOnly:
            parts = [.line(runs(shown))]
        case .bars:
            parts = [.bars(session: Gauge(session), weekly: Gauge(weekly))]
        case .iconOnly:
            parts = [.mark(percent: shown.percent, state: shown.state)]
        }

        isStale = pool.lastReadAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
        if isStale { parts = parts.map(\.untinted) }

        let spoken = style.showsBothWindows ? [session, weekly] : [shown]
        var label = "Ebb, " + spoken.map { "\($0.spokenTitle) \($0.percent)% free" }.joined(separator: ", ")
        if style == .refillTime || shown.percent == 0, !style.showsBothWindows, let date = shown.refillsAt {
            label += ", more in " + RefillText.until(date, now: now)
        }
        if style == .ring, pool.accounts.count > 1 {
            label += ", \(pool.accounts.filter { $0 }.count) of \(pool.accounts.count) accounts ready"
        }
        if isStale { label += ", not updated recently" }
        accessibilityLabel = label
    }
}

extension MenuBarItem.Part {
    var isTinted: Bool {
        switch self {
        case let .mark(_, state): state != .normal
        case let .line(runs): runs.contains { $0.state != .normal }
        case let .stack(rows): rows.contains { $0.state != .normal }
        case let .ring(ring): ring.number.state != .normal || ring.arc.state != .normal
        case let .bars(session, weekly): session.state != .normal || weekly.state != .normal
        }
    }

    var untinted: Self {
        switch self {
        case let .mark(percent, _):
            return .mark(percent: percent, state: .normal)
        case let .line(runs):
            return .line(runs.map { MenuBarItem.Run($0.text, isSecondary: $0.isSecondary) })
        case let .stack(rows):
            return .stack(rows.map { MenuBarItem.StackRow(label: $0.label, value: $0.value, state: .normal, refill: $0.refill) })
        case var .ring(ring):
            ring.number.state = .normal
            ring.arc.state = .normal
            return .ring(ring)
        case let .bars(session, weekly):
            return .bars(session: .init(percent: session.percent, state: .normal), weekly: .init(percent: weekly.percent, state: .normal))
        }
    }
}

/// The accounts drawn in the Ring's bottom gap.
public enum RingAccounts: Sendable, Equatable {
    case hidden
    /// Ready accounts first, then the limited ones in grey.
    case dots([Bool])
    /// Past `maxDots`, the dots give way to "up/total".
    case count(ready: Int, total: Int)

    public static let maxDots = 5

    /// One account needs no dots. At 1× the dots blur into the arc, so they're dropped; the
    /// count stays, soft but rare.
    public init(_ accounts: [Bool], backingScale: Double) {
        let ready = accounts.filter { $0 }.count
        if accounts.count > Self.maxDots {
            self = .count(ready: ready, total: accounts.count)
        } else if accounts.count > 1, backingScale >= 2 {
            self = .dots(Array(repeating: true, count: ready) + Array(repeating: false, count: accounts.count - ready))
        } else {
            self = .hidden
        }
    }
}

public enum RefillText {
    /// "38m", "2h 10m", "3d 4h": short enough for the menu bar. Rounds up, so it never promises early.
    public static func until(_ date: Date, now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 {
            let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let (days, hours) = Int((Double(minutes) / 60).rounded(.up)).quotientAndRemainder(dividingBy: 24)
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }
}
