import Foundation
import Testing
@testable import EbbCore

private let fiveHours: TimeInterval = 5 * 60 * 60

private func summary(
    sessionFree: Double = 100, sessionResets: [Restoration] = [], weeklyFree: Double = 100, weeklyResets: [Restoration] = [],
    weight: Double, weeklyWeight: Double? = nil, isPartial: Bool = false, readableShare: Double = 1, weeklyUncapped: Double = 0
) -> PoolSummary {
    PoolSummary(
        session: WindowSummary(freePercent: sessionFree, resets: sessionResets),
        weekly: WindowSummary(freePercent: weeklyFree, resets: weeklyResets, uncappedPercent: weeklyUncapped),
        isPartial: isPartial,
        totalWeight: PlanWeight(session: weight, weekly: weeklyWeight ?? weight),
        readableShare: readableShare
    )
}

private func session(_ run: LedgerRun, _ pool: PoolSummary) -> Pace.Forecast? {
    Pace.session(run.ledger, pool: run.pool, summary: pool, horizon: fiveHours, now: run.now)
}

private func weekly(_ run: LedgerRun, _ pool: PoolSummary) -> Pace.Forecast? {
    Pace.weekly(run.ledger, pool: run.pool, summary: pool, now: run.now)
}

/// Seconds to run out, when the forecast is a single value.
private func runOut(_ forecast: Pace.Forecast?) -> TimeInterval? {
    guard case let .runsOut(within) = forecast?.outlook, within.lowerBound == within.upperBound else { return nil }
    return within.lowerBound
}

