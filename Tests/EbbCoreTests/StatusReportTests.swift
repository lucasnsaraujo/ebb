import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

private func at(_ minutes: Double) -> Date {
    now.addingTimeInterval(minutes * 60)
}

private func provider(_ id: String, session: Double, weekly: Double, sessionResets: [Restoration] = [], weeklyResets: [Restoration] = [], isPartial: Bool = false, readAt: Date? = now) -> ProviderStatus {
    let known = Providers.named(id)
    return ProviderStatus(
        id: id,
        title: known?.title ?? id,
        shortWindow: known?.shortWindow ?? .fiveHours,
        session: WindowStatus(freePercent: session, resets: sessionResets),
        weekly: WindowStatus(freePercent: weekly, resets: weeklyResets),
        isPartial: isPartial,
        readAt: readAt
    )
}

private let pools = PoolStatus(
    updatedAt: now,
    menuBarProvider: "codex",
    providers: [
        provider("claude", session: 88.4, weekly: 45, sessionResets: [Restoration(date: at(31), gain: 12)]),
        provider("codex", session: 15, weekly: 62.6),
        provider("devin", session: 70, weekly: 40),
    ]
)

@Suite(.hangLimit) struct StatuslineTests {
    @Test func showsTheMenuBarPoolsTwoWindowsSideBySide() {
        #expect(StatusReport.statusline(pools, provider: nil, now: at(1)) == "5h 15% · W 63%")
    }

    @Test func aNamedProviderWinsOverTheMenuBarChoice() {
        #expect(StatusReport.statusline(pools, provider: "claude", now: at(1)) == "5h 88% · W 45%")
        #expect(StatusReport.statusline(pools, provider: "devin", now: at(1)) == "1d 70% · W 40%")
    }

    @Test func aResetThatLandedSinceTheReadingCountsAsFree() {
        #expect(StatusReport.statusline(pools, provider: "claude", now: at(32)) == "5h 100% · W 45% · 32m old")
    }

    @Test func oldNumbersCarryTheirAge() {
        #expect(StatusReport.statusline(pools, provider: "claude", now: at(9)) == "5h 88% · W 45%")
        #expect(StatusReport.statusline(pools, provider: "claude", now: at(25)) == "5h 88% · W 45% · 25m old")
    }

    @Test func aPoolWithNoRecentReadingSaysSoEvenWhileTheAppRuns() {
        var status = pools
        status.updatedAt = at(20)
        status.providers[0].readAt = nil
        #expect(StatusReport.statusline(status, provider: "claude", now: at(21)) == "5h 88% · W 45% · stale")
        status.providers[0].readAt = at(5)
        #expect(StatusReport.statusline(status, provider: "claude", now: at(21)) == "5h 88% · W 45% · 16m old")
    }

    @Test func saysSoWhenThereIsNothingToShow() {
        #expect(StatusReport.statusline(nil, provider: nil, now: now) == "Ebb: no data")
        #expect(StatusReport.statusline(PoolStatus(updatedAt: now, menuBarProvider: nil, providers: []), provider: nil, now: now) == "Ebb: no data")
        #expect(StatusReport.statusline(pools, provider: "kimi", now: now) == "Ebb: no kimi pool")
    }
}

@Suite(.hangLimit) struct StatusTextTests {
    private let english = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func listsEveryPoolWithBothWindowsAndTheNextRefill() {
        let weekly = Restoration(date: UsageLimit.parseTimestamp("2026-10-27T22:00:00+00:00")!, gain: 30)
        var status = pools
        status.providers[0].weekly.resets = [weekly]
        status.providers[2].isPartial = true
        #expect(StatusReport.text(status, now: at(1), timeZone: utc, locale: english) == """
        Claude
          5-hour  88% left  +12% at 8:05\u{202F}PM
          Weekly  45% left  +30% Tue 10:00\u{202F}PM
        Codex (menu bar)
          5-hour  15% left
          Weekly  63% left
        Devin (partial: some accounts can't be read, so they're left out)
          Daily   70% left
          Weekly  40% left
        Updated 1m ago.
        """)
    }

    @Test func oldNumbersSayWhyTheyMayBeOutOfDate() {
        let text = StatusReport.text(pools, now: at(130), timeZone: utc, locale: english)
        #expect(text.hasPrefix("Claude (last read 2h 10m ago)\n"))
        #expect(text.hasSuffix("Updated 2h 10m ago. Ebb may have quit, or its menu bar item is hidden."))
    }

    @Test func aRefillOnAnotherDayNamesTheDay() {
        let late = UsageLimit.parseTimestamp("2026-10-26T23:50:00+00:00")!
        #expect(StatusReport.moment(late, now: now, timeZone: utc, locale: english) == "at 11:50\u{202F}PM")
        let tomorrow = UsageLimit.parseTimestamp("2026-10-27T18:00:00+00:00")!
        #expect(StatusReport.moment(tomorrow, now: now, timeZone: utc, locale: english) == "Tue 6:00\u{202F}PM")
    }
}

@Suite(.hangLimit) struct StatusJSONTests {
    private func object(_ status: PoolStatus, now: Date) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: StatusReport.json(status, now: now)) as? [String: Any])
    }

    @Test func carriesTheDocumentedTopLevelFields() throws {
        let json = try object(pools, now: at(1))
        #expect(json["schema_version"] as? Int == 1)
        #expect(json["updated_at"] as? String == "2026-10-26T19:34:00Z")
        #expect(json["age_seconds"] as? Int == 60)
        #expect(json["is_stale"] as? Bool == false)
        #expect(json["menu_bar_provider"] as? String == "codex")
        #expect((json["providers"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["claude", "codex", "devin"])
    }

    @Test func eachPoolCarriesItsWindowsAtTheTimeAsked() throws {
        let providers = try #require(try object(pools, now: at(1))["providers"] as? [[String: Any]])
        let claude = providers[0]
        #expect(claude["name"] as? String == "Claude")
        #expect(claude["is_partial"] as? Bool == false)
        #expect(claude["read_at"] as? String == "2026-10-26T19:34:00Z")
        #expect(claude["is_stale"] as? Bool == false)
        let session = try #require(claude["short_window"] as? [String: Any])
        #expect(session["kind"] as? String == "five_hours")
        #expect(session["name"] as? String == "5-hour")
        #expect(session["free_percent"] as? Int == 88)
        let refill = try #require(session["next_refill"] as? [String: Any])
        #expect(refill["at"] as? String == "2026-10-26T20:05:00Z")
        #expect(refill["gain_percent"] as? Int == 12)
        let weekly = try #require(claude["weekly"] as? [String: Any])
        #expect(weekly["kind"] as? String == "weekly")
        #expect(weekly["free_percent"] as? Int == 45)
        #expect(weekly["next_refill"] is NSNull)
        #expect((providers[2]["short_window"] as? [String: Any])?["kind"] as? String == "day")
        #expect((providers[2]["short_window"] as? [String: Any])?["name"] as? String == "Daily")
    }

    @Test func oldNumbersAreFlaggedStale() throws {
        let json = try object(pools, now: at(11))
        #expect(json["is_stale"] as? Bool == true)
        #expect(json["age_seconds"] as? Int == 660)
        #expect((json["providers"] as? [[String: Any]])?.first?["is_stale"] as? Bool == true)
    }

    @Test func aPoolWithoutAReadingHasANullReadTime() throws {
        var status = pools
        status.providers[0].readAt = nil
        let first = try #require((try object(status, now: at(1))["providers"] as? [[String: Any]])?.first)
        #expect(first["read_at"] is NSNull)
        #expect(first["is_stale"] as? Bool == true)
    }
}
