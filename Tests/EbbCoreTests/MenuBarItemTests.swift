import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

private func pool(
    session: Int,
    weekly: Int,
    sessionRefillIn minutes: Double = 130,
    weeklyRefillIn weeklyMinutes: Double = 3 * 24 * 60,
    shortWindow: ShortWindow = .fiveHours,
    accounts: [Bool] = [true, true, true, false],
    readMinutesAgo: Double = 1
) -> MenuBarPool {
    MenuBarPool(
        session: WindowReading(window: .session, percent: session, refillsAt: now + minutes * 60, shortWindow: shortWindow),
        weekly: WindowReading(window: .weekly, percent: weekly, refillsAt: now + weeklyMinutes * 60, shortWindow: shortWindow),
        accounts: accounts,
        lastReadAt: now - readMinutesAgo * 60
    )
}

private func item(_ style: MenuBarStyle, _ limit: MenuBarLimit, _ pool: MenuBarPool) -> MenuBarItem {
    MenuBarItem(style: style, limit: limit, pool: pool, now: now)
}

private func item(_ style: MenuBarStyle, _ pool: MenuBarPool) -> MenuBarItem {
    item(style, .fiveHour, pool)
}

private typealias Run = MenuBarItem.Run

@Suite struct MenuBarStyleTests {
    @Test func defaultIsTheMarkThenTheFiveHourText() {
        let parts = item(.standard, pool(session: 88, weekly: 45)).parts
        #expect(parts == [.mark(percent: 88, state: .normal), .line([Run("5h 88%")])])
    }

    @Test func eachStyleDrawsItsOwnParts() {
        let reading = pool(session: 88, weekly: 45)
        #expect(item(.both, reading).parts == [
            .mark(percent: 88, state: .normal),
            .line([Run("5h 88%"), Run("·", isSecondary: true), Run("W 45%")]),
        ])
        #expect(item(.stacked, reading).parts == [
            .mark(percent: 88, state: .normal),
            .stack([.init(label: "5h", value: "88%", state: .normal), .init(label: "W", value: "45%", state: .normal)]),
        ])
        #expect(item(.refillTime, reading).parts == [
            .mark(percent: 88, state: .normal),
            .line([Run("5h 88%"), Run("· 2h 10m", isSecondary: true)]),
        ])
        #expect(item(.numberOnly, reading).parts == [.line([Run("5h 88%")])])
        #expect(item(.bars, reading).parts == [.bars(session: .init(percent: 88, state: .normal), weekly: .init(percent: 45, state: .normal))])
        #expect(item(.iconOnly, reading).parts == [.mark(percent: 88, state: .normal)])
        #expect(item(.ring, reading).parts == [
            .ring(.init(number: .init(percent: 88, state: .normal), arc: .init(percent: 45, state: .normal), accounts: [true, true, true, false])),
        ])
    }

    @Test func devinsDailyWindowIsLabelledOneDay() {
        let parts = item(.standard, pool(session: 73, weekly: 40, shortWindow: .day)).parts
        #expect(parts == [.mark(percent: 73, state: .normal), .line([Run("1d 73%")])])
    }

    @Test func percentagesAreWholeNumbersClampedToTheGauge() {
        let summary = PoolSummary(
            session: WindowSummary(freePercent: 88.6, resets: []),
            weekly: WindowSummary(freePercent: 100.4, resets: []),
            isPartial: false
        )
        let reading = MenuBarPool(summary: summary, shortWindow: .fiveHours, accounts: [], lastReadAt: now, now: now)
        #expect(reading.session.percent == 89)
        #expect(reading.weekly.percent == 100)
    }

    @Test func refillTimeIsTheNextResetStillAhead() {
        let summary = PoolSummary(
            session: WindowSummary(freePercent: 40, resets: [Restoration(date: now - 60, gain: 5), Restoration(date: now + 38 * 60, gain: 10)]),
            weekly: WindowSummary(freePercent: 60, resets: []),
            isPartial: false
        )
        let reading = MenuBarPool(summary: summary, shortWindow: .fiveHours, accounts: [], lastReadAt: now, now: now)
        #expect(item(.refillTime, reading).parts.last == .line([Run("5h 40%"), Run("· 38m", isSecondary: true)]))
        #expect(item(.refillTime, .weekly, reading).parts.last == .line([Run("W 60%")]))
    }
}

