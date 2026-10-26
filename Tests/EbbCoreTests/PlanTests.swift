import Foundation
import Testing
@testable import EbbCore

@Suite struct ClaudePlanTests {
    @Test func maxTiersWeighByTheirMultiplier() {
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: "active") == .paid(weight: 20))
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_5x", subscriptionStatus: "active") == .paid(weight: 5))
    }

    @Test func paidTierWithoutMultiplierWeighsLikePro() {
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_pro", subscriptionStatus: "active") == .paid(weight: 1))
    }

    @Test func subscriptionThatIsNotActiveIsInactive() {
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: "canceled") == .inactive)
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: nil) == .inactive)
        #expect(ClaudeProvider.plan(rateLimitTier: "default_claude_max_20x", subscriptionStatus: "canceled").weight == 0)
    }

    @Test func activePlanWithUnreadableOrFreeTierIsUnknownAndWeighsNothing() {
        #expect(ClaudeProvider.plan(rateLimitTier: nil, subscriptionStatus: "active") == .unknown)
        #expect(ClaudeProvider.plan(rateLimitTier: "free", subscriptionStatus: "active") == .unknown)
        #expect(ClaudeProvider.plan(rateLimitTier: nil, subscriptionStatus: "active").weight == 0)
    }

    @Test func profileResponseReadsTheOrganizationPlan() throws {
        let body = #"{"account":{"email":"x"},"organization":{"rate_limit_tier":"default_claude_max_5x","subscription_status":"active"}}"#
        let profile = try #require(ClaudeProvider().parsePlan(Data(body.utf8)))
        #expect(profile.plan == .paid(weight: 5))
        #expect(profile.tier == "default_claude_max_5x")
    }

    @Test func profileWithoutPlanFieldsIsNotReadAsCancelled() {
        let body = #"{"account":{"email":"x"},"organization":{"uuid":"o"}}"#
        #expect(ClaudeProvider().parsePlan(Data(body.utf8)) == nil)
    }

    @Test func cachedPlansRoundTrip() throws {
        for plan in [Plan.paid(weight: 20), .inactive, .unknown] {
            let data = try JSONEncoder().encode(PlanProfile(plan: plan, tier: "tier"))
            #expect(try JSONDecoder().decode(PlanProfile.self, from: data).plan == plan)
        }
    }

    @Test func profileCheckCadenceDependsOnState() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let hoursAgo = { (hours: Double) in now.addingTimeInterval(-hours * 3600) }
        #expect(ProfilePlan.isDue(lastCheck: nil, plan: nil, isRetired: false, now: now))
        #expect(!ProfilePlan.isDue(lastCheck: hoursAgo(5), plan: .paid(weight: 5), isRetired: false, now: now))
        #expect(ProfilePlan.isDue(lastCheck: hoursAgo(6), plan: .paid(weight: 5), isRetired: false, now: now))
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
        #expect(Retirement.action(isDisabled: true, isRetiredByUs: true, plan: .paid(weight: 20), inactiveStreak: 0) == .reinstate)
    }

    @Test func accountTheUserDisabledIsNeverReinstated() {
        #expect(Retirement.action(isDisabled: true, isRetiredByUs: false, plan: .paid(weight: 5), inactiveStreak: 0) == .keep)
    }

    @Test func activeOrUnknownPlansNeverRetire() {
        #expect(Retirement.action(isDisabled: false, isRetiredByUs: false, plan: .paid(weight: 5), inactiveStreak: 9) == .keep)
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
}
