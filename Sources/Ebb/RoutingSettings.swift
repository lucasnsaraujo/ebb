import Foundation

enum RoutingSettings {
    static let balancesSessionsKey = "balancesSessions"

    /// "Balance new sessions by remaining capacity", on unless turned off in Settings.
    static var balancesSessions: Bool {
        UserDefaults.standard.object(forKey: balancesSessionsKey) as? Bool ?? true
    }
}
