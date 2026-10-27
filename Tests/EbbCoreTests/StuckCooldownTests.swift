import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

private func usage(session: Double, weekly: Double, readAt: Date = now - 60) -> DatedLimits {
    DatedLimits(limits: [
        UsageLimit(kind: .session, usedPercent: session, resetsAt: now + 3 * 3600),
        UsageLimit(kind: .weeklyAll, usedPercent: weekly, resetsAt: now + 3 * 86400),
    ], date: readAt)
}

@Suite struct StuckCooldownTests {
    private let heldForDays = AccountHealth(state: .coolingDown(until: now + 18 * 86400))
    /// The proxy's last response, the one that started the cooldown.
    private let signalsAt = now - 3600

    @Test func aCooldownOverAnAccountWithQuotaIsStuck() {
        #expect(StuckCooldown.isStuck(health: heldForDays, usage: usage(session: 30, weekly: 50), signalsObservedAt: signalsAt, now: now))
        #expect(StuckCooldown.isStuck(health: heldForDays, usage: usage(session: 30, weekly: 50), signalsObservedAt: nil, now: now))
    }

    @Test func aCooldownOverASpentAccountIsDeserved() {
        #expect(!StuckCooldown.isStuck(health: heldForDays, usage: usage(session: 100, weekly: 50), signalsObservedAt: signalsAt, now: now))
        #expect(!StuckCooldown.isStuck(health: heldForDays, usage: usage(session: 30, weekly: 100), signalsObservedAt: signalsAt, now: now))
    }

    @Test func aShortBackoffIsNotStuck() {
        let brief = AccountHealth(state: .coolingDown(until: now + 5 * 60))
        #expect(!StuckCooldown.isStuck(health: brief, usage: usage(session: 30, weekly: 50), signalsObservedAt: signalsAt, now: now))
    }

    @Test func aHoldWithNoEndIsARejectedLoginNotAQuota() {
        let rejected = AccountHealth(state: .coolingDown(until: nil))
        #expect(!StuckCooldown.isStuck(health: rejected, usage: usage(session: 30, weekly: 50), signalsObservedAt: signalsAt, now: now))
    }

    @Test func onlyAUsageReadingNewerThanTheProxysLastResponseProvesIt() {
        #expect(!StuckCooldown.isStuck(health: heldForDays, usage: usage(session: 30, weekly: 50, readAt: now - 2 * 3600), signalsObservedAt: signalsAt, now: now))
        #expect(!StuckCooldown.isStuck(health: heldForDays, usage: usage(session: 30, weekly: 50, readAt: now - 20 * 60), signalsObservedAt: now - 10 * 60, now: now))
        #expect(!StuckCooldown.isStuck(health: heldForDays, usage: nil, signalsObservedAt: signalsAt, now: now))
    }

    @Test func aLoginTheProxyIsntHoldingIsNotStuck() {
        #expect(!StuckCooldown.isStuck(health: AccountHealth(state: .ok), usage: usage(session: 30, weekly: 50), signalsObservedAt: signalsAt, now: now))
        #expect(!StuckCooldown.isStuck(health: AccountHealth(state: .disabled), usage: usage(session: 30, weekly: 50), signalsObservedAt: signalsAt, now: now))
    }

    @Test func theLineCountsTheHeldAccounts() {
        #expect(StuckCooldown.line(count: 1) == "CLIProxyAPI is still holding 1 account in cooldown.")
        #expect(StuckCooldown.line(count: 3) == "CLIProxyAPI is still holding 3 accounts in cooldown.")
    }

    @Test func theCommandChecksForTheKeyFirstAndNeverHoldsIt() {
        let command = StuckCooldown.resetCommand(baseURL: URL(string: "http://127.0.0.1:8317")!, authIndexes: ["3", "7"])
        let call = { (index: String) in
            #"curl -fsS -X POST -H "Authorization: Bearer $MANAGEMENT_KEY" -H "Content-Type: application/json" -d '{"auth_index":"\#(index)"}' 'http://127.0.0.1:8317/v0/management/reset-quota'"#
        }
        #expect(command == #"if [ -z "$MANAGEMENT_KEY" ]; then echo "Set MANAGEMENT_KEY to your CLIProxyAPI management key first." >&2; else "# + call("3") + " && " + call("7") + "; fi")
    }

    @Test func anIndexOrAddressThatCouldBreakTheShellLineIsLeftOut() {
        let command = StuckCooldown.resetCommand(baseURL: URL(string: "http://127.0.0.1:8317")!, authIndexes: ["3'; rm -rf ~; '", "a1"])
        #expect(!command.contains("rm -rf"))
        #expect(command.contains(#""auth_index":"a1""#))
        #expect(StuckCooldown.resetCommand(baseURL: URL(string: "http://a'b:8317")!, authIndexes: ["a1"]).isEmpty)
        #expect(StuckCooldown.resetCommand(baseURL: URL(string: "http://127.0.0.1:8317")!, authIndexes: ["x y"]).isEmpty)
    }
}
