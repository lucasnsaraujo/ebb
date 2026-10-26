import Foundation
import EbbCore

/// One row of the accounts panel.
struct AccountDetail: Identifiable, Equatable {
    enum Status: Equatable {
        /// Read recently and counted in the pool.
        case active
        /// Enabled, but read a while ago or not at all. A past reading still counts.
        case stale
        /// Disabled by Ebb because its plan ended.
        case retired
        /// Disabled by hand in the proxy; never touched.
        case disabledByUser
    }

    let email: String
    let plan: Plan?
    let status: Status
    var sessionFree: Double?
    /// `nil` when the plan has no weekly cap, or there's no reading.
    var weeklyFree: Double?
    /// Percent of new threads the proxy routes here.
    var share: Double?
    var readAt: Date?

    var id: String { email }

    /// Read recently, and the plan has no general weekly cap (Team plans).
    var hasNoWeeklyCap: Bool {
        readAt != nil && sessionFree != nil && weeklyFree == nil
    }

    var label: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }

    var planBadge: String? {
        guard case let .paid(weight) = plan else { return nil }
        return weight > 1 ? "\(Int(weight))x" : "Pro"
    }
}
