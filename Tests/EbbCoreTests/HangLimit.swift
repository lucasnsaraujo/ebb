import Foundation
import Testing

extension Trait where Self == HangLimit {
    /// Ends the whole test process when one test runs past `seconds`.
    static var hangLimit: Self { HangLimit(seconds: 60) }
}

/// `.timeLimit` only cancels a test's task, so a test spinning in a synchronous loop keeps the
/// `swiftpm-testing-helper` process at full CPU, even after `swift test` itself is killed.
/// This exits the process instead, so a hang fails the run within a minute.
struct HangLimit: SuiteTrait, TestTrait, TestScoping {
    /// Its own queue: with every core busy in spinning tests, the shared global pool may never run the timer.
    private static let timerQueue = DispatchQueue(label: "HangLimit")

    let seconds: Int
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let exitProcess = DispatchWorkItem { [seconds] in
            FileHandle.standardError.write(Data("\(test.name) at \(test.sourceLocation) ran past \(seconds)s; exiting.\n".utf8))
            exit(EXIT_FAILURE)
        }
        Self.timerQueue.asyncAfter(deadline: .now() + .seconds(seconds), execute: exitProcess)
        defer { exitProcess.cancel() }
        try await function()
    }
}
