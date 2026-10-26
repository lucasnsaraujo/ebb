import Foundation
import Testing
@testable import EbbCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func mixedListing() throws -> [ProxyAuthFile] {
    try #require(ProxyAuthFile.parseList(fixtureData("proxy-auth-files-mixed")))
}

private func login(_ name: String) throws -> ProxyAuthFile {
    try #require(try mixedListing().first { $0.name == name })
}

private let observed = Date(timeIntervalSince1970: 1_793_040_000)

@Suite struct CodexSignalTests {
    @Test func primaryAndSecondaryWindowsBecomeSessionAndWeekly() throws {
        let codex = try login("codex-plus@example.com.json")
        #expect(codex.quota?.limits == [
            UsageLimit(kind: .session, usedPercent: 25, resetsAt: Date(timeIntervalSince1970: 1_793_056_000)),
            UsageLimit(kind: .weeklyAll, usedPercent: 60, resetsAt: Date(timeIntervalSince1970: 1_793_400_000)),
        ])
        #expect(codex.planName == "plus")
        #expect(codex.accountID == "00000000-0000-4000-8000-000000000001")
    }

    @Test func aWeeklyOnlyPrimaryWindowFillsTheWeeklySlot() {
        // CPA's own test: plans without a 5-hour cap send the weekly window as primary.
        let limits = CodexProvider().limits(fromSignals: [
            "X-Codex-Primary-Used-Percent": "48",
            "X-Codex-Primary-Window-Minutes": "10080",
            "X-Codex-Primary-Reset-After-Seconds": "523210",
        ], observedAt: observed)
        #expect(limits == [UsageLimit(kind: .weeklyAll, usedPercent: 48, resetsAt: observed + 523_210)])
    }

    @Test func reachedLimitReadsAsFullyUsed() {
        let limits = CodexProvider().limits(fromSignals: [
            "X-Codex-Limit-Reached": "true",
            "X-Codex-Primary-Used-Percent": "97",
            "X-Codex-Primary-Window-Minutes": "300",
            "X-Codex-Primary-Reset-At": "1793056000",
            "X-Codex-Secondary-Used-Percent": "40",
            "X-Codex-Secondary-Window-Minutes": "10080",
            "X-Codex-Secondary-Reset-At": "1793400000",
        ], observedAt: observed)
        #expect(limits?.map(\.usedPercent) == [100, 40])
    }

    @Test func modelSpecificLimitsAloneAreNotAReading() {
        let limits = CodexProvider().limits(fromSignals: [
            "X-Codex-Bengalfox-Primary-Used-Percent": "90",
            "X-Codex-Bengalfox-Primary-Window-Minutes": "300",
        ], observedAt: observed)
        #expect(limits == nil)
    }

    @Test func planFallsBackToTheIDTokenClaim() throws {
        let codex = try login("codex-pro@example.com.json")
        #expect(codex.planName == "pro")
        #expect(codex.quota == nil)
    }

    @Test func whamUsageGivesWindowsAndPlan() throws {
        let reading = try #require(CodexProvider().readUsageCall(fixtureData("codex-wham-usage")))
        #expect(reading.planName == "pro")
        #expect(reading.limits == [
            UsageLimit(kind: .session, usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_793_056_000)),
            UsageLimit(kind: .weeklyAll, usedPercent: 34, resetsAt: Date(timeIntervalSince1970: 1_793_400_000)),
        ])
        #expect(!reading.hasEndedSubscription)
    }
}

@Suite struct DevinSignalTests {
    @Test func remainingPercentsBecomeDailyAndWeeklyUsage() throws {
        let devin = try login("devin-dev@example.com.json")
        #expect(devin.quota?.limits == [
            UsageLimit(kind: .session, usedPercent: 27, resetsAt: UsageLimit.parseTimestamp("2026-10-27T00:00:00Z")),
            UsageLimit(kind: .weeklyAll, usedPercent: 60, resetsAt: UsageLimit.parseTimestamp("2026-11-02T00:00:00Z")),
        ])
        #expect(devin.planName == "pro")
        #expect(DevinProvider().shortWindow == .day)
    }
}

@Suite struct AntigravityTests {
    @Test func eachWindowTakesItsTightestModelGroup() throws {
        let reading = try #require(AntigravityProvider().readUsageCall(fixtureData("antigravity-quota-summary")))
        let limits = try #require(reading.limits)
        #expect(limits.map(\.kind) == [.session, .weeklyAll])
        #expect(abs(limits[0].usedPercent - 70) < 0.001)
        #expect(limits[0].resetsAt == UsageLimit.parseTimestamp("2026-10-26T21:00:00Z"))
        #expect(abs(limits[1].usedPercent - 40) < 0.001)
        #expect(limits[1].resetsAt == UsageLimit.parseTimestamp("2026-10-30T00:00:00Z"))
    }