@Suite struct SessionPaceTests {
    @Test func aSteadyBurnRunsOutOnTime() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)

        let forecast = try #require(session(run, summary(sessionFree: 40, weight: 20)))

        let seconds = try #require(runOut(forecast))
        #expect(abs(seconds - 2 * 3600) < 3 * 60)
        #expect(PaceText.sentence(forecast, window: .session, short: .fiveHours, now: run.now) == "About 2 h left at this pace")
    }

    /// Session demand is kept in 5-hour weights, so the pool's weekly weight never enters it.
    @Test func sessionDemandIsDividedByThePoolsFiveHourWeight() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)

        let forecast = try #require(session(run, summary(sessionFree: 40, weight: 20, weeklyWeight: 7)))
        #expect(abs(try #require(runOut(forecast)) - 2 * 3600) < 3 * 60)
    }

    @Test func idleShowsNothingRatherThanLasting() {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)
        run.idle(minutes: 180)

        #expect(session(run, summary(sessionFree: 40, weight: 20)) == nil)
    }

    @Test func aShortPauseCountsAsActiveTime() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 20)
        run.idle(minutes: 6)
        run.burn(["a": 20], minutes: 20)

        let forecast = try #require(session(run, summary(sessionFree: 40, weight: 20)))
        #expect(forecast.basis >= 45 * 60)
    }

    @Test func aLongPauseIsLeftOutSoItDoesNotDiluteThePace() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 20)
        run.idle(minutes: 15)
        run.burn(["a": 20], minutes: 20)

        let forecast = try #require(session(run, summary(sessionFree: 40, weight: 20)))
        #expect(forecast.basis < 45 * 60)
        #expect(abs(try #require(runOut(forecast)) - 2 * 3600) < 3 * 60)
    }

    @Test func twelveIdleMinutesHideThePace() {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)
        run.idle(minutes: 12)

        #expect(session(run, summary(sessionFree: 40, weight: 20)) == nil)
    }

    @Test func oneJumpIsNotEnoughEvidence() {
        var run = LedgerRun(weights: ["a": 20])
        run.idle(minutes: 20)
        run.now += 30
        run.used["a"] = 8
        run.poll()

        #expect(session(run, summary(sessionFree: 40, weight: 20)) == nil)
    }

    @Test func aFiveMinuteBurstIsNotEnoughEvidence() {
        var run = LedgerRun(weights: ["a": 20])
        run.idle(minutes: 20)
        run.burn(["a": 96], minutes: 5)

        #expect(session(run, summary(sessionFree: 40, weight: 20)) == nil)
    }

    @Test func aBurstAfterLightUseShowsARangeNotAnAlarm() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 3], minutes: 70)
        run.burn(["a": 30], minutes: 20)

        let forecast = try #require(session(run, summary(sessionFree: 60, weight: 20)))

        guard case let .runsOut(within) = forecast.outlook else {
            Issue.record("expected a run-out")
            return
        }
        #expect(within.upperBound / within.lowerBound >= Pace.bracketRatio)
        #expect(PaceText.inline(forecast, window: .session, now: run.now)?.contains("–") == true)
    }

    @Test func useUnderOnePoolPointIsBelowTheEvidenceFloor() {
        var run = LedgerRun(weights: ["a": 20, "b": 25])
        run.burn(["a": 3], minutes: 20)

        #expect(session(run, summary(sessionFree: 40, weight: 45)) == nil)
    }

    @Test func aResetInsideTheWindowCanPushTheRunOutBackOrCancelIt() throws {
        let now = ledgerStart
        let soon = [Restoration(date: now + 3600, gain: 20)]
        let plenty = [Restoration(date: now + 3600, gain: 60)]

        let pushed = try #require(Pace.timeToEmpty(free: 20, resets: soon, rate: 10, horizon: fiveHours, now: now))
        #expect(abs(pushed - 4 * 3600) < 1)
        #expect(Pace.timeToEmpty(free: 20, resets: plenty, rate: 10, horizon: fiveHours, now: now) == nil)
        #expect(Pace.timeToEmpty(free: 20, resets: [], rate: 10, horizon: fiveHours, now: now) == TimeInterval(2 * 3600))
    }

    @Test func anAddedAccountSpreadsTheSameDemandOverMoreCapacity() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 10], minutes: 45)
        let alone = try #require(runOut(session(run, summary(sessionFree: 20, weight: 20))))

        run.weights["b"] = 20
        run.used["b"] = 50
        run.now += 30
        run.poll()
        let shared = try #require(runOut(session(run, summary(sessionFree: 20, weight: 40))))

        #expect(abs(shared - 2 * alone) < 5 * 60)
    }

    @Test func aRetiredAccountsPastDemandStillCounts() throws {
        var run = LedgerRun(weights: ["a": 20, "b": 20])
        run.burn(["a": 10, "b": 10], minutes: 45)
        let before = try #require(runOut(session(run, summary(sessionFree: 30, weight: 40))))

        run.ledger.keepAccounts(["a"], in: run.pool)
        run.weights["b"] = nil
        let after = try #require(runOut(session(run, summary(sessionFree: 30, weight: 20))))

        #expect(abs(after - before / 2) < 5 * 60)
    }

    @Test func useWhileEbbWasNotWatchingDoesNotInflateThePace() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.poll()
        run.away(minutes: 240)
        run.ledger.heartbeat(at: run.now)
        run.record("a", at: ledgerStart)
        run.now += 60
        run.used["a"] = 20
        run.poll()
        run.burn(["a": 20], minutes: 30)

        #expect(abs(try #require(runOut(session(run, summary(sessionFree: 40, weight: 20)))) - 2 * 3600) < 3 * 60)
    }

    @Test func aClockBehindTheRecordShowsNothing() {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)
        run.now -= 60 * 60
        run.poll()

        #expect(session(run, summary(sessionFree: 40, weight: 20)) == nil)
    }

    @Test func aPartlyReadPoolShowsNothingUnlessMostOfItWasRead() {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)

        #expect(session(run, summary(sessionFree: 40, weight: 20, isPartial: true, readableShare: 0.75)) == nil)
        #expect(session(run, summary(sessionFree: 40, weight: 20, isPartial: true, readableShare: 0.8)) != nil)
    }

    @Test func anEmptyPoolKeepsItsUsualLine() {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 20], minutes: 45)

        #expect(session(run, summary(sessionFree: 0.3, weight: 20)) == nil)
    }

    @Test func aPoolThatLastsSaysSoOnlyOnHover() throws {
        var run = LedgerRun(weights: ["a": 20])
        run.burn(["a": 5], minutes: 45)

        let forecast = try #require(session(run, summary(sessionFree: 80, weight: 20)))

        #expect(forecast.outlook == .lasts)
        #expect(PaceText.inline(forecast, window: .session, now: run.now) == nil)
        #expect(PaceText.sentence(forecast, window: .session, short: .fiveHours, now: run.now) == "Lasts through the next 5 hours at this pace")
    }
}

