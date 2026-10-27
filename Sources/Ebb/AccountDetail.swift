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
        /// The provider refused the token the proxy holds, so its windows can't be read.
        case limitsUnavailable
        /// A provider without usage windows: only the proxy's view of its health.
        case health(AccountHealth.State)
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
    /// Ebb's provider name; Claude unless set.
    var provider = ClaudeProvider().proxyName
    /// The auth file name, for logins without an email.
    var fileName: String?
    /// The plan as the provider names it, for providers whose weight doesn't spell it out.
    var planTitle: String?
    /// The proxy's message for a login it holds back.
    var healthMessage: String?
    /// Paid usage past the plan's limits, shown on hover only.
    var extraUsage: ExtraUsage?
    /// The proxy holds it in cooldown though a fresh reading shows quota.
    var isStuckInCooldown = false
    /// The proxy's key for the login, for its `reset-quota` call.
    var authIndex: String?

    var id: String { provider == ClaudeProvider().proxyName ? email : "\(provider)/\(fileName ?? email)" }

    /// Read recently, and the plan has no general weekly cap (Team plans).
    var hasNoWeeklyCap: Bool {
        readAt != nil && sessionFree != nil && weeklyFree == nil
    }

    var label: String {
        email.split(separator: "@").first.map(String.init) ?? email
    }

    var planBadge: String? {
        if let planTitle { return planTitle }
        guard provider == ClaudeProvider().proxyName, case let .paid(weight) = plan else { return nil }
        return weight > 1 ? "\(Int(weight))x" : "Pro"
    }

    var isHealthOnly: Bool {
        if case .health = status { true } else { false }
    }
}

extension AccountDetail.Status {
    /// The word Copy Diagnostics uses.
    var diagnosticsName: String {
        switch self {
        case .active: "active"
        case .stale: "stale"
        case .retired: "retired"
        case .disabledByUser, .health(.disabled): "disabled"
        case .limitsUnavailable: "limits unavailable"
        case .health(.ok): "health ok"
        case .health(.coolingDown): "cooling down"
        case .health(.failing): "failing"
        }
    }
}
