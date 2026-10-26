import Foundation
import Testing
@testable import EbbCore

private let now = UsageLimit.parseTimestamp("2026-10-26T19:34:00+00:00")!

private func at(_ minutes: Double) -> Date {
    now.addingTimeInterval(minutes * 60)
}

private func window(_ free: Double, resets: [(minutes: Double, gain: Double)] = []) -> WindowStatus {
    WindowStatus(freePercent: free, resets: resets.map { Restoration(date: at($0.minutes), gain: $0.gain) })
}

private func claude(session: WindowStatus = window(88), weekly: WindowStatus = window(45)) -> ProviderStatus {
    ProviderStatus(id: "claude", title: "Claude", shortWindow: .fiveHours, session: session, weekly: weekly, isPartial: false, readAt: now)
}

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "ebb-tests-\(UUID().uuidString)/status.json")
}

@Suite struct PoolStatusFileTests {
    @Test func whatTheAppWritesTheCommandReadsBack() throws {
        let file = temporaryFile()
        let status = PoolStatus(updatedAt: now, menuBarProvider: "claude", providers: [claude(session: window(88, resets: [(30, 12)]))])
        try status.write(to: file)
        #expect(PoolStatus.read(from: file) == status)
    }

    @Test func aFileFromAnotherVersionReadsAsMissing() throws {
        let file = temporaryFile()
        var status = PoolStatus(updatedAt: now, menuBarProvider: nil, providers: [claude()])
        status.version = PoolStatus.currentVersion + 1
        try status.write(to: file)
        #expect(PoolStatus.read(from: file) == nil)
    }
}

@Suite struct WindowStatusTests {
    @Test func resetsThatPassedSinceTheReadingAddTheirCapacityBack() {
        let status = window(60, resets: [(10, 15), (40, 20)])
        #expect(status.free(at: at(5)) == 60)
        #expect(status.free(at: at(10)) == 75)
        #expect(status.free(at: at(41)) == 95)
    }

    @Test func freeCapacityNeverPassesAHundred() {
        #expect(window(90, resets: [(10, 15)]).free(at: at(20)) == 100)
    }

    @Test func theNextRefillIsTheFirstResetStillAhead() {
        let status = window(60, resets: [(10, 15), (40, 20)])
        #expect(status.nextRefill(at: at(5)) == Restoration(date: at(10), gain: 15))
        #expect(status.nextRefill(at: at(10)) == Restoration(date: at(40), gain: 20))
        #expect(status.nextRefill(at: at(41)) == nil)
    }

    @Test func aResetWorthLessThanHalfAPointIsNoRefill() {
        #expect(window(60, resets: [(10, 0.4), (40, 20)]).nextRefill(at: at(5)) == Restoration(date: at(40), gain: 20))
    }
}

@Suite struct PoolStatusFromSummariesTests {
    private func summary(session: Double, weekly: Double, isPartial: Bool = false) -> PoolSummary {
        PoolSummary(
            session: WindowSummary(freePercent: session, resets: [Restoration(date: at(30), gain: 10)]),
            weekly: WindowSummary(freePercent: weekly, resets: []),
            isPartial: isPartial
        )
    }

    @Test func eachProviderKeepsItsOwnWindowsInTheGivenOrder() {
        let status = PoolStatus(
            summaries: ["claude": summary(session: 88, weekly: 45), "devin": summary(session: 70, weekly: 40, isPartial: true)],
            providers: ["devin", "claude"],
            readAt: ["claude": at(-1)],
            menuBarProvider: "claude",
            updatedAt: now
        )
        #expect(status.providers.map(\.id) == ["devin", "claude"])
        #expect(status.providers[0].shortWindow == .day)
        #expect(status.providers[0].isPartial)
        #expect(status.providers[1].title == "Claude")
        #expect(status.providers[1].session == WindowStatus(freePercent: 88, resets: [Restoration(date: at(30), gain: 10)]))
        #expect(status.providers[1].weekly == WindowStatus(freePercent: 45, resets: []))
        #expect(status.providers[1].readAt == at(-1))
        #expect(status.providers[0].readAt == nil)
    }

    @Test func aProviderWithoutASummaryIsLeftOut() {
        let status = PoolStatus(summaries: ["claude": summary(session: 88, weekly: 45)], providers: ["codex", "claude"], readAt: [:], menuBarProvider: nil, updatedAt: now)
        #expect(status.providers.map(\.id) == ["claude"])
    }
}

@Suite struct PoolStatusWriteTests {
    private func status(at date: Date, session: Double = 88) -> PoolStatus {
        PoolStatus(updatedAt: date, menuBarProvider: "claude", providers: [claude(session: window(session))])
    }

    @Test func theFirstStatusIsWritten() {
        #expect(status(at: now).needsWrite(after: nil))
    }

    @Test func changedNumbersAreWrittenAtOnce() {
        #expect(status(at: at(0.5), session: 87).needsWrite(after: status(at: now)))
    }

    @Test func aNewerReadingOfTheSameNumbersWaitsForTheRefresh() {
        var next = status(at: at(1))
        next.providers[0].readAt = at(1)
        #expect(!next.needsWrite(after: status(at: now)))
    }

    @Test func unchangedNumbersAreRewrittenOnlyToRefreshTheirAge() {
        #expect(!status(at: at(4)).needsWrite(after: status(at: now)))
        #expect(status(at: at(5)).needsWrite(after: status(at: now)))
    }
}