@Suite struct WeeklyPaceTests {
    /// Three working sessions a day at 2 points an hour, polled around the clock.
    private func workDays(_ days: Int, run: inout LedgerRun, asleepAtNight: Bool = false) {
        for _ in 0..<days {
            for _ in 0..<3 {
                run.burn(["a": 2], minutes: 60)
                run.idle(minutes: 120)
            }
            if asleepAtNight {
                run.away(minutes: 15 * 60)
                run.poll()
            } else {
                run.idle(minutes: 15 * 60)
            }
        }
    }

    @Test func weeklyNeedsADayOfHistory() throws {
        var run = LedgerRun(weights: ["a": 20], kind: .weekly)
        for _ in 0..<3 {
            run.burn(["a": 2], minutes: 60)
            run.idle(minutes: 120)
        }
        run.idle(minutes: 13 * 60)
        #expect(weekly(run, summary(weeklyFree: 10, weight: 20)) == nil)

        run.idle(minutes: 150)
        #expect(weekly(run, summary(weeklyFree: 10, weight: 20)) != nil)
    }

    /// Weekly demand is kept in weekly weights, where a Max 20x weighs 7, not its 5-hour 20.
    @Test func weeklyDemandIsDividedByThePoolsWeeklyWeight() throws {
        var run = LedgerRun(weights: ["a": 7], kind: .weekly)
        workDays(2, run: &run)

        let max20 = try #require(runOut(weekly(run, summary(weeklyFree: 20, weight: 20, weeklyWeight: 7))))
        let sameInBothWindows = try #require(runOut(weekly(run, summary(weeklyFree: 20, weight: 7))))
        #expect(max20 == sameInBothWindows)
    }

    @Test func weeklyNeedsThreeSeparateSessions() {
        var run = LedgerRun(weights: ["a": 20], kind: .weekly)
        run.burn(["a": 2], minutes: 60)
        run.idle(minutes: 120)
        run.burn(["a": 2], minutes: 60)
        run.idle(minutes: 23 * 60)

        #expect(weekly(run, summary(weeklyFree: 10, weight: 20)) == nil)
    }

    @Test func twoQuietDaysHideTheWeeklyPace() {
        var run = LedgerRun(weights: ["a": 20], kind: .weekly)
        workDays(2, run: &run)
        #expect(weekly(run, summary(weeklyFree: 10, weight: 20)) != nil)

        run.idle(minutes: 49 * 60)
        #expect(weekly(run, summary(weeklyFree: 10, weight: 20)) == nil)
    }

    @Test func nightsAsleepAreNotCountedAsIdle() throws {
        var awake = LedgerRun(weights: ["a": 20], kind: .weekly)
        workDays(3, run: &awake)
        var asleep = LedgerRun(weights: ["a": 20], kind: .weekly)
        workDays(3, run: &asleep, asleepAtNight: true)

        let idleNights = try #require(runOut(weekly(awake, summary(weeklyFree: 20, weight: 20))))
        let sleptNights = try #require(runOut(weekly(asleep, summary(weeklyFree: 20, weight: 20))))

        #expect(sleptNights < idleNights * 0.75)
    }

    @Test func anAccountsWeeklyResetKeepsThePoolsPace() throws {
        var run = LedgerRun(weights: ["a": 20, "b": 20], kind: .weekly)
        run.used["a"] = 80
        run.resets["a"] = ledgerStart + 2 * 24 * 3600 + 30
        workDays(2, run: &run)
        let before = try #require(runOut(weekly(run, summary(weeklyFree: 10, weight: 40))))
        let units = run.totals.units

        run.now = ledgerStart + 2 * 24 * 3600 + 60
        run.used["a"] = 0
        run.resets["a"] = run.now + 7 * 24 * 3600 - 120
        run.poll()

        #expect(run.totals.units >= units)
        let after = try #require(runOut(weekly(run, summary(weeklyFree: 10, weight: 40))))
        #expect(abs(after - before) < 3 * 3600)
    }

