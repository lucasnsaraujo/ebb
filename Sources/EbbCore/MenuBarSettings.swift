import Foundation
import Observation

/// The menu bar style and limit, kept in UserDefaults across launches.
@MainActor
@Observable
public final class MenuBarSettings {
    public static let styleKey = "menuBarStyle"
    public static let limitKey = "menuBarLimit"

    public var style: MenuBarStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }

    public var limit: MenuBarLimit {
        didSet { defaults.set(limit.rawValue, forKey: Self.limitKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Values it doesn't recognise, say from a newer version, fall back to Default and 5-Hour.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleKey).flatMap(MenuBarStyle.init(rawValue:)) ?? .standard
        limit = defaults.string(forKey: Self.limitKey).flatMap(MenuBarLimit.init(rawValue:)) ?? .fiveHour
    }
}