@Suite struct MenuBarLimitTests {
    @Test func fiveHourLimitShowsTheFiveHourWindowEvenWhenWeeklyIsLower() {
        let reading = pool(session: 88, weekly: 45)
        #expect(item(.standard, .fiveHour, reading).parts == [.mark(percent: 88, state: .normal), .line([Run("5h 88%")])])
        #expect(item(.numberOnly, .fiveHour, reading).parts == [.line([Run("5h 88%")])])
    }

    @Test func weeklyLimitShowsTheWeeklyWindowAndSetsTheWater() {
        let reading = pool(session: 88, weekly: 45)
        #expect(item(.standard, .weekly, reading).parts == [.mark(percent: 45, state: .normal), .line([Run("W 45%")])])
        #expect(item(.iconOnly, .weekly, reading).parts == [.mark(percent: 45, state: .normal)])
        #expect(item(.numberOnly, .weekly, reading).parts == [.line([Run("W 45%")])])
    }

    @Test func tighterOfTheTwoSwitchesToWhicheverWindowHasLessFree() {
        #expect(item(.standard, .tighter, pool(session: 88, weekly: 45)).parts.last == .line([Run("W 45%")]))
        #expect(item(.standard, .tighter, pool(session: 30, weekly: 45)).parts.last == .line([Run("5h 30%")]))
    }

    @Test func tighterOfTheTwoKeepsTheShortWindowOnATie() {
        #expect(item(.standard, .tighter, pool(session: 45, weekly: 45)).parts.last == .line([Run("5h 45%")]))
    }

    @Test func twoWindowStylesIgnoreTheLimit() {
        let reading = pool(session: 88, weekly: 45)
        for style in MenuBarStyle.allCases where style.showsBothWindows {
            #expect(item(style, .weekly, reading) == item(style, .fiveHour, reading), "\(style)")
        }
        #expect(MenuBarStyle.allCases.filter(\.showsBothWindows) == [.ring, .both, .stacked, .bars])
    }
}

@Suite struct LowStateTests {
    @Test func thresholdsAreFifteenAndFivePercent() {
        #expect(LowState(percent: 16) == .normal)
        #expect(LowState(percent: 15) == .low)
        #expect(LowState(percent: 6) == .low)
        #expect(LowState(percent: 5) == .critical)
        #expect(LowState(percent: 0) == .critical)
    }

