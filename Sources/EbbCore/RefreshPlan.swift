import Foundation

public struct FetchState: Sendable, Equatable {
    public var lastAttempt: Date?
    public var retryNotBefore: Date?
    public var failures = 0

    public init(lastAttempt: Date? = nil, retryNotBefore: Date? = nil, failures: Int = 0) {
        self.lastAttempt = lastAttempt
        self.retryNotBefore = retryNotBefore
        self.failures = failures
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
