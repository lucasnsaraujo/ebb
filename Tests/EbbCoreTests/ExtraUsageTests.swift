import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) struct ExtraUsageTests {
    @Test func claudeWithOverageAllowedShowsExtraUsageOn() {
        let signals = ["Anthropic-Ratelimit-Unified-Overage-Status": "allowed"]
        #expect(ClaudeProvider().extraUsage(fromSignals: signals) == .claudeOverage(isNearLimit: false))
        #expect(ClaudeProvider().extraUsage(fromSignals: ["anthropic-ratelimit-unified-overage-status": "allowed_warning"]) == .claudeOverage(isNearLimit: true))
    }

    @Test func claudeWithOverageDisabledShowsNothing() {
        let signals = ["Anthropic-Ratelimit-Unified-Overage-Status": "rejected", "Anthropic-Ratelimit-Unified-Overage-Disabled-Reason": "org_level_disabled"]
        #expect(ClaudeProvider().extraUsage(fromSignals: signals) == nil)
        #expect(ClaudeProvider().extraUsage(fromSignals: [:]) == nil)
    }

    @Test func codexWithCreditsShowsTheBalance() {
        let signals = ["X-Codex-Credits-Has-Credits": "true", "X-Codex-Credits-Unlimited": "false", "X-Codex-Credits-Balance": "12.50"]
        #expect(CodexProvider().extraUsage(fromSignals: signals) == .codexCredits(balance: 12.5))
        #expect(CodexProvider().extraUsage(fromSignals: ["X-Codex-Credits-Unlimited": "true"]) == .codexUnlimitedCredits)
    }

    @Test func codexFlagsReadTheSameInAnyCase() {
        #expect(CodexProvider().extraUsage(fromSignals: ["X-Codex-Credits-Has-Credits": "True", "X-Codex-Credits-Balance": "4"]) == .codexCredits(balance: 4))
        #expect(CodexProvider().extraUsage(fromSignals: ["X-Codex-Credits-Unlimited": "1"]) == .codexUnlimitedCredits)
    }

    @Test func extraUsageFromADayOldResponseIsNotShown() throws {
        let listing = """
        {"files": [{"name": "codex-a.json", "provider": "codex", "quota": {"observed_at": "2026-10-26T19:30:00Z",
            "signals": {"X-Codex-Credits-Unlimited": "true"}}}]}
        """
        let file = try #require(ProxyAuthFile.parseList(Data(listing.utf8))?.first)
        let observed = UsageLimit.parseTimestamp("2026-10-26T19:30:00Z")!
        #expect(file.extraUsage(at: observed + 3600) == .codexUnlimitedCredits)
        #expect(file.extraUsage(at: observed + 25 * 3600) == nil)
    }

    @Test func codexWithoutCreditsOrAZeroBalanceShowsNothing() {
        #expect(CodexProvider().extraUsage(fromSignals: ["X-Codex-Credits-Has-Credits": "false", "X-Codex-Credits-Unlimited": "false", "X-Codex-Credits-Balance": "0"]) == nil)
        #expect(CodexProvider().extraUsage(fromSignals: ["X-Codex-Credits-Has-Credits": "true", "X-Codex-Credits-Balance": "0"]) == nil)
    }

    @Test func eachKindReadsAsOneShortLine() {
        #expect(ExtraUsage.claudeOverage(isNearLimit: false).text == "Extra usage on")
        #expect(ExtraUsage.claudeOverage(isNearLimit: true).text == "Extra usage on, near its limit")
        #expect(ExtraUsage.codexCredits(balance: 12.5).text(locale: Locale(identifier: "en_US")) == "Credits: 12.5")
        #expect(ExtraUsage.codexUnlimitedCredits.text == "Credits: unlimited")
    }

    @Test func theListingCarriesEachLoginsExtraUsage() throws {
        let listing = """
        {"files": [
          {"name": "codex-a.json", "provider": "codex", "quota": {"observed_at": "2026-10-26T19:30:00Z",
            "signals": {"X-Codex-Credits-Has-Credits": "true", "X-Codex-Credits-Balance": "3"}}},
          {"name": "codex-b.json", "provider": "codex", "quota": {"observed_at": "2026-10-26T19:30:00Z",
            "signals": {"X-Codex-Credits-Has-Credits": "false", "X-Codex-Credits-Balance": "0"}}},
          {"name": "kimi.json", "provider": "kimi"}
        ]}
        """
        let files = try #require(ProxyAuthFile.parseList(Data(listing.utf8)))
        #expect(files.map(\.extraUsage) == [.codexCredits(balance: 3), nil, nil])
    }
}
