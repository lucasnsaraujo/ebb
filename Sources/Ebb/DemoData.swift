import EbbCore
import Foundation

/// `--demo`: fake logins of every kind, with no network and no saved key. Claude, Codex,
/// Devin and Antigravity pools; a Kimi login whose token is refused; two health-only logins.
@MainActor
enum DemoData {
    private struct Login {
        var provider: String
        var email: String
        var plan: String?
        var sessionUsed: Double?
        var sessionResetIn: TimeInterval = 2 * 3600
        var weeklyUsed: Double?
        var weeklyResetIn: TimeInterval = 3 * 86400
        var status: AccountDetail.Status = .active
        var message: String?
    }

    private static let logins = [
        Login(provider: "claude", email: "work@example.com", plan: "max_20x", sessionUsed: 64, sessionResetIn: 132 * 60, weeklyUsed: 71),
        Login(provider: "claude", email: "research@example.com", plan: "max_5x", sessionUsed: 12, sessionResetIn: 41 * 60),
        Login(provider: "claude", email: "side@example.com", plan: "max_5x", sessionUsed: 30, sessionResetIn: 250 * 60),
        Login(provider: "claude", email: "lab@example.com", plan: "max_5x", sessionUsed: 20, sessionResetIn: 70 * 60, weeklyUsed: 100, weeklyResetIn: 3 * 3600),
        Login(provider: "codex", email: "plus@example.com", plan: "plus", sessionUsed: 25, sessionResetIn: 95 * 60, weeklyUsed: 60, weeklyResetIn: 4 * 86400),
        Login(provider: "codex", email: "pro@example.com", plan: "pro", sessionUsed: 10, sessionResetIn: 200 * 60, weeklyUsed: 34, weeklyResetIn: 2 * 86400),
        Login(provider: "devin", email: "dev@example.com", plan: "pro", sessionUsed: 27, sessionResetIn: 9 * 3600, weeklyUsed: 60, weeklyResetIn: 6 * 86400),
        Login(provider: "antigravity", email: "agy@example.com", sessionUsed: 70, sessionResetIn: 80 * 60, weeklyUsed: 40, weeklyResetIn: 5 * 86400),
        Login(provider: "kimi", email: "moon@example.com", plan: "level_basic", status: .limitsUnavailable),
        Login(provider: "xai", email: "grok@example.com", status: .health(.coolingDown(until: .now + 40 * 60)), message: "quota exhausted"),
        Login(provider: "gemini", email: "Gemini key", status: .health(.ok)),
    ]

    /// A Claude 5-hour pool that runs out before its big reset, and a Codex week that runs out
    /// on Thursday-ish; the other windows last, so their pace shows only on hover.
    private static let forecasts = [
        "claude": PoolForecast(
            session: Pace.Forecast(outlook: .runsOut(within: (110 * 60)...(110 * 60)), basis: 40 * 60),
            weekly: nil
        ),
        "codex": PoolForecast(
            session: Pace.Forecast(outlook: .lasts, basis: 35 * 60),
            weekly: Pace.Forecast(outlook: .runsOut(within: (3.6 * 86400)...(3.6 * 86400)), basis: 5 * 86400)
        ),
    ]

    static func store(connection: ProxyConnection, now: Date = .now) -> PoolStore {
        var providerLogins: [ProviderLogin] = []
        var details: [AccountDetail] = []
        var routing: [String: Int] = [:]
        for login in logins {
            let limits = [
                login.sessionUsed.map { UsageLimit(kind: .session, usedPercent: $0, resetsAt: now + login.sessionResetIn) },
                login.weeklyUsed.map { UsageLimit(kind: .weeklyAll, usedPercent: $0, resetsAt: now + login.weeklyResetIn) },
            ].compactMap { $0 }
            let isPooled = Providers.named(login.provider) != nil
            let plan = PlanWeights.defaultWeight(provider: login.provider, plan: login.plan).map { Plan.paid(weight: $0) } ?? .unknown
            let member = isPooled ? PoolMember(plan: plan, signals: limits.isEmpty ? nil : DatedLimits(limits: limits, date: now - 150), usage: nil) : nil
            providerLogins.append(ProviderLogin(provider: login.provider, member: member))
            if !limits.isEmpty {
                routing[login.email] = ProxyWeight.target(planWeight: plan.weight.session, freePercent: Pool.effectiveFree(limits, at: now))
            }
            let isClaude = login.provider == ClaudeProvider().proxyName
            var detail = AccountDetail(
                email: login.email,
                plan: plan,
                status: login.status,
                sessionFree: login.sessionUsed.map { 100 - $0 },
                weeklyFree: login.weeklyUsed.map { 100 - $0 },
                readAt: limits.isEmpty ? nil : now - 150,
                provider: login.provider,
                fileName: "\(login.provider)-\(login.email).json",
                planTitle: isClaude ? nil : PlanWeights.defaults[login.provider]?.first { $0.plan == login.plan }?.title
            )
            detail.healthMessage = login.message
            // One Claude login the proxy still skips though its quota is back.
            if login.email == "side@example.com" {
                detail.isStuckInCooldown = true
                detail.authIndex = "4"
            }
            details.append(detail)
        }
        for provider in Set(logins.map(\.provider)) {
            let shares = ProxyWeight.shares(routing.filter { email, _ in logins.contains { $0.email == email && $0.provider == provider } })
            for index in details.indices where details[index].provider == provider {
                details[index].share = shares[details[index].email]
            }
        }
        let pooled = Set(providerLogins.filter { $0.member != nil }.map(\.provider))
        let state = PoolState(
            summaries: ProviderPools.summarize(providerLogins, at: now),
            details: details.sorted { $0.label < $1.label },
            providers: Providers.all.map(\.proxyName).filter(pooled.contains),
            defaultProvider: ProviderPools.defaultProvider(ProviderPools.pooledWeight(providerLogins)),
            forecasts: forecasts
        )
        let urgent = UrgentLogin(provider: "Codex", freePercent: 40, factor: 1.73, weeklyResetsAt: now + 13 * 3600)
        let isDown = LaunchOptions.demo == .down
        return PoolStore(connection: connection, state: state, proxyReadAt: isDown ? nil : now - 150, proxyFailure: isDown ? .unreachable : nil, strongestUrgency: urgent, incidents: ["codex": .degradedPerformance])
    }

    /// `--demo low`: a nearly empty pool, to show the menu bar's warning colours.
    static func lowMenuBarPool(now: Date) -> MenuBarPool {
        MenuBarPool(
            session: WindowReading(window: .session, percent: 5, refillsAt: now + 38 * 60),
            weekly: WindowReading(window: .weekly, percent: 8, refillsAt: now + 2 * 86400),
            accounts: [true, false, false, false],
            lastReadAt: now
        )
    }
}
