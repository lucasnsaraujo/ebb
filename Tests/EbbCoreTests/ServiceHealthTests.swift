import Foundation
import Testing
@testable import EbbCore

private func summary(_ components: [(String, String)]) -> Data {
    let items = components.map { #"{"id": "x", "name": "\#($0.0)", "status": "\#($0.1)"}"# }.joined(separator: ",")
    return Data(#"{"page": {"url": "https://status.claude.com"}, "status": {"indicator": "minor", "description": "Partially Degraded Service"}, "components": [\#(items)]}"#.utf8)
}

@Suite(.hangLimit) struct ServiceHealthTests {
    private let claude = StatusPage.forProvider("claude")!
    private let codex = StatusPage.forProvider("codex")!

    @Test func onlyThePoolsOwnComponentsCount() {
        let data = summary([("claude.ai", "major_outage"), ("Claude API (api.anthropic.com)", "operational"), ("Claude Code", "degraded_performance")])
        #expect(claude.health(from: data) == .degradedPerformance)
        #expect(claude.health(from: summary([("claude.ai", "major_outage"), ("Claude Code", "operational")])) == .operational)
    }

    @Test func theWorstRelevantComponentWins() {
        let data = summary([("Responses", "partial_outage"), ("Codex in ChatGPT Desktop", "major_outage"), ("Images", "operational")])
        #expect(codex.health(from: data) == .majorOutage)
    }

    @Test func anUnreadablePageGivesNoHealth() {
        #expect(claude.health(from: Data("<html>".utf8)) == nil)
        #expect(claude.health(from: summary([("claude.ai", "major_outage")])) == nil)
    }

    @Test func aProblemReadsAsOneQuietLine() {
        #expect(ServiceHealth.degradedPerformance.line(title: "Claude") == "Claude: degraded performance")
        #expect(ServiceHealth.underMaintenance.line(title: "Codex") == "Codex: under maintenance")
        #expect(ServiceHealth.operational.line(title: "Claude") == nil)
    }

    @Test func onlyClaudeAndCodexHaveAStatusPage() {
        #expect(claude.pageURL.absoluteString == "https://status.claude.com")
        #expect(codex.summaryURL.absoluteString == "https://status.openai.com/api/v2/summary.json")
        #expect(StatusPage.forProvider("kimi") == nil)
    }
}

@Suite(.hangLimit) struct StatusPageReadsTests {
    private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

    @Test func eachProviderIsReadAtMostEveryFiveMinutes() {
        var reads = StatusPageReads()
        #expect(reads.due(["claude", "kimi"], now: now) == ["claude"])
        reads.record("claude", health: .operational, now: now)
        #expect(reads.due(["claude"], now: now + 299).isEmpty)
        #expect(reads.due(["claude"], now: now + 300) == ["claude"])
    }

    @Test func aProviderThatJoinsLaterIsReadAtOnce() {
        var reads = StatusPageReads()
        reads.record("claude", health: .operational, now: now)
        #expect(reads.due(["claude", "codex"], now: now + 10) == ["codex"])
    }

    @Test func aFailedReadKeepsTheLastKnownProblem() {
        var reads = StatusPageReads()
        reads.record("claude", health: .majorOutage, now: now)
        reads.record("claude", health: nil, now: now + 300)
        #expect(reads.incidents == ["claude": .majorOutage])
        #expect(reads.due(["claude"], now: now + 301).isEmpty)
    }

    @Test func aGoodReadClearsTheProblem() {
        var reads = StatusPageReads()
        reads.record("codex", health: .partialOutage, now: now)
        reads.record("codex", health: .operational, now: now + 300)
        #expect(reads.incidents.isEmpty)
    }
}

@Suite(.hangLimit) struct IncidentTrackerTests {
    private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!
    @Test func aNewProblemAlertsOnce() {
        var tracker = IncidentTracker()
        #expect(tracker.alerts(provider: "claude", title: "Claude", health: .degradedPerformance, now: now).map(\.title) == ["Claude: degraded performance"])
        #expect(tracker.alerts(provider: "claude", title: "Claude", health: .degradedPerformance, now: now).isEmpty)
    }

    @Test func aWorseningProblemAlertsAgainButARecoveryDoesNot() {
        var tracker = IncidentTracker()
        _ = tracker.alerts(provider: "claude", title: "Claude", health: .degradedPerformance, now: now)
        #expect(tracker.alerts(provider: "claude", title: "Claude", health: .majorOutage, now: now).count == 1)
        #expect(tracker.alerts(provider: "claude", title: "Claude", health: .partialOutage, now: now).isEmpty)
        #expect(tracker.alerts(provider: "claude", title: "Claude", health: .operational, now: now).isEmpty)
    }

    @Test func theNextProblemAfterAnHourOfRecoveryAlertsAgain() {
        var tracker = IncidentTracker()
        _ = tracker.alerts(provider: "codex", title: "Codex", health: .partialOutage, now: now)
        _ = tracker.alerts(provider: "codex", title: "Codex", health: .operational, now: now + 300)
        #expect(tracker.alerts(provider: "codex", title: "Codex", health: .degradedPerformance, now: now + 3900).count == 1)
    }

    @Test func aFlappingStatusAlertsOnce() {
        var tracker = IncidentTracker()
        _ = tracker.alerts(provider: "codex", title: "Codex", health: .partialOutage, now: now)
        _ = tracker.alerts(provider: "codex", title: "Codex", health: .operational, now: now + 300)
        #expect(tracker.alerts(provider: "codex", title: "Codex", health: .partialOutage, now: now + 600).isEmpty)
        _ = tracker.alerts(provider: "codex", title: "Codex", health: .underMaintenance, now: now + 900)
        #expect(tracker.alerts(provider: "codex", title: "Codex", health: .partialOutage, now: now + 1200).isEmpty)
    }

    @Test func maintenanceNeverAlerts() {
        var tracker = IncidentTracker()
        #expect(tracker.alerts(provider: "claude", title: "Claude", health: .underMaintenance, now: now).isEmpty)
    }

    @Test func aRelaunchRemembersWhatWasAnnounced() throws {
        var tracker = IncidentTracker()
        _ = tracker.alerts(provider: "claude", title: "Claude", health: .partialOutage, now: now)
        var restored = try JSONDecoder().decode(IncidentTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored.alerts(provider: "claude", title: "Claude", health: .partialOutage, now: now).isEmpty)
    }
}