    @Test func aPoolWithAnUncappedAccountNeverRunsOutWeekly() {
        var run = LedgerRun(weights: ["a": 20], kind: .weekly)
        workDays(2, run: &run)

        #expect(weekly(run, summary(weeklyFree: 50, weight: 40, weeklyUncapped: 50)) == nil)
    }

    @Test func sessionAndWeeklyDemandStayApart() {
        var ledger = DemandLedger()
        var now = ledgerStart
        var used = (session: 0.0, weekly: 0.0)
        for _ in 0..<60 {
            now += 30
            used.session += 0.5
            used.weekly += 0.05
            ledger.heartbeat(at: now)
            ledger.record(UsageLimit(kind: .session, usedPercent: used.session, resetsAt: ledgerStart + fiveHours), readAt: now, pool: "claude", kind: .session, account: "a", weight: 20, window: fiveHours)
            ledger.record(UsageLimit(kind: .weeklyAll, usedPercent: used.weekly, resetsAt: ledgerStart + 6 * 86400), readAt: now, pool: "claude", kind: .weekly, account: "a", weight: 20, window: 7 * 86400)
        }

        #expect(abs(ledger.totals(pool: "claude", kind: .session).units - 20 * 29.5) < 0.001)
        #expect(abs(ledger.totals(pool: "claude", kind: .weekly).units - 20 * 2.95) < 0.001)
    }
}

@Suite struct PaceTextTests {
    @Test func durationsRoundLikeBattery() {
        #expect(PaceText.duration(9 * 60) == "Under 10 min")
        #expect(PaceText.duration(37 * 60) == "35 min")
        #expect(PaceText.duration(58 * 60) == "1 h")
        #expect(PaceText.duration(120 * 60) == "2 h")
        #expect(PaceText.duration(130 * 60) == "2 h 10 min")
        #expect(PaceText.duration(400 * 60) == "6 h 30 min")
    }

    @Test func sessionLinesSayAboutOrUnder() {
        let now = ledgerStart
        let single = Pace.Forecast(outlook: .runsOut(within: 7800...7800), basis: 2700)
        let soon = Pace.Forecast(outlook: .runsOut(within: 300...300), basis: 2700)
        let range = Pace.Forecast(outlook: .runsOut(within: 4000...7000), basis: 2700)

        #expect(PaceText.inline(single, window: .session, now: now) == "About 2 h 10 min left")
        #expect(PaceText.inline(soon, window: .session, now: now) == "Under 10 min left")
        #expect(PaceText.inline(range, window: .session, now: now) == "1–2 h left")
        let nearAnHour = Pace.Forecast(outlook: .runsOut(within: 3500...7000), basis: 2700)
        #expect(PaceText.inline(nearAnHour, window: .session, now: now) == "1–2 h left")
        #expect(PaceText.sentence(range, window: .session, short: .fiveHours, now: now) == "1–2 h left at this pace")
        #expect(PaceText.basis(single, window: .session) == "Based on 45 min of activity")
    }

    @Test func weeklyRunOutNamesTheDayInLocalTimeAcrossADaylightSavingChange() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let english = Locale(identifier: "en_GB")
        // Saturday 24 October 2026, 12:00 CEST; clocks go back on Sunday the 25th.
        let now = Date(timeIntervalSince1970: 1_792_836_000)
        let forecast = Pace.Forecast(outlook: .runsOut(within: (5 * 86400 + 20 * 60)...(5 * 86400 + 20 * 60)), basis: 5 * 86400)

        #expect(PaceText.inline(forecast, window: .weekly, now: now, timeZone: berlin, locale: english) == "Runs out ~Thu 11:00")
        #expect(PaceText.sentence(forecast, window: .weekly, short: .fiveHours, now: now, timeZone: berlin, locale: english) == "Runs out around Thu 11:00 at this pace")
        #expect(PaceText.sentence(Pace.Forecast(outlook: .lasts, basis: 5 * 86400), window: .weekly, short: .fiveHours, now: now) == "Lasts until reset at this pace")
        #expect(PaceText.basis(forecast, window: .weekly) == "Based on the last 5 days")
    }
}
