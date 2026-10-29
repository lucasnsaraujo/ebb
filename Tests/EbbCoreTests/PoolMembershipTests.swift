import Foundation
import Testing
@testable import EbbCore

private let now = Date(timeIntervalSince1970: 1_793_040_000)
private let english = Locale(identifier: "en_US")
private let brazil = Locale(identifier: "pt_BR")

private func roster(_ pool: String = "claude", title: String = "Claude", present: [String], counted: [(String, String?)], retired: [String] = []) -> PoolRoster {
    PoolRoster(
        pool: pool, title: title, present: present.map { "\($0)@example.com" },
        counted: counted.map { PoolRoster.Account(id: "\($0.0)@example.com", plan: $0.1) },
        retired: retired.map { "\($0)@example.com" }
    )
}

private func account(_ name: String, plan: String? = "Max 20x") -> PoolRoster.Account {
    PoolRoster.Account(id: "\(name)@example.com", plan: plan)
}

/// Two Claude logins, both counted, as a baseline taken on Ebb's first run.
private func startedTracker() -> MembershipTracker {
    var tracker = MembershipTracker()
    #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)
    return tracker
}

@Suite(.hangLimit) struct JoinedAlertTests {
    @Test func theFirstListingIsABaselineNotNews() {
        var tracker = startedTracker()
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)
    }

    @Test func anAccountPresentAtTheBaselineButReadLaterNeverJoins() {
        var tracker = MembershipTracker()
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x")])], locale: english).isEmpty)
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)
    }

    @Test func aNewAccountJoinsOnceWhenItStartsCounting() throws {
        var tracker = startedTracker()
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b", "c"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)

        let joined = tracker.alerts(rosters: [roster(present: ["a", "b", "c"], counted: [("a", "Max 20x"), ("b", "Max 5x"), ("c", "Max 5x")])], locale: english)
        #expect(joined.map(\.title) == ["Claude: a new Max 5x account joined the pool"])
        #expect(joined.map(\.body) == ["The pool now has 3 accounts."])
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b", "c"], counted: [("a", "Max 20x"), ("b", "Max 5x"), ("c", "Max 5x")])], locale: english).isEmpty)
    }

    @Test func aPlanWithoutANameIsLeftUnsaid() {
        var tracker = startedTracker()
        let joined = tracker.alerts(rosters: [roster(present: ["a", "b", "c"], counted: [("a", "Max 20x"), ("b", "Max 5x"), ("c", nil)])], locale: english)
        #expect(joined.map(\.title) == ["Claude: a new account joined the pool"])
    }

    @Test func aPoolAppearingAfterTheBaselineAnnouncesItsAccount() {
        var tracker = startedTracker()
        let rosters = [
            roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")]),
            roster("codex", title: "Codex", present: ["t"], counted: [("t", "Team")]),
        ]
        let joined = tracker.alerts(rosters: rosters, locale: english)
        #expect(joined.map(\.title) == ["Codex: a new Team account joined the pool"])
        #expect(joined.map(\.body) == ["The pool now has 1 account."])
    }

    @Test func anAccountMissingFromAPollNeverJoinsAgain() {
        var tracker = startedTracker()
        #expect(tracker.alerts(rosters: [roster(present: ["a"], counted: [("a", "Max 20x")])], locale: english).isEmpty)
        #expect(tracker.alerts(rosters: [], locale: english).isEmpty)
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)
    }

    /// Gone for as many polls as `AlertTracker` takes to call an account gone, it's forgotten, so its return is news.
    @Test func anAccountGoneForThreePollsJoinsAgainWhenItReturns() {
        var tracker = startedTracker()
        for _ in 0..<3 {
            #expect(tracker.alerts(rosters: [roster(present: ["a"], counted: [("a", "Max 20x")])], locale: english).isEmpty)
        }
        let back = tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english)
        #expect(back.map(\.title) == ["Claude: a new Max 5x account joined the pool"])
    }

    /// Onboarding: the proxy answers before any login exists, and each login added then is still the baseline.
    @Test func theBaselineWaitsForTheFirstCountedLogin() {
        var tracker = MembershipTracker()
        #expect(tracker.alerts(rosters: [], locale: english).isEmpty)
        #expect(tracker.alerts(rosters: [roster(present: ["a"], counted: [])], locale: english).isEmpty)
        #expect(tracker.alerts(rosters: [roster(present: ["a"], counted: [("a", "Max 20x")])], locale: english).isEmpty)
        let joined = tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english)
        #expect(joined.map(\.title) == ["Claude: a new Max 5x account joined the pool"])
    }

    @Test func aRelaunchNeverRepeatsAJoin() throws {
        var tracker = startedTracker()
        let full = roster(present: ["a", "b", "c"], counted: [("a", "Max 20x"), ("b", "Max 5x"), ("c", "Pro")])
        #expect(tracker.alerts(rosters: [full], locale: english).count == 1)
        var restored = try JSONDecoder().decode(MembershipTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored.alerts(rosters: [full], locale: english).isEmpty)
    }

    @Test func theSavedTrackerNeverHoldsAnEmail() throws {
        var tracker = startedTracker()
        _ = tracker.alert(after: .retire, accepted: true, pool: "claude", title: "Claude", account: account("a"), now: now, locale: english)
        let saved = String(decoding: try JSONEncoder().encode(tracker), as: UTF8.self)
        #expect(!saved.contains("example.com"))
    }

    @Test func aJoinSpeaksPortuguese() {
        var tracker = startedTracker()
        let joined = tracker.alerts(rosters: [roster(present: ["a", "b", "c"], counted: [("a", "Max 20x"), ("b", "Max 5x"), ("c", "Max 5x")])], locale: brazil)
        #expect(joined.map(\.title) == ["Claude: uma nova conta Max 5x entrou na cota"])
        #expect(joined.map(\.body) == ["A cota agora tem 3 contas."])
    }
}