    @Test func onlyTheElementCarryingTheValueIsTinted() {
        let reading = pool(session: 15, weekly: 5)
        #expect(item(.standard, reading).parts == [.mark(percent: 15, state: .normal), .line([Run("5h 15%", state: .low)])])
        #expect(item(.both, reading).parts == [
            .mark(percent: 15, state: .normal),
            .line([Run("5h 15%", state: .low), Run("·", isSecondary: true), Run("W 5%", state: .critical)]),
        ])
        #expect(item(.iconOnly, .weekly, reading).parts == [.mark(percent: 5, state: .critical)])
        #expect(item(.stacked, reading).parts.first == .mark(percent: 15, state: .normal))
        #expect(item(.refillTime, reading).parts == [.mark(percent: 15, state: .normal), .line([Run("5h 15%", state: .low), Run("· 2h 10m", isSecondary: true)])])
        #expect(item(.bars, reading).parts == [.bars(session: .init(percent: 15, state: .low), weekly: .init(percent: 5, state: .critical))])
        #expect(item(.ring, reading).parts == [
            .ring(.init(number: .init(percent: 15, state: .low), arc: .init(percent: 5, state: .critical), accounts: [true, true, true, false])),
        ])
        #expect(item(.standard, reading).isTinted)
        #expect(!item(.standard, pool(session: 16, weekly: 5)).isTinted)
    }

    @Test func anEmptyWindowAddsWhenItRefills() {
        let reading = pool(session: 0, weekly: 45, sessionRefillIn: 100)
        #expect(item(.standard, reading).parts.last == .line([Run("5h 0%", state: .critical), Run("· 1h 40m", isSecondary: true)]))
        #expect(item(.numberOnly, reading).parts.last == .line([Run("5h 0%", state: .critical), Run("· 1h 40m", isSecondary: true)]))
        #expect(item(.refillTime, reading).parts.last == .line([Run("5h 0%", state: .critical), Run("· 1h 40m", isSecondary: true)]))
        #expect(item(.stacked, reading).parts.last == .stack([
            .init(label: "5h", value: "0%", state: .critical, refill: "· 1h 40m"),
            .init(label: "W", value: "45%", state: .normal),
        ]))
    }

    @Test func oldReadingsDimTheItemAndDropTheTint() {
        let fresh = item(.standard, pool(session: 5, weekly: 45, readMinutesAgo: 9))
        #expect(!fresh.isStale)
        #expect(fresh.isTinted)
        let stale = item(.standard, pool(session: 5, weekly: 45, readMinutesAgo: 11))
        #expect(stale.isStale)
        #expect(!stale.isTinted)
        #expect(stale.parts == [.mark(percent: 5, state: .normal), .line([Run("5h 5%")])])
    }

    @Test func noReadingShowsTheMarkAtRestDimmed() {
        let empty = MenuBarItem(style: .numberOnly, limit: .fiveHour, pool: nil, now: now)
        #expect(empty.parts == [.mark(percent: MenuBarItem.restPercent, state: .normal)])
        #expect(empty.isStale)
    }
}

@Suite struct RingAccountsTests {
    @Test func dotsAppearOnlyOnRetinaScreens() {
        #expect(RingAccounts([true, false, true], backingScale: 2) == .dots([true, true, false]))
        #expect(RingAccounts([true, false, true], backingScale: 1) == .hidden)
    }

    @Test func oneAccountNeedsNoDots() {
        #expect(RingAccounts([true], backingScale: 2) == .hidden)
    }

    @Test func pastFiveAccountsTheDotsBecomeACountThatStaysAtOneX() {
        #expect(RingAccounts([true, true, true, true, false], backingScale: 2) == .dots([true, true, true, true, false]))
        #expect(RingAccounts([true, true, false, true, true, false, true], backingScale: 2) == .count(ready: 5, total: 7))
        #expect(RingAccounts([true, true, false, true, true, false, true], backingScale: 1) == .count(ready: 5, total: 7))
    }
}

@Suite struct RefillTextTests {
    @Test func roundsUpToTheMinuteHourOrDay() {
        #expect(RefillText.until(now + 37.2 * 60, now: now) == "38m")
        #expect(RefillText.until(now + 10, now: now) == "1m")
        #expect(RefillText.until(now + 60 * 60, now: now) == "1h")
        #expect(RefillText.until(now + 130 * 60, now: now) == "2h 10m")
        #expect(RefillText.until(now + (3 * 24 + 3.5) * 3600, now: now) == "3d 4h")
        #expect(RefillText.until(now + 2 * 24 * 3600, now: now) == "2d")
    }
}

@MainActor
@Suite struct MenuBarSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ebb.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsAtDefaultAndFiveHour() {
        let settings = MenuBarSettings(defaults: freshDefaults())
        #expect(settings.style == .standard)
        #expect(settings.limit == .fiveHour)
    }

    @Test func choicesSurviveARelaunch() {
        let defaults = freshDefaults()
        let settings = MenuBarSettings(defaults: defaults)
        settings.style = .ring
        settings.limit = .tighter
        let relaunched = MenuBarSettings(defaults: defaults)
        #expect(relaunched.style == .ring)
        #expect(relaunched.limit == .tighter)
    }

    @Test func unknownStoredValuesFallBackToTheDefaults() {
        let defaults = freshDefaults()
        defaults.set("sparkline", forKey: MenuBarSettings.styleKey)
        defaults.set("monthly", forKey: MenuBarSettings.limitKey)
        let settings = MenuBarSettings(defaults: defaults)
        #expect(settings.style == .standard)
        #expect(settings.limit == .fiveHour)
    }
}
