import Foundation
import Testing
@testable import EbbCore

@Suite struct ClaudePlanTests {
    @Test func maxTiersWeighTheirMultiplierASessionAndTheMeasuredRatioAWeek() {
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: "active") == .paid(weight: PlanWeight(session: 20, weekly: 7)))
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_5x", subscriptionStatus: "active") == .paid(weight: PlanWeight(session: 5, weekly: 3.5)))
    }

    @Test func paidTierWithoutMultiplierWeighsLikePro() {
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_pro", subscriptionStatus: "active") == .paid(weight: PlanWeight(1)))
    }

    @Test func anEndedSubscriptionIsInactive() {
        for status in ["canceled", "cancelled", "expired", "incomplete_expired", "inactive", "Canceled"] {
            #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: status) == .inactive, "\(status)")
        }
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: "canceled").weight == .zero)
    }

    /// Auto-retire disables the login in the proxy, so only a status that says the plan ended may lead there.
    @Test func aStatusThatDoesNotSayThePlanEndedKeepsTheTiersWeight() {
        for status in [nil, "past_due", "trialing", "unpaid_grace", ""] as [String?] {
            #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: status) == .paid(weight: PlanWeight(session: 20, weekly: 7)), "\(String(describing: status))")
        }
    }

    @Test func activePlanWithUnreadableOrFreeTierIsUnknownAndWeighsNothing() {
        #expect(ClaudeProvider.plan(rateLimitTier: nil, subscriptionStatus: "active") == .unknown)
        #expect(ClaudeProvider.plan(rateLimitTier: "free", subscriptionStatus: "active") == .unknown)
        #expect(ClaudeProvider.plan(rateLimitTier: nil, subscriptionStatus: "active").weight == .zero)
    }

    @Test func profileResponseReadsTheOrganizationPlan() throws {
        let body = #"{"account":{"email":"x"},"organization":{"rate_limit_tier":"default_claude_max_5x","subscription_status":"active"}}"#
        let profile = try #require(ClaudeProvider().parsePlan(Data(body.utf8)))
        #expect(profile.plan == .paid(weight: PlanWeight(session: 5, weekly: 3.5)))
        #expect(profile.tier == "default_claude_max_5x")
    }

    @Test func profileWithoutPlanFieldsIsNotReadAsCancelled() {
        let body = #"{"account":{"email":"x"},"organization":{"uuid":"o"}}"#
        #expect(ClaudeProvider().parsePlan(Data(body.utf8)) == nil)
    }

    @Test func cachedPlansRoundTrip() throws {
        for plan in [Plan.paid(weight: PlanWeight(session: 20, weekly: 7)), .inactive, .unknown] {
            let data = try JSONEncoder().encode(PlanProfile(plan: plan, tier: "tier"))
            #expect(try JSONDecoder().decode(PlanProfile.self, from: data).plan == plan)
        }
    }

    @Test func aPlanCachedBeforePlansHadAWeeklySizeStillLoads() throws {
        let cached = #"{"status":"paid","weight":20,"tier":"default_claude_max_20x"}"#
        let profile = try JSONDecoder().decode(PlanProfile.self, from: Data(cached.utf8))
        #expect(profile.plan == .paid(weight: PlanWeight(20)))
        #expect(profile.tier == "default_claude_max_20x")
    }

    @Test func profileCheckCadenceDependsOnState() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let hoursAgo = { (hours: Double) in now.addingTimeInterval(-hours * 3600) }
        #expect(ProfilePlan.isDue(lastCheck: nil, plan: nil, isRetired: false, now: now))
        #expect(!ProfilePlan.isDue(lastCheck: hoursAgo(5), plan: .paid(weight: PlanWeight(5)), isRetired: false, now: now))
        #expect(ProfilePlan.isDue(lastCheck: hoursAgo(6), plan: .paid(weight: PlanWeight(5)), isRetired: false, now: now))
        #expect(ProfilePlan.isDue(lastCheck: hoursAgo(0.25), plan: .inactive, isRetired: false, now: now))
        #expect(!ProfilePlan.isDue(lastCheck: hoursAgo(23), plan: .inactive, isRetired: true, now: now))
        #expect(ProfilePlan.isDue(lastCheck: hoursAgo(24), plan: .inactive, isRetired: true, now: now))
    }
}

@Suite struct RetirementTests {
    @Test func confirmedInactivePlanRetiresAnEnabledAccount() {
        #expect(Retirement.action(isDisabled: false, isRetiredByUs: false, plan: .inactive, inactiveStreak: 2) == .retire)
    }

    @Test func singleInactiveAnswerRetiresNothing() {
        #expect(Retirement.action(isDisabled: false, isRetiredByUs: false, plan: .inactive, inactiveStreak: 1) == .keep)
    }

    @Test func renewedPlanReinstatesAnAccountWeRetired() {
        #expect(Retirement.action(isDisabled: true, isRetiredByUs: true, plan: .paid(weight: PlanWeight(20)), inactiveStreak: 0) == .reinstate)
    }

    @Test func accountTheUserDisabledIsNeverReinstated() {
        #expect(Retirement.action(isDisabled: true, isRetiredByUs: false, plan: .paid(weight: PlanWeight(5)), inactiveStreak: 0) == .keep)
    }

    @Test func activeOrUnknownPlansNeverRetire() {
        #expect(Retirement.action(isDisabled: false, isRetiredByUs: false, plan: .paid(weight: PlanWeight(5)), inactiveStreak: 9) == .keep)
        #expect(Retirement.action(isDisabled: false, isRetiredByUs: false, plan: .unknown, inactiveStreak: 9) == .keep)
    }
}

@Suite struct RetiredAccountsTests {
    private let list = RetiredAccounts(
        file: FileManager.default.temporaryDirectory.appending(path: "ebb-tests-\(UUID().uuidString)/retired.json")
    )

    @Test func retiringAndReinstatingUpdateTheList() throws {
        #expect(list.load().isEmpty)
        try list.record(.retire, name: "claude-a.json")
        try list.record(.retire, name: "claude-b.json")
        #expect(list.load() == ["claude-a.json", "claude-b.json"])
        try list.record(.reinstate, name: "claude-a.json")
        #expect(list.load() == ["claude-b.json"])
    }

    @Test func accountsReenabledByHandAreForgotten() throws {
        try list.save(["claude-a.json", "claude-b.json"])
        try list.forget(allBut: ["claude-b.json", "claude-user-disabled.json"])
        #expect(list.load() == ["claude-b.json"])
    }

    /// Each proxy keeps its own list, so a remote listing never forgets what Ebb retired locally.
    @Test func eachProxyKeepsItsOwnListNamedByHost() {
        let folder = URL(fileURLWithPath: "/Users/example/.config/ebb")
        #expect(RetiredAccounts.file(in: folder, remoteHost: nil).lastPathComponent == "retired.json")
        #expect(RetiredAccounts.file(in: folder, remoteHost: "nas.local").lastPathComponent == "retired-nas.local.json")
        #expect(RetiredAccounts.file(in: folder, remoteHost: "Proxy.Example.COM").lastPathComponent == "retired-proxy.example.com.json")
        #expect(RetiredAccounts.file(in: folder, remoteHost: "[fe80::1]").lastPathComponent == "retired-fe80--1.json")
        #expect(RetiredAccounts.file(in: folder, remoteHost: "nas.local").deletingLastPathComponent().path == folder.path)
    }
}
