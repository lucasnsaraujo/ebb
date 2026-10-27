import Foundation
import Testing
@testable import EbbCore

private let now = Date(timeIntervalSince1970: 1_793_040_000)

private func summary(_ accounts: [[UsageLimit]]) throws -> PoolSummary {
    try #require(Pool.summarize(accounts.map { AccountUsage(weight: 1, limits: $0, readAt: now) }, at: now))
}

private let weeklyOnly = [UsageLimit(kind: .weeklyAll, usedPercent: 60, resetsAt: now + 3 * 86_400)]
private let both = [
    UsageLimit(kind: .session, usedPercent: 10, resetsAt: now + 3_600),
    UsageLimit(kind: .weeklyAll, usedPercent: 60, resetsAt: now + 3 * 86_400),
]

@Suite struct WeeklyOnlyPoolTests {
    private func item(_ style: MenuBarStyle, _ accounts: [[UsageLimit]]) throws -> MenuBarItem {
        let pool = MenuBarPool(summary: try summary(accounts), shortWindow: .fiveHours, accounts: [true], lastReadAt: now, now: now)
        return MenuBarItem(style: style, limit: .fiveHour, pool: pool, now: now)
    }

    @Test func aPoolWithNoFiveHourWindowShowsTheWeeklyNumberNotAFullFiveHourOne() throws {
        #expect(try item(.standard, [weeklyOnly]).parts == [.mark(percent: 40, state: .normal), .line([.init("W 40%")])])
        #expect(try item(.numberOnly, [weeklyOnly]).parts == [.line([.init("W 40%")])])
    }

    @Test func twoWindowStylesDropTheMissingFiveHourWindow() throws {
        #expect(try item(.both, [weeklyOnly]).parts == [.mark(percent: 40, state: .normal), .line([.init("W 40%")])])
        #expect(try item(.stacked, [weeklyOnly]).parts == [.mark(percent: 40, state: .normal), .stack([.init(label: "W", value: "40%", state: .normal)])])
    }

    @Test func oneAccountWithAFiveHourWindowBringsTheFiveHourNumberBack() throws {
        #expect(try item(.standard, [weeklyOnly, both]).parts == [.mark(percent: 95, state: .normal), .line([.init("5h 95%")])])
    }

    @Test func anAccountWithNoWindowsYetDoesNotHideTheFiveHourNumber() throws {
        #expect(try item(.standard, [[]]).parts == [.mark(percent: 100, state: .normal), .line([.init("5h 100%")])])
    }
}