    @Test func summaryWithoutMeasuredBucketsHasNoLimits() throws {
        let body = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","window":"5h"}]}]}"#
        #expect(AntigravityProvider().readUsageCall(Data(body.utf8))?.limits == nil)
    }
}

@Suite struct KimiTests {
    @Test func usagesGiveTheFiveHourWindowWeeklyQuotaAndMembership() throws {
        let reading = try #require(KimiProvider().readUsageCall(fixtureData("kimi-usages")))
        let limits = try #require(reading.limits)
        #expect(limits.map(\.kind) == [.session, .weeklyAll])
        #expect(limits.map(\.usedPercent) == [75, 25])
        #expect(limits[0].resetsAt == UsageLimit.parseTimestamp("2026-10-26T21:33:02.717Z"))
        #expect(reading.planName == "level_basic")
    }

    @Test func internationalLoginsAreReadOnTheirOwnHost() throws {
        let kimi = try login("kimi-moon@example.com.json")
        #expect(kimi.provider == "kimi")
        #expect(KimiProvider().usageCall(for: kimi)?.url.host() == "api.kimi.ai")
        var china = kimi
        china.proxyProvider = "kimi"
        #expect(KimiProvider().usageCall(for: china)?.url.host() == "api.kimi.com")
    }
}

@Suite struct MetaTests {
    @Test func subscriptionUsageGivesBothWindows() throws {
        let reading = try #require(MetaProvider().readUsageCall(fixtureData("meta-muse-key")))
        #expect(reading.limits == [
            UsageLimit(kind: .session, usedPercent: 96, resetsAt: Date(timeIntervalSince1970: 1_793_056_000)),
            UsageLimit(kind: .weeklyAll, usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_793_400_000)),
        ])
        #expect(reading.planName == "Muse Code Power Usage")
        #expect(!reading.hasEndedSubscription)
    }

    @Test func inactiveSubscriptionIsDefinitive() throws {
        let reading = try #require(MetaProvider().readUsageCall(Data(#"{"is_subs_active":false,"subs_usage":null}"#.utf8)))
        #expect(reading.hasEndedSubscription)
        #expect(CallOutcome.reading(reading).subscriptionEvidence == .inactive)
    }

    @Test func idleWindowIsNoReadingRatherThanAnEmptyAccount() throws {
        let body = #"{"is_subs_active":true,"subs_tier_name":"Muse Code Power Usage"}"#
        let reading = try #require(MetaProvider().readUsageCall(Data(body.utf8)))
        #expect(reading.limits == nil)
    }
}

@Suite struct MixedListingTests {
    @Test func everyProviderIsListedWithItsHealth() throws {
        let files = try mixedListing()
        #expect(files.map(\.provider) == ["claude", "codex", "codex", "devin", "antigravity", "kimi", "meta", "xai", "gemini"])
        let xai = try login("xai-grok@example.com.json")
        #expect(!xai.hasUsageWindows)
        #expect(xai.health.state == .coolingDown(until: UsageLimit.parseTimestamp("2026-10-26T20:30:00Z")))
        #expect(xai.health.message == "quota exhausted")
        #expect(xai.quota == nil)
        let gemini = try login("gemini-key-0000")
        #expect(gemini.displayName == "Gemini key")
        #expect(gemini.health == AccountHealth(state: .ok, successes: 9))
        #expect(try login("codex-plus@example.com.json").hasUsageWindows)
    }
}

@Suite struct APICallTests {
    private let calling = ["codex-plus@example.com.json", "antigravity-agy@example.com.json", "kimi-moon@example.com.json", "meta-muse@example.com.json"]

    @Test func callsNameTheLoginAndLeaveTheTokenToTheProxy() throws {
        for name in calling {
            let file = try login(name)
            let provider = try #require(Providers.named(file.provider))
            let call = try #require(provider.usageCall(for: file))
            let body = try #require(try JSONSerialization.jsonObject(with: call.body()) as? [String: Any])
            #expect(body["auth_index"] as? String == file.authIndex, "\(name)")
            let header = try #require(body["header"] as? [String: String])
            #expect(header["Authorization"] == "Bearer $TOKEN$", "\(name)")
            #expect(header.values.filter { $0.contains("$TOKEN$") }.count == 1, "\(name)")
            #expect(body["url"] as? String == call.url.absoluteString)
        }
    }

