import Foundation

/// CLIProxyAPI locks a client out of its management API for 30 minutes after five wrong keys,
/// counting localhost too, and every call during a lockout fails. So after one refusal Ebb stops
/// asking with that key until a lockout would have ended; a different key is tried at once.
public struct ManagementLockout: Sendable, Equatable {
    /// CLIProxyAPI's `banDuration`, plus a minute so the first retry lands after it.
    static let pause: TimeInterval = 31 * 60

    private var refusedKey: ManagementKey?
    private var resumesAt: Date?
    private var bannedUntil: Date?

    public init() {}

    public func allowsRequest(with key: ManagementKey, now: Date) -> Bool {
        guard key == refusedKey, let resumesAt else { return true }
        return now >= resumesAt
    }

    /// Whether the proxy said this Mac is locked out, rather than just that the key is wrong.
    public func isBanned(now: Date) -> Bool {
        bannedUntil.map { now < $0 } ?? false
    }

    /// `message` is the proxy's error text, which names the time left when it's a lockout.
    public mutating func noteRefusal(of key: ManagementKey, message: String, now: Date) {
        refusedKey = key
        let ban = Self.remainingBan(in: message)
        bannedUntil = ban.map { now + $0 }
        resumesAt = now + (ban.map { $0 + 60 } ?? Self.pause)
    }

    public mutating func noteAccepted() {
        self = ManagementLockout()
    }

    /// The Go duration in "… Try again in 29m58s".
    static func remainingBan(in message: String) -> TimeInterval? {
        guard let range = message.range(of: #"Try again in ((?:\d+h)?(?:\d+m)?(?:\d+(?:\.\d+)?s)?)"#, options: .regularExpression) else { return nil }
        let duration = message[range].dropFirst("Try again in ".count)
        var total: TimeInterval = 0
        var number = ""
        for character in duration {
            if character.isNumber || character == "." {
                number.append(character)
            } else {
                let unit: TimeInterval = switch character {
                case "h": 3600
                case "m": 60
                default: 1
                }
                total += (Double(number) ?? 0) * unit
                number = ""
            }
        }
        return duration.isEmpty ? nil : total
    }
}
