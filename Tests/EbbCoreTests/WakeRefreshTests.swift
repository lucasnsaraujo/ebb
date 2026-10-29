import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) struct WakeRefreshTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    @Test func aWakeReadsTheAccountWhoseReadingWentStaleLongestAgo() {
        let states = [
            "a": FetchState(lastAttempt: minutesAgo(10)),
            "b": FetchState(lastAttempt: minutesAgo(480)),
            "c": FetchState(lastAttempt: minutesAgo(0.5)),
        ]
        #expect(WakeRefresh.account(in: states, lastRequest: minutesAgo(480), now: now) == "b")
    }

    /// The loops fire on wake too, their sleeps having run out; the wake must not add to them.
    @Test func aWakeWithinAMinuteOfTheLastProviderRequestReadsNothing() {
        let states = ["a": FetchState(lastAttempt: minutesAgo(480))]
        #expect(WakeRefresh.account(in: states, lastRequest: now.addingTimeInterval(-20), now: now) == nil)
        #expect(WakeRefresh.account(in: states, lastRequest: now.addingTimeInterval(-RefreshPlan.minimumSpacing), now: now) == "a")
        #expect(WakeRefresh.account(in: states, lastRequest: nil, now: now) == "a")
    }

    @Test func aShortNapLeavesFreshReadingsAlone() {
        let states = [
            "a": FetchState(lastAttempt: minutesAgo(1)),
            "b": FetchState(lastAttempt: minutesAgo(1.5), retryNotBefore: now.addingTimeInterval(600)),
        ]
        #expect(WakeRefresh.account(in: states, lastRequest: minutesAgo(5), now: now) == nil)
    }

    @Test func slotIsFreeAMinuteAfterTheLastRequest() {
        #expect(RefreshPlan.isSlotFree(lastRequest: nil, now: now))
        #expect(!RefreshPlan.isSlotFree(lastRequest: now.addingTimeInterval(-59), now: now))
        #expect(RefreshPlan.isSlotFree(lastRequest: now.addingTimeInterval(-60), now: now))
    }
}