@Suite(.hangLimit) struct RetirementAlertTests {
    private func retire(_ tracker: inout MembershipTracker, _ account: PoolRoster.Account, accepted: Bool = true, pool: String = "claude", title: String = "Claude", locale: Locale = english) -> PoolAlert? {
        tracker.alert(after: .retire, accepted: accepted, pool: pool, title: title, account: account, now: now, locale: locale)
    }

    private func reinstate(_ tracker: inout MembershipTracker, _ account: PoolRoster.Account, accepted: Bool = true, pool: String = "claude", title: String = "Claude", locale: Locale = english) -> PoolAlert? {
        tracker.alert(after: .reinstate, accepted: accepted, pool: pool, title: title, account: account, now: now, locale: locale)
    }

    @Test func aRetirementTheProxyAcceptedAlertsOnce() {
        var tracker = startedTracker()
        let left = retire(&tracker, account("a"))
        #expect(left?.title == "Claude: a Max 20x account left the pool")
        #expect(left?.body == "Its plan ended, so Ebb disabled it in the proxy. It's enabled again if the plan renews.")
        #expect(retire(&tracker, account("a")) == nil)
    }

    @Test func aReinstatementTheProxyAcceptedAlertsOnce() {
        var tracker = startedTracker()
        _ = retire(&tracker, account("a"))
        let back = reinstate(&tracker, account("a"))
        #expect(back?.title == "Claude: a Max 20x account is back in the pool")
        #expect(back?.body == "Its plan is active again, so Ebb enabled it in the proxy.")
        #expect(reinstate(&tracker, account("a")) == nil)
        #expect(retire(&tracker, account("a"))?.title == "Claude: a Max 20x account left the pool")
    }

    @Test func aRetirementOrReinstatementTheProxyRefusedNeverFires() {
        var tracker = startedTracker()
        #expect(retire(&tracker, account("a"), accepted: false) == nil)
        #expect(retire(&tracker, account("a")) != nil)
        #expect(reinstate(&tracker, account("a"), accepted: false) == nil)
        #expect(reinstate(&tracker, account("a")) != nil)
    }

    @Test func keepingAnAccountSaysNothing() {
        var tracker = startedTracker()
        #expect(tracker.alert(after: .keep, accepted: true, pool: "claude", title: "Claude", account: account("a"), now: now, locale: english) == nil)
    }

    @Test func aReinstatementOfAnAccountEbbNeverRetiredIsNotNews() {
        var tracker = startedTracker()
        #expect(reinstate(&tracker, account("a")) == nil)
    }

    /// Ebb retired it before this tracker existed: the listing says so, and putting it back is news.
    @Test func anAccountRetiredBeforeTheBaselineComesBackWithAnAlert() {
        var tracker = MembershipTracker()
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x")], retired: ["b"])], locale: english).isEmpty)
        #expect(reinstate(&tracker, account("b", plan: "Max 5x"))?.title == "Claude: a Max 5x account is back in the pool")
    }

    /// The user enabled it by hand, so Ebb's record dropped it; retiring it again is a new event.
    @Test func aRetirementForgottenByTheRecordCanBeAnnouncedAgain() {
        var tracker = startedTracker()
        _ = retire(&tracker, account("a"))
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)
        #expect(retire(&tracker, account("a")) != nil)
    }

    @Test func aRetiredAccountComingBackNeverReadsAsJoining() {
        var tracker = startedTracker()
        _ = retire(&tracker, account("a"))
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("b", "Max 5x")], retired: ["a"])], locale: english).isEmpty)
        _ = reinstate(&tracker, account("a"))
        #expect(tracker.alerts(rosters: [roster(present: ["a", "b"], counted: [("a", "Max 20x"), ("b", "Max 5x")])], locale: english).isEmpty)
    }

    @Test func aRelaunchRemembersWhatEbbRetired() throws {
        var tracker = startedTracker()
        _ = retire(&tracker, account("a"))
        var restored = try JSONDecoder().decode(MembershipTracker.self, from: JSONEncoder().encode(tracker))
        #expect(retire(&restored, account("a")) == nil)
        #expect(reinstate(&restored, account("a")) != nil)
    }

    @Test func englishPicksTheArticleForThePlan() {
        var tracker = startedTracker()
        #expect(retire(&tracker, account("e", plan: "Enterprise"), pool: "codex", title: "Codex")?.title == "Codex: an Enterprise account left the pool")
        #expect(reinstate(&tracker, account("e", plan: "Enterprise"), pool: "codex", title: "Codex")?.title == "Codex: an Enterprise account is back in the pool")
        #expect(retire(&tracker, account("x", plan: nil))?.title == "Claude: an account left the pool")
        #expect(reinstate(&tracker, account("x", plan: nil))?.title == "Claude: an account is back in the pool")
    }

    @Test func retirementsSpeakPortuguese() {
        var tracker = startedTracker()
        let left = retire(&tracker, account("a"), locale: brazil)
        #expect(left?.title == "Claude: uma conta Max 20x saiu da cota")
        #expect(left?.body == "O plano acabou, então o Ebb a desativou no proxy. Ela volta a ser ativada se o plano for renovado.")
        let back = reinstate(&tracker, account("a"), locale: brazil)
        #expect(back?.title == "Claude: uma conta Max 20x voltou à cota")
        #expect(back?.body == "O plano está ativo de novo, então o Ebb a reativou no proxy.")
        #expect(retire(&tracker, account("e", plan: "Enterprise"), pool: "codex", title: "Codex", locale: brazil)?.title == "Codex: uma conta Enterprise saiu da cota")
    }
}