    @Test func codexSendsItsAccountAndAntigravityItsProject() throws {
        let codex = try #require(CodexProvider().usageCall(for: login("codex-plus@example.com.json")))
        #expect(codex.method == "GET")
        #expect(codex.header["ChatGPT-Account-Id"] == "00000000-0000-4000-8000-000000000001")
        let antigravity = try #require(AntigravityProvider().usageCall(for: login("antigravity-agy@example.com.json")))
        #expect(antigravity.method == "POST")
        #expect(antigravity.data == #"{"project":"example-project-000"}"#)
    }

    @Test func noCallWithoutAnAuthIndex() throws {
        var codex = try login("codex-plus@example.com.json")
        codex.authIndex = nil
        #expect(CodexProvider().usageCall(for: codex) == nil)
    }

    @Test func signalOnlyProvidersMakeNoCalls() throws {
        #expect(DevinProvider().usageCall(for: try login("devin-dev@example.com.json")) == nil)
    }
}

@Suite struct CallOutcomeTests {
    private let now = Date(timeIntervalSince1970: 1_793_040_000)

    private func wrapped(_ status: Int, body: String = "", header: [String: [String]] = [:]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["status_code": status, "header": header, "body": body])
    }

    @Test func refusedTokensReadAsLimitsNotAvailable() {
        #expect(CallOutcome.read(proxyStatus: 200, body: wrapped(401), provider: CodexProvider(), now: now) == .tokenRejected)
        #expect(CallOutcome.read(proxyStatus: 200, body: wrapped(403), provider: MetaProvider(), now: now) == .tokenRejected)
        let missing = Data(#"{"error":"auth token not found"}"#.utf8)
        #expect(CallOutcome.read(proxyStatus: 400, body: missing, provider: KimiProvider(), now: now) == .tokenRejected)
    }

    @Test func rateLimitCarriesRetryAfter() {
        let outcome = CallOutcome.read(proxyStatus: 200, body: wrapped(429, header: ["Retry-After": ["120"]]), provider: CodexProvider(), now: now)
        #expect(outcome == .rateLimited(retryAfter: 120))
    }

    @Test func successfulCallIsParsedByItsProvider() throws {
        let body = try String(data: fixtureData("codex-wham-usage"), encoding: .utf8) ?? ""
        guard case let .reading(reading) = CallOutcome.read(proxyStatus: 200, body: wrapped(200, body: body), provider: CodexProvider(), now: now) else {
            Issue.record("expected a reading")
            return
        }
        #expect(reading.planName == "pro")
    }

    @Test func unreadableBodiesAndProxyErrorsAreFailures() {
        #expect(CallOutcome.read(proxyStatus: 200, body: wrapped(200, body: "<html>"), provider: CodexProvider(), now: now) == .failed)
        #expect(CallOutcome.read(proxyStatus: 502, body: Data(#"{"error":"request failed"}"#.utf8), provider: CodexProvider(), now: now) == .failed)
    }

    @Test func aRefusedTokenNeverRetiresAnAccount() {
        for outcome in [CallOutcome.tokenRejected, .rateLimited(retryAfter: nil), .failed] {
            #expect(outcome.subscriptionEvidence == nil)
            #expect(Retirement.action(after: outcome, isDisabled: false, isRetiredByUs: false, inactiveStreak: 9) == .keep)
        }
        let ended = CallOutcome.reading(UsageCallReading(limits: nil, planName: nil, hasEndedSubscription: true))
        #expect(Retirement.action(after: ended, isDisabled: false, isRetiredByUs: false, inactiveStreak: 2) == .retire)
    }
}

@Suite struct ProviderPoolTests {
    private let now = Date(timeIntervalSince1970: 1_793_040_000)

    private func member(weight: Double, sessionUsed: Double, weeklyUsed: Double? = nil, resetIn hours: Double = 1) -> PoolMember {
        let limits = [UsageLimit(kind: .session, usedPercent: sessionUsed, resetsAt: now + hours * 3600)]
            + (weeklyUsed.map { [UsageLimit(kind: .weeklyAll, usedPercent: $0, resetsAt: now + 3 * 86400)] } ?? [])
        return PoolMember(plan: .paid(weight: weight), signals: DatedLimits(limits: limits, date: now), usage: nil)
    }

