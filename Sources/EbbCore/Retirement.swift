import Foundation

/// Takes accounts whose plan ended out of CLIProxyAPI, and puts back the ones that renew.
/// Only accounts listed in `retired.json` count as ours; anything else disabled was the user.
public enum Retirement {
    /// "Inactive" answers in a row needed before an account is retired.
    public static let confirmations = 2

    public enum Action: Sendable, Equatable {
        case retire, reinstate, keep
    }

    public static func action(isDisabled: Bool, isRetiredByUs: Bool, plan: Plan, inactiveStreak: Int) -> Action {
        switch plan {
        case .inactive where !isDisabled && inactiveStreak >= confirmations: .retire
        case .paid where isDisabled && isRetiredByUs: .reinstate
        default: .keep
        }
    }

    /// After a usage call: only a definitive answer about the subscription can retire or
    /// reinstate. A refused token, a rate limit or a failure leaves the account alone.
    public static func action(after outcome: CallOutcome, isDisabled: Bool, isRetiredByUs: Bool, inactiveStreak: Int) -> Action {
        guard case .reading = outcome else { return .keep }
        let plan = outcome.subscriptionEvidence ?? .paid(weight: PlanWeight(1))
        return action(isDisabled: isDisabled, isRetiredByUs: isRetiredByUs, plan: plan, inactiveStreak: inactiveStreak)
    }
}

/// `retired.json`: auth file names this app disabled.
public struct RetiredAccounts: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// `retired.json` for the proxy on this Mac. A remote proxy keeps its own list, named by host,
    /// so its listing never forgets what Ebb retired on another proxy.
    public static func file(in directory: URL, remoteHost: String?) -> URL {
        guard let remoteHost else { return directory.appending(path: "retired.json") }
        let safe = remoteHost.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }
        return directory.appending(path: "retired-\(String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))).json")
    }

    public func load() -> Set<String> {
        guard let data = try? Data(contentsOf: file),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }

    public func save(_ names: Set<String>) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(names.sorted()).write(to: file, options: .atomic)
    }

    /// Records the outcome of an action the proxy accepted.
    public func record(_ action: Retirement.Action, name: String) throws {
        var names = load()
        switch action {
        case .retire: names.insert(name)
        case .reinstate: names.remove(name)
        case .keep: return
        }
        try save(names)
    }

    /// Forgets names the proxy no longer lists as disabled (re-enabled or deleted by hand),
    /// so a later manual disable is never mistaken for ours.
    public func forget(allBut stillDisabled: Set<String>) throws {
        let names = load()
        let kept = names.intersection(stillDisabled)
        if kept != names { try save(kept) }
    }
}
