import Foundation
import Testing
@testable import EbbCore

/// Monday 19:34 UTC.
private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!
/// 2.1014 days on: the reset most tests pace toward.
private let wednesday = UsageLimit.parseTimestamp("2026-10-28T22:00:00+00:00")!
private let utc = TimeZone(identifier: "UTC")!
private let english = Locale(identifier: "en_US")
private let brazil = Locale(identifier: "pt_BR")

private func account(weight: Double, weeklyUsed: Double? = nil, resetsAt: Date? = wednesday) -> AccountUsage {
    AccountUsage(weight: weight, limits: weeklyUsed.map { [UsageLimit(kind: .weeklyAll, usedPercent: $0, resetsAt: resetsAt)] } ?? [], readAt: now)
}

private func weeklyBudget(_ accounts: [AccountUsage]) -> WeeklyBudget? {
    WeeklyBudget.of(accounts, totalWeight: accounts.reduce(0) { $0 + $1.weight }, now: now)
}

@Suite struct WeeklyBudgetTests {
    /// 56 + 20 pool points free over the 2.1014 days until the big account resets: 36 a day.
    @Test func theCappedFreeShareIsSpreadOverTheDaysUntilTheSoonestMeaningfulReset() throws {
        let budget = try #require(weeklyBudget([account(weight: 20, weeklyUsed: 30), account(weight: 5, weeklyUsed: 0, resetsAt: now + 5.3 * 86400)]))
        #expect(budget.freePercent == 76)
        #expect(budget.resetsAt == wednesday)
        #expect(budget.percentPerDay(at: now) == 36)
    }

    /// A Pro beside a Max 20x holds under a tenth of the pool, so its reset tomorrow doesn't cut the week short.
    @Test func aSmallAccountsResetDoesNotSetTheHorizon() throws {
        let budget = try #require(weeklyBudget([account(weight: 1, weeklyUsed: 50, resetsAt: now + 1.5 * 86400), account(weight: 20, weeklyUsed: 50)]))
        #expect(budget.resetsAt == wednesday)
        #expect(budget.percentPerDay(at: now) == 24)
    }

    /// A fresh Max 5x resetting tomorrow brings nothing back, so the Max 20x's reset in six days is the horizon.
    @Test func aResetThatBringsNothingBackIsNotTheHorizon() throws {
        let budget = try #require(weeklyBudget([account(weight: 5, weeklyUsed: 0, resetsAt: now + 1.1 * 86400), account(weight: 20, weeklyUsed: 50, resetsAt: now + 6 * 86400)]))
        #expect(budget.freePercent == 60)
        #expect(budget.resetsAt == now + 6 * 86400)
        #expect(budget.percentPerDay(at: now) == 10)
    }

    /// The card's free share counts an uncapped account as fully free; a budget in capped terms would contradict it.
    @Test func aPoolWithAnUncappedAccountHasNoBudget() {
        #expect(weeklyBudget([account(weight: 1), account(weight: 1)]) == nil)
        #expect(weeklyBudget([account(weight: 1), account(weight: 1, weeklyUsed: 40)]) == nil)
    }

    @Test func aResetUnderADayAwayHidesTheLine() throws {
        let budget = try #require(weeklyBudget([account(weight: 5, weeklyUsed: 20, resetsAt: now + 20 * 3600)]))
        #expect(budget.percentPerDay(at: now) == nil)
        #expect(PaceText.budget(budget, now: now, timeZone: utc, locale: english) == nil)
        #expect(budget.percentPerDay(at: now - 5 * 3600) == 77)
    }

    @Test func aNearlyEmptyShareHidesTheLine() {
        #expect(weeklyBudget([account(weight: 5, weeklyUsed: 97)])?.percentPerDay(at: now) == nil)
        #expect(weeklyBudget([account(weight: 5, weeklyUsed: 95)])?.percentPerDay(at: now) == 2)
    }

    @Test func aWindowWithoutAResetDateGivesNoHorizonButStillCounts() {
        #expect(weeklyBudget([account(weight: 5, weeklyUsed: 20, resetsAt: nil)]) == nil)
        let budget = weeklyBudget([account(weight: 5, weeklyUsed: 20, resetsAt: nil), account(weight: 5, weeklyUsed: 60)])
        #expect(budget?.freePercent == 60)
        #expect(budget?.resetsAt == wednesday)
    }

    /// A window whose reset passed reads as fresh, and its next reset isn't known yet.
    @Test func aResetAlreadyPassedIsNotAHorizon() {
        #expect(weeklyBudget([account(weight: 5, weeklyUsed: 80, resetsAt: now - 60)]) == nil)
        let budget = weeklyBudget([account(weight: 5, weeklyUsed: 80, resetsAt: now - 60), account(weight: 5, weeklyUsed: 50)])
        #expect(budget?.freePercent == 75)
        #expect(budget?.resetsAt == wednesday)
    }

    @Test func thePoolSummaryCarriesTheBudget() throws {
        let accounts = [account(weight: 20, weeklyUsed: 30), account(weight: 5, weeklyUsed: 0, resetsAt: now + 5.3 * 86400)]
        let summary = try #require(Pool.summarize(accounts, at: now))
        #expect(summary.weeklyBudget == WeeklyBudget(freePercent: 76, resetsAt: wednesday))
        #expect(Pool.summarize([account(weight: 1)], at: now)?.weeklyBudget == nil)
    }

    @Test func theLineReadsInBothLanguagesWithTheLocalesClock() throws {
        let budget = try #require(weeklyBudget([account(weight: 20, weeklyUsed: 30), account(weight: 5, weeklyUsed: 0, resetsAt: now + 5.3 * 86400)]))
        #expect(PaceText.budget(budget, now: now, timeZone: utc, locale: english) == "About 36% a day lasts until Wed 10:00\u{202F}PM")
        #expect(PaceText.budget(budget, now: now, timeZone: utc, locale: brazil) == "Cerca de 36% por dia dura até qua. 22:00")
    }
}