    @Test func providersAreNeverBlended() throws {
        let summaries = ProviderPools.summarize([
            ProviderLogin(provider: "claude", member: member(weight: 20, sessionUsed: 90, weeklyUsed: 50)),
            ProviderLogin(provider: "codex", member: member(weight: 1, sessionUsed: 0, weeklyUsed: 10)),
            ProviderLogin(provider: "codex", member: member(weight: 1, sessionUsed: 50)),
        ], at: now)
        #expect(Set(summaries.keys) == ["claude", "codex"])
        #expect(abs(try #require(summaries["claude"]).session.freePercent - 10) < 0.001)
        #expect(abs(try #require(summaries["codex"]).session.freePercent - 75) < 0.001)
        #expect(abs(try #require(summaries["codex"]).weekly.freePercent - 95) < 0.001)
    }

    @Test func healthOnlyLoginsNeverChangeAPool() {
        let pooled = [ProviderLogin(provider: "claude", member: member(weight: 5, sessionUsed: 40))]
        let withHealthOnly = pooled + [
            ProviderLogin(provider: "xai", member: nil),
            ProviderLogin(provider: "gemini", member: member(weight: 100, sessionUsed: 100)),
            ProviderLogin(provider: "claude", member: nil),
        ]
        #expect(ProviderPools.summarize(withHealthOnly, at: now) == ProviderPools.summarize(pooled, at: now))
        #expect(ProviderPools.pooledWeight(withHealthOnly) == ["claude": 5])
    }

    @Test func devinsDailyResetsCountTowardItsShortWindow() throws {
        let summaries = ProviderPools.summarize([ProviderLogin(provider: "devin", member: member(weight: 1, sessionUsed: 30, resetIn: 20))], at: now)
        #expect(try #require(summaries["devin"]).session.resets.map(\.gain) == [30])
        let claude = ProviderPools.summarize([ProviderLogin(provider: "claude", member: member(weight: 1, sessionUsed: 30, resetIn: 20))], at: now)
        #expect(try #require(claude["claude"]).session.resets.isEmpty)
    }

    @Test func menuBarDefaultsToTheProviderWithTheMostPooledWeight() {
        #expect(ProviderPools.defaultProvider(["claude": 25, "codex": 40]) == "codex")
        #expect(ProviderPools.defaultProvider(["codex": 5, "claude": 5]) == "claude")
        #expect(ProviderPools.defaultProvider([:]) == nil)
    }
}

@Suite struct PlanWeightTests {
    @Test func defaultsComeFromTheTable() {
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "plus") == 1)
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "pro") == 20)
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "business") == 1)
        #expect(PlanWeights.defaultWeight(provider: "claude", plan: "max_20x") == 20)
        #expect(PlanWeights.defaultWeight(provider: "kimi", plan: "level_intermediate") == 7)
    }

    @Test func unlistedPlansFallBackOrStayUnknown() {
        #expect(PlanWeights.defaultWeight(provider: "claude", plan: "team_5x") == 5)
        #expect(PlanWeights.defaultWeight(provider: "devin", plan: "anything") == 1)
        #expect(PlanWeights.defaultWeight(provider: "antigravity", plan: nil) == 1)
        #expect(PlanWeights.defaultWeight(provider: "kimi", plan: "level_new") == 1)
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "sci") == nil)
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: nil) == nil)
    }

    @Test func overridesWinPerPlanRow() {
        let overrides = ["codex/pro": 15.0, "claude/max_5x": 4, "devin/*": 3, "codex/plus": 0]
        #expect(PlanWeights.weight(provider: "codex", plan: "pro", overrides: overrides) == 15)
        #expect(PlanWeights.weight(provider: "codex", plan: "PRO", overrides: overrides) == 15)
        #expect(PlanWeights.weight(provider: "codex", plan: "plus", overrides: overrides) == 1)
        #expect(PlanWeights.weight(provider: "claude", plan: "max_5x", overrides: overrides) == 4)
        #expect(PlanWeights.weight(provider: "claude", plan: "max_20x", overrides: overrides) == 20)
        #expect(PlanWeights.weight(provider: "devin", plan: "team", overrides: overrides) == 3)
    }

    @Test func everyDefaultCitesItsSource() {
        for (provider, rows) in PlanWeights.defaults {
            #expect(Providers.named(provider) != nil)
            for row in rows {
                #expect(!row.source.isEmpty && row.weight > 0, "\(provider)/\(row.plan)")
                #expect(row.isGuess == (row.source.hasPrefix("Guess") || row.source.hasPrefix("Estimate")), "\(provider)/\(row.plan)")
            }
        }
        #expect(ClaudeProvider.planName(rateLimitTier: "default_claude_max_20x") == "max_20x")
    }
}
