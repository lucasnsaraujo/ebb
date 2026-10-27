import Foundation
import os

/// `--budget-report <file>`: counts what Ebb does while it idles and writes the counts to the file. CI runs
/// it twice, with the menu bar item showing and with `--hidden`, and `scripts/check-budget.sh` holds the
/// numbers to the budget. The run's network is `StandInProxy`, so it needs no proxy and sends nothing.
enum Budget {
    static let isRecording = LaunchOptions.budgetReport != nil

    /// The loops tick at 0, 30 and 60 s, a little late each time. This much more than the run's length
    /// keeps the tick at 60 s inside the count on every run.
    private static let grace: Duration = .seconds(5)

    private struct Counts {
        var requests: [String: Int] = [:]
        var wakes: [String: Int] = [:]
    }

    private static let counts = OSAllocatedUnfairLock(initialState: Counts())

    /// A request went out through the transport. `label` names what it asked for.
    static func request(_ label: String) {
        guard isRecording else { return }
        counts.withLock { $0.requests[label, default: 0] += 1 }
    }

    /// A timer or polling loop woke up.
    static func wake(_ source: String) {
        guard isRecording else { return }
        counts.withLock { $0.wakes[source, default: 0] += 1 }
    }

    struct Report: Codable, Equatable {
        var seconds: Double
        var isHidden: Bool
        var requestTotal: Int
        var wakeTotal: Int
        var requests: [String: Int]
        var wakes: [String: Int]
    }

    static func snapshot(seconds: Double, isHidden: Bool) -> Report {
        let counts = counts.withLock { $0 }
        return Report(
            seconds: seconds, isHidden: isHidden,
            requestTotal: counts.requests.values.reduce(0, +), wakeTotal: counts.wakes.values.reduce(0, +),
            requests: counts.requests, wakes: counts.wakes
        )
    }

    /// A budget run writes caches, the usage ledger and the pool status like a real one, so it runs
    /// only in a throwaway home: the script sets `HOME` and `CFFIXED_USER_HOME` and names it in `EBB_BUDGET_HOME`.
    static func requireThrowawayHome() {
        guard isRecording else { return }
        let named = ProcessInfo.processInfo.environment["EBB_BUDGET_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let home = EbbPaths.home.resolvingSymlinksInPath().path
        guard named == home, EbbPaths.applicationSupport.resolvingSymlinksInPath().path.hasPrefix(home) else {
            FileHandle.standardError.write(Data("--budget-report needs a throwaway home: run scripts/check-budget.sh\n".utf8))
            exit(2)
        }
    }

    /// Ends the run after `seconds`: writes the report and quits.
    @MainActor
    static func finish(after seconds: Double, writingTo file: URL) {
        Task {
            try? await Task.sleep(for: .seconds(seconds) + grace)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = snapshot(seconds: seconds, isHidden: LaunchOptions.forcesHidden)
            do {
                try encoder.encode(report).write(to: file, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Couldn't write the budget report: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(0)
        }
    }
}
