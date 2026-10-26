import Foundation

public enum Backoff {
    public static let longest: TimeInterval = 30 * 60
    static let first: TimeInterval = 2 * 60

    /// How long an account waits after `failures` failed requests in a row.
    /// A server-sent `Retry-After` always wins.
    public static func delay(afterFailures failures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return max(retryAfter, 1) }
        let doublings = Double(max(failures, 1) - 1)
        return min(first * pow(2, doublings), longest)
    }

    /// Parses a `Retry-After` header: delta-seconds or an HTTP date.
    public static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { $0.timeIntervalSince(now) }
    }
}
