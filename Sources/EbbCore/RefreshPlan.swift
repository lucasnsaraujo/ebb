import Foundation

public struct FetchState: Sendable, Equatable {
    public var lastAttempt: Date?
    public var retryNotBefore: Date?
    public var failures = 0
    /// How the last attempt ended, for the diagnostics.
    public var lastOutcome: RequestOutcome?

    public init(lastAttempt: Date? = nil, retryNotBefore: Date? = nil, failures: Int = 0, lastOutcome: RequestOutcome? = nil) {
        self.lastAttempt = lastAttempt
        self.retryNotBefore = retryNotBefore
        self.failures = failures
        self.lastOutcome = lastOutcome
    }
}

public enum RefreshPlan {
    /// An idle account's usage is read this often.
    public static let period: TimeInterval = 5 * 60
    /// No two provider requests, direct or through the proxy's `api-call`, go out closer than this.
    public static let minimumSpacing: TimeInterval = 60

    /// False when the login was tried after the job picked it: another trigger got there
    /// while this one waited for its slot.
    public static func isStillDue(_ state: FetchState?, chosenAt: Date) -> Bool {
        (state?.lastAttempt ?? .distantPast) < chosenAt
    }

    /// Whether a provider request may go out now: none went out within `minimumSpacing`.
    public static func isSlotFree(lastRequest: Date?, now: Date) -> Bool {
        guard let lastRequest else { return true }
        return now.timeIntervalSince(lastRequest) >= minimumSpacing
    }

    /// The account to read next: the one tried longest ago, skipping accounts
    /// that are backing off or were tried within `minimumAge`.
    public static func nextAccount(in states: [String: FetchState], minimumAge: TimeInterval, now: Date) -> String? {
        states
            .filter { _, state in
                if let retry = state.retryNotBefore, retry > now { return false }
                guard let last = state.lastAttempt else { return true }
                return now.timeIntervalSince(last) >= minimumAge
            }
            .min { lhs, rhs in
                let left = lhs.value.lastAttempt ?? .distantPast
                let right = rhs.value.lastAttempt ?? .distantPast
                return left == right ? lhs.key < rhs.key : left < right
            }?
            .key
    }
}

/// What one wake may do once the network is back: poll the proxy, and read the one account whose
/// reading went stale longest ago during the sleep. The loops fire on wake as well, their sleeps
/// having run out, so a wake never reads within a minute of the last provider request.
public enum WakeRefresh {
    /// Wi-Fi comes back a few seconds after the screen does.
    public static let networkDelay: TimeInterval = 5
    /// A reading older than this at wake is worth re-reading before the loop gets to it.
    public static let staleAge: TimeInterval = 2 * 60

    public static func account(in states: [String: FetchState], lastRequest: Date?, now: Date) -> String? {
        guard RefreshPlan.isSlotFree(lastRequest: lastRequest, now: now) else { return nil }
        return RefreshPlan.nextAccount(in: states, minimumAge: staleAge, now: now)
    }
}
