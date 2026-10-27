import Foundation
import Testing
@testable import EbbCore

@MainActor
@Suite struct DiagnosticsTests {
    private let now = Date(timeIntervalSince1970: 1_793_040_000)
    private let email = "jane.doe@gmail.com"
    private let token = "sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdef"
    private let managementKey = "mgmt-secret-9f8e7d6c"
    private let fileName = "claude-4c515511-jane.doe@gmail.com.json"

    private func report(log: DiagnosticLog) -> DiagnosticsReport {
        DiagnosticsReport(
            ebbVersion: "1.2",
            macOSVersion: "Version 26.1 (Build 25B1)",
            proxyVersion: "8.0.40",
            connection: "local, reachable",
            routingStrategy: "weighted-round-robin",
            accounts: [
                DiagnosticAccount(provider: "claude", name: "zed@example.com", status: "stale", readAt: now - 14 * 60, outcome: .rateLimited),
                DiagnosticAccount(provider: "claude", name: email, status: "active", readAt: now - 90, outcome: .ok),
                DiagnosticAccount(provider: "codex", name: fileName, status: "limits unavailable", readAt: nil, outcome: .tokenRefused),
            ],
            log: log.entries,
            secrets: [managementKey]
        )
    }

    @Test func nothingPrivateSurvivesIntoTheReport() {
        let log = DiagnosticLog()
        log.record("usage for \(fileName) with Bearer \(token)", at: now - 30)
        log.record("key \(managementKey) refused for \(email)", at: now - 10)
        let text = Diagnostics.text(report(log: log), now: now)
        for secret in [email, "jane.doe", token, "sk-ant", managementKey, fileName, "4c515511", "zed@example.com", ".json"] {
            #expect(!text.contains(secret), Comment(rawValue: secret))
        }
        #expect(text.contains("claude#1"))
        #expect(text.contains("codex#1"))
    }

    @Test func accountsAreNumberedPerProviderInNameOrder() {
        let text = Diagnostics.text(report(log: DiagnosticLog()), now: now)
        #expect(text.contains("claude#1  active"))
        #expect(text.contains("claude#2  stale"))
        #expect(!text.contains("claude#3"))
        let accounts = report(log: DiagnosticLog()).accounts
        #expect(Diagnostics.label(provider: "claude", name: "zed@example.com", among: accounts) == "claude#2")
        #expect(Diagnostics.label(provider: "codex", name: fileName, among: accounts) == "codex#1")
    }

    @Test func reportNamesVersionsRoutingCountsAgesAndOutcomes() {
        let text = Diagnostics.text(report(log: DiagnosticLog()), now: now)
        #expect(text.contains("Ebb 1.2"))
        #expect(text.contains("macOS Version 26.1 (Build 25B1)"))
        #expect(text.contains("CLIProxyAPI 8.0.40"))
        #expect(text.contains("Routing: weighted-round-robin"))
        #expect(text.contains("Providers: claude 2, codex 1"))
        #expect(text.contains("claude#2  stale  read 14m ago  rate limited"))
        #expect(text.contains("codex#1  limits unavailable  never read  token refused"))
    }

    @Test func reportGivesEachPoolsWindowsAndWhatIsLocked() {
        var report = report(log: DiagnosticLog())
        let locked = WindowSummary(freePercent: 23.6, resets: [], lockedPercent: 57.1, unlocksAt: now + 26 * 3600 + 20 * 60)
        report.pools = [
            "codex": PoolSummary(session: WindowSummary(freePercent: 80, resets: []), weekly: WindowSummary(freePercent: 90, resets: []), isPartial: false),
            "claude": PoolSummary(session: locked, weekly: WindowSummary(freePercent: 41.4, resets: []), isPartial: false),
        ]
        let text = Diagnostics.text(report, now: now)
        #expect(text.contains("Pool claude: 5h 24% left, 57% locked, unlocks in 26h; weekly 41% left\nPool codex: 5h 80% left; weekly 90% left"))
    }

    @Test func logKeepsOnlyTheLastTwentyLines() {
        let log = DiagnosticLog()
        for index in 1...25 { log.record("event \(index)", at: now + Double(index)) }
        #expect(log.entries.count == 20)
        #expect(log.entries.first?.message == "event 6")
        #expect(log.entries.last?.message == "event 25")
    }

    @Test func scrubbingLeavesOrdinaryWordsAlone() {
        let line = "Proxy poll failed; claude#2 usage: rate limited (retry in 2m)"
        #expect(Redaction.scrub(line) == line)
        #expect(Redaction.scrub("token \(token) for \(email)") == "token ‹token› for ‹email›")
        #expect(Redaction.scrub("Key check: valid; version 8.0.40; brew exited with status 1") == "Key check: valid; version 8.0.40; brew exited with status 1")
    }

    @Test func scrubbingCatchesWhatLogLinesAndBrewOutputCanCarry() {
        let cases: [(String, String)] = [
            ("for jane.doe+ebb@gmail.com", "for ‹email›"),
            ("mailto:jane.doe%40gmail.com", "mailto:‹email›"),
            (#"{"access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJqYW5lIn0.c2lnbmF0dXJl","expires_in":3600}"#, #"{"access_token":"‹redacted›","expires_in":3600}"#),
            (#"{"refresh_token": "abc", "api_key": "k"}"#, #"{"refresh_token": "‹redacted›", "api_key": "‹redacted›"}"#),
            ("GET https://proxy.example.com/v0/management/auth-files?key=mgmt-secret&token=abc123&page=2", "GET https://proxy.example.com/v0/management/auth-files?key=‹redacted›&token=‹redacted›&page=2"),
            ("login 00000000-0000-4000-8000-000000000001 refused", "login ‹id› refused"),
            ("key 0123456789abcdef0123456789abcdef", "key ‹key›"),
            ("Error: /Users/janedoe/Library/Logs/Homebrew/cliproxyapi/stderr.log", "Error: /Users/‹user›/Library/Logs/Homebrew/cliproxyapi/stderr.log"),
            ("see /home/janedoe/.cli-proxy-api", "see /home/‹user›/.cli-proxy-api"),
        ]
        for (input, expected) in cases {
            #expect(Redaction.scrub(input) == expected, Comment(rawValue: input))
        }
    }
}
