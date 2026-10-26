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
}

/// `retired.json`: auth file names this app disabled.
public struct RetiredAccounts: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
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
