import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

private func at(_ minutes: Double) -> Date {
    now.addingTimeInterval(minutes * 60)
}

private func pool(_ id: String, session: Double, weekly: Double, sessionResets: [Restoration] = [], weeklyResets: [Restoration] = [], readAt: Date? = now) -> ProviderStatus {
    let known = Providers.named(id)
    return ProviderStatus(
        id: id, title: known?.title ?? id, shortWindow: known?.shortWindow ?? .fiveHours,
        session: WindowStatus(freePercent: session, resets: sessionResets),
        weekly: WindowStatus(freePercent: weekly, resets: weeklyResets),
        isPartial: false, readAt: readAt
    )
}

private let status = PoolStatus(
    updatedAt: now,
    menuBarProvider: "codex",
    providers: [
        pool("claude", session: 88.4, weekly: 45, sessionResets: [Restoration(date: at(31), gain: 12)], weeklyResets: [Restoration(date: at(3000), gain: 30)]),
        pool("codex", session: 15, weekly: 62.6, weeklyResets: [Restoration(date: at(600), gain: 20)]),
        pool("devin", session: 70, weekly: 40, sessionResets: [Restoration(date: at(900), gain: 10)], weeklyResets: [Restoration(date: at(60), gain: 5)]),
    ]
)

@Suite struct PoolAnswerTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    @Test func answersForTheMenuBarPoolWhenNoProviderIsChosen() throws {
        let answer = try #require(PoolAnswer(status, provider: nil, now: at(1)))
        #expect(answer.provider == "Codex")
        #expect(answer.shortWindowFree == 15)
        #expect(answer.weeklyFree == 63)
    }

    @Test func theNextRefillIsTheSoonerOfTheTwoWindows() throws {
        let claude = try #require(PoolAnswer(status, provider: "claude", now: at(1)))
        #expect(claude.nextRefill == PoolAnswer.Refill(window: .session, date: at(31), gain: 12))
        let codex = try #require(PoolAnswer(status, provider: "codex", now: at(1)))
        #expect(codex.nextRefill == PoolAnswer.Refill(window: .weekly, date: at(600), gain: 20))
        let devin = try #require(PoolAnswer(status, provider: "devin", now: at(1)))
        #expect(devin.nextRefill == PoolAnswer.Refill(window: .weekly, date: at(60), gain: 5))
        var bare = status
        bare.providers[2].session.resets = []
        bare.providers[2].weekly.resets = []
        #expect(PoolAnswer(bare, provider: "devin", now: at(1))?.nextRefill == nil)
    }

    @Test func numbersMoveOnToTheTimeAsked() throws {
        let answer = try #require(PoolAnswer(status, provider: "claude", now: at(32)))
        #expect(answer.shortWindowFree == 100)
        #expect(answer.nextRefill == PoolAnswer.Refill(window: .weekly, date: at(3000), gain: 30))
    }

    @Test func saysBothWindowsApartInOneSentence() throws {
        let answer = try #require(PoolAnswer(status, provider: "claude", now: at(1)))
        #expect(answer.sentence(timeZone: utc, locale: english) == "Claude: 88% of the 5-hour pool and 45% of the weekly pool are left. Next refill: +12% of the 5-hour pool at 8:05\u{202F}PM.")
        let codex = try #require(PoolAnswer(status, provider: "codex", now: at(1)))
        #expect(codex.sentence(timeZone: utc, locale: english) == "Codex: 15% of the 5-hour pool and 63% of the weekly pool are left. Next refill: +20% of the weekly pool on Tue 5:34\u{202F}AM.")
        let devin = try #require(PoolAnswer(status, provider: "devin", now: at(1)))
        #expect(devin.sentence(timeZone: utc, locale: english).hasPrefix("Devin: 70% of the daily pool and 40% of the weekly pool are left."))
    }

    @Test func oldNumbersSaySo() throws {
        let answer = try #require(PoolAnswer(status, provider: "devin", now: at(25)))
        #expect(answer.isStale)
        #expect(answer.sentence(timeZone: utc, locale: english).hasSuffix(" Last read 25m ago."))
    }

    @Test func noDataOrNoSuchPoolGivesNoAnswer() {
        #expect(PoolAnswer(nil, provider: nil, now: now) == nil)
        #expect(PoolAnswer(status, provider: "kimi", now: now) == nil)
    }
}
