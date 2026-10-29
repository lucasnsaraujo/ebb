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

@Suite(.hangLimit) struct CodexSignalTests {
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

    @Test func unreadableWindowsAreNoReadingRatherThanAFreeAccount() throws {
        for windows in [#""primary_window":null,"secondary_window":null"#, #""primary":{"used_pct":97,"window_secs":18000}"#] {
            let body = #"{"plan_type":"pro","rate_limit":{"allowed":true,"#.appending(windows) + "}}"
            let reading = try #require(CodexProvider().readUsageCall(Data(body.utf8)))
            #expect(reading.limits == nil)
            #expect(reading.planName == "pro")
        }
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

@Suite(.hangLimit) struct DevinSignalTests {
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

@Suite(.hangLimit) struct AntigravityTests {
    @Test func eachWindowTakesItsTightestModelGroup() throws {
        let reading = try #require(AntigravityProvider().readUsageCall(fixtureData("antigravity-quota-summary")))
        let limits = try #require(reading.limits)
        #expect(limits.map(\.kind) == [.session, .weeklyAll])
        #expect(abs(limits[0].usedPercent - 70) < 0.001)
        #expect(limits[0].resetsAt == UsageLimit.parseTimestamp("2026-10-26T21:00:00Z"))
        #expect(abs(limits[1].usedPercent - 40) < 0.001)
        #expect(limits[1].resetsAt == UsageLimit.parseTimestamp("2026-10-30T00:00:00Z"))
    }

    /// Google's JSON leaves out fields at zero, so a spent bucket arrives with its reset but no fraction.
    @Test func aSpentBucketWithoutItsFractionReadsAsFullyUsed() throws {
        let body = #"""
        {"groups":[
          {"buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.8,"resetTime":"2026-10-26T22:00:00Z"}]},
          {"buckets":[{"bucketId":"claude-gpt-5h","window":"5h","resetTime":"2026-10-26T21:00:00Z"}]}
        ]}
        """#
        let limits = try #require(AntigravityProvider().readUsageCall(Data(body.utf8))?.limits)
        #expect(limits == [UsageLimit(kind: .session, usedPercent: 100, resetsAt: UsageLimit.parseTimestamp("2026-10-26T21:00:00Z"))])
    }

    @Test func summaryWithoutMeasuredBucketsHasNoLimits() throws {
        let body = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","window":"5h"}]}]}"#
        #expect(AntigravityProvider().readUsageCall(Data(body.utf8))?.limits == nil)
    }
}

@Suite(.hangLimit) struct KimiTests {
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

@Suite(.hangLimit) struct MetaTests {
    @Test func subscriptionUsageGivesBothWindows() throws {
        let reading = try #require(MetaProvider().readUsageCall(fixtureData("meta-muse-key")))
        #expect(reading.limits == [
            UsageLimit(kind: .session, usedPercent: 96, resetsAt: Date(timeIntervalSince1970: 1_793_056_000)),
            UsageLimit(kind: .weeklyAll, usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_793_400_000)),
        ])
        #expect(reading.planName == "Muse Code Power Usage")
        #expect(!reading.hasEndedSubscription)
    }

    /// The proxy sends Meta the minted key, not the login token, so an inactive answer may describe the key.
    @Test func inactiveAnswerNeverRetiresTheLogin() throws {
        let reading = try #require(MetaProvider().readUsageCall(Data(#"{"is_subs_active":false,"subs_usage":null}"#.utf8)))
        #expect(!reading.hasEndedSubscription)
        #expect(Retirement.action(after: .reading(reading), isDisabled: false, isRetiredByUs: false, inactiveStreak: 9) == .keep)
    }

    @Test func idleWindowIsNoReadingRatherThanAnEmptyAccount() throws {
        let body = #"{"is_subs_active":true,"subs_tier_name":"Muse Code Power Usage"}"#
        let reading = try #require(MetaProvider().readUsageCall(Data(body.utf8)))
        #expect(reading.limits == nil)
    }
}

@Suite(.hangLimit) struct MixedListingTests {
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

@Suite(.hangLimit) struct APICallTests {
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

@Suite(.hangLimit) struct CallOutcomeTests {
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

@Suite(.hangLimit) struct ProviderPoolTests {
    private let now = Date(timeIntervalSince1970: 1_793_040_000)

    private func member(weight: Double, sessionUsed: Double, weeklyUsed: Double? = nil, resetIn hours: Double = 1) -> PoolMember {
        let limits = [UsageLimit(kind: .session, usedPercent: sessionUsed, resetsAt: now + hours * 3600)]
            + (weeklyUsed.map { [UsageLimit(kind: .weeklyAll, usedPercent: $0, resetsAt: now + 3 * 86400)] } ?? [])
        return PoolMember(plan: .paid(weight: PlanWeight(weight)), signals: DatedLimits(limits: limits, date: now), usage: nil)
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

@Suite(.hangLimit) struct PlanWeightTests {
    @Test func defaultsComeFromTheTable() {
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "plus") == PlanWeight(1))
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "pro") == PlanWeight(20))
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "business") == PlanWeight(1))
        #expect(PlanWeights.defaultWeight(provider: "kimi", plan: "level_intermediate") == PlanWeight(7))
    }

    /// Anthropic's per-session multipliers for the 5-hour window; the measured ratios for the week,
    /// where Max 20x holds about twice Max 5x, not four times.
    @Test func claudePlansWeighLessAWeekThanTheirSessionMultiplier() {
        #expect(PlanWeights.defaultWeight(provider: "claude", plan: "pro") == PlanWeight(session: 1, weekly: 1))
        #expect(PlanWeights.defaultWeight(provider: "claude", plan: "max_5x") == PlanWeight(session: 5, weekly: 3.5))
        #expect(PlanWeights.defaultWeight(provider: "claude", plan: "max_20x") == PlanWeight(session: 20, weekly: 7))
    }

    @Test func unlistedPlansFallBackOrStayUnknown() {
        #expect(PlanWeights.defaultWeight(provider: "claude", plan: "team_5x") == PlanWeight(session: 5, weekly: 3.5))
        #expect(PlanWeights.defaultWeight(provider: "devin", plan: "anything") == PlanWeight(1))
        #expect(PlanWeights.defaultWeight(provider: "antigravity", plan: nil) == PlanWeight(1))
        #expect(PlanWeights.defaultWeight(provider: "kimi", plan: "level_new") == PlanWeight(1))
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: "sci") == nil)
        #expect(PlanWeights.defaultWeight(provider: "codex", plan: nil) == nil)
    }

    @Test func overridesWinPerPlanRow() {
        func fiveHour(_ provider: String, _ plan: String) -> String {
            PlanWeights.overrideKey(provider: provider, plan: plan, window: .session)
        }
        let overrides = [fiveHour("codex", "pro"): 15.0, fiveHour("claude", "max_5x"): 4, fiveHour("devin", "*"): 3, fiveHour("codex", "plus"): 0]
        #expect(PlanWeights.weight(provider: "codex", plan: "pro", overrides: overrides) == PlanWeight(session: 15, weekly: 20))
        #expect(PlanWeights.weight(provider: "codex", plan: "PRO", overrides: overrides) == PlanWeight(session: 15, weekly: 20))
        #expect(PlanWeights.weight(provider: "codex", plan: "plus", overrides: overrides) == PlanWeight(1))
        #expect(PlanWeights.weight(provider: "claude", plan: "max_5x", overrides: overrides) == PlanWeight(session: 4, weekly: 3.5))
        #expect(PlanWeights.weight(provider: "claude", plan: "max_20x", overrides: overrides) == PlanWeight(session: 20, weekly: 7))
        #expect(PlanWeights.weight(provider: "devin", plan: "team", overrides: overrides) == PlanWeight(session: 3, weekly: 1))
    }

    @Test func eachWindowHasItsOwnOverride() {
        let overrides = [
            PlanWeights.overrideKey(provider: "claude", plan: "max_20x", window: .weekly): 8.0,
            PlanWeights.overrideKey(provider: "claude", plan: "max_5x", window: .session): 6,
            PlanWeights.overrideKey(provider: "claude", plan: "max_5x", window: .weekly): 4,
            PlanWeights.overrideKey(provider: "claude", plan: "pro", window: .weekly): 0,
        ]
        #expect(PlanWeights.weight(provider: "claude", plan: "max_20x", overrides: overrides) == PlanWeight(session: 20, weekly: 8))
        #expect(PlanWeights.weight(provider: "claude", plan: "max_5x", overrides: overrides) == PlanWeight(session: 6, weekly: 4))
        #expect(PlanWeights.weight(provider: "claude", plan: "pro", overrides: overrides) == PlanWeight(1))
    }

    /// Settings saved one weight per plan, under "provider/plan", before plans had a weekly size.
    /// Where a provider's plans weigh the same in both windows it sized both, and still does, so
    /// routing and the weekly pool don't move. Claude's weeks are measured apart: there it was
    /// meant for sessions, so it sizes the 5-hour window and the week keeps its default.
    @Test func aWeightSavedBeforePlansHadAWeeklySizeKeepsWhatItSized() {
        let saved = PlanWeights.splittingLegacyOverrides(["claude/max_20x": 10.0, "claude/pro": 2, "codex/pro": 30, "devin/*": 3])
        #expect(PlanWeights.weight(provider: "claude", plan: "max_20x", overrides: saved) == PlanWeight(session: 10, weekly: 7))
        #expect(PlanWeights.weight(provider: "claude", plan: "pro", overrides: saved) == PlanWeight(session: 2, weekly: 1))
        #expect(PlanWeights.weight(provider: "codex", plan: "pro", overrides: saved) == PlanWeight(30))
        #expect(PlanWeights.weight(provider: "devin", plan: "team", overrides: saved) == PlanWeight(3))
    }

    /// Once split, a 5-hour edit is the 5-hour window's alone, and a window's own override wins.
    @Test func aSplitWeightNeverComesBackOverAWindowsOwnOverride() {
        let weeklyKey = PlanWeights.overrideKey(provider: "codex", plan: "pro", window: .weekly)
        let saved = PlanWeights.splittingLegacyOverrides(["codex/pro": 30, weeklyKey: 25])
        #expect(PlanWeights.weight(provider: "codex", plan: "pro", overrides: saved) == PlanWeight(session: 30, weekly: 25))
        #expect(saved["codex/pro"] == nil)

        let edited = [PlanWeights.overrideKey(provider: "codex", plan: "pro", window: .session): 30.0]
        #expect(PlanWeights.weight(provider: "codex", plan: "pro", overrides: PlanWeights.splittingLegacyOverrides(edited)) == PlanWeight(session: 30, weekly: 20))
    }

    @Test func everyDefaultCitesItsSource() {
        for (provider, rows) in PlanWeights.defaults {
            #expect(Providers.named(provider) != nil)
            for row in rows {
                #expect(!row.source.isEmpty && row.weight.isPositive, "\(provider)/\(row.plan)")
                #expect(row.isGuess == (row.source.hasPrefix("Guess") || row.source.hasPrefix("Estimate")), "\(provider)/\(row.plan)")
            }
        }
        #expect(ClaudeProvider.planName(rateLimitTier: "default_claude_max_20x") == "max_20x")
    }
}

@Suite(.hangLimit) struct ClaudeThroughTheProxyTests {
    private let profile = #"{"organization":{"rate_limit_tier":"default_claude_max_20x","subscription_status":"active"}}"#

    private func claudeLogin() throws -> ProxyAuthFile {
        var login = try #require(ProxyAuthFile.parseList(fixtureData("proxy-auth-files")))[0]
        login.authIndex = "claude-0001"
        return login
    }

    @Test func claudeIsCalledThroughTheProxyOnlyWhenTheProxyIsRemote() throws {
        let claude = try claudeLogin()
        #expect(claude.isReadThroughProxy(isRemote: true))
        #expect(!claude.isReadThroughProxy(isRemote: false))
        let codex = try login("codex-plus@example.com.json")
        #expect(codex.isReadThroughProxy(isRemote: false))
    }

    @Test func usageAndProfileCallsCarryClaudesOAuthHeadersAndLeaveTheTokenToTheProxy() throws {
        let claude = try claudeLogin()
        let usage = try #require(ClaudeProvider().usageCall(for: claude))
        let plan = try #require(ClaudeProvider().planCall(for: claude))
        #expect(usage.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(plan.url.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        for call in [usage, plan] {
            #expect(call.method == "GET")
            #expect(call.authIndex == "claude-0001")
            #expect(call.header["Authorization"] == ProxyAPICall.bearer)
            #expect(call.header["anthropic-beta"] == "oauth-2025-04-20")
            #expect(call.header.values.filter { $0.contains(ProxyAPICall.tokenPlaceholder) }.count == 1)
        }
        var withoutIndex = claude
        withoutIndex.authIndex = nil
        #expect(ClaudeProvider().usageCall(for: withoutIndex) == nil)
        #expect(ClaudeProvider().planCall(for: withoutIndex) == nil)
    }

    @Test func theUsageAnswerThroughTheProxyReadsLikeTheDirectOne() throws {
        let body = try fixtureData("team-session-18")
        let reading = try #require(ClaudeProvider().readUsageCall(Data("{\"limits\":\(String(decoding: body, as: UTF8.self))}".utf8)))
        #expect(reading.limits?.first == UsageLimit(kind: .session, usedPercent: 18, resetsAt: UsageLimit.parseTimestamp("2026-10-26T20:10:00.831009+00:00")))
        #expect(reading.planName == nil)
        #expect(ClaudeProvider().readUsageCall(Data("{}".utf8)) == nil)
    }

    @Test func theProfileAnswerGivesThePlanAndWhetherItEnded() throws {
        let active = try #require(ClaudeProvider().readPlanCall(Data(profile.utf8)))
        #expect(active == UsageCallReading(limits: nil, planName: "max_20x", hasEndedSubscription: false))
        let ended = #"{"organization":{"rate_limit_tier":"default_claude_max_20x","subscription_status":"canceled"}}"#
        #expect(ClaudeProvider().readPlanCall(Data(ended.utf8))?.hasEndedSubscription == true)
        #expect(ClaudeProvider().readPlanCall(Data(#"{"organization":{}}"#.utf8)) == nil)
    }

    @Test func aProfileThroughTheProxyIsReadWithThePlanParser() throws {
        let wrapped = try JSONSerialization.data(withJSONObject: ["status_code": 200, "header": [:], "body": profile])
        let outcome = CallOutcome.read(proxyStatus: 200, body: wrapped, now: .now, parse: ClaudeProvider().readPlanCall)
        #expect(outcome == .reading(UsageCallReading(limits: nil, planName: "max_20x")))
        let refused = try JSONSerialization.data(withJSONObject: ["status_code": 401, "header": [:], "body": ""])
        #expect(CallOutcome.read(proxyStatus: 200, body: refused, now: .now, parse: ClaudeProvider().readPlanCall) == .tokenRejected)
    }
}
