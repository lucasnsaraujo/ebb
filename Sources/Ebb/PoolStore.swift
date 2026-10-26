import Foundation
import Observation
import EbbCore

/// Keeps the pool summary fresh while the menu bar item is visible.
///
/// CLIProxyAPI's management API is the main source: free, polled every 30 s, carrying the
/// rate-limit headers of each account's latest real response. Providers are asked only for
/// idle accounts and plan checks, one request at a time and at least a minute apart.
@MainActor
@Observable
final class PoolStore {
    static let proxyInterval: Duration = .seconds(30)
    static let providerInterval: Duration = .seconds(RefreshPlan.minimumSpacing)
    /// Opening the panel re-reads an idle account whose reading is older than this.
    static let staleOnOpen: TimeInterval = 2 * 60

    private(set) var summary: PoolSummary?
    /// Every Claude login, for the accounts panel: the only place accounts appear.
    private(set) var accountDetails: [AccountDetail] = []
    /// When the proxy last answered; `nil` while it's unreachable.
    private(set) var proxyReadAt: Date?
    /// The newest usage-API reading among accounts that rely on one.
    private(set) var usageAPIReadAt: Date?
    private(set) var isRefreshing = false

    private struct Dated<Value> {
        var value: Value
        var date: Date
    }

    private enum Job {
        case usage(String)
        case profile(String)
    }

    @ObservationIgnored private let accountClient = AccountClient()
    @ObservationIgnored private let proxy = ProxyClient()
    @ObservationIgnored private let connection: ProxyConnection
    /// Never touches the network; shows cached numbers only.
    let isOffline: Bool
    /// By email. Accounts the user disabled by hand are left out of everything but the panel.
    @ObservationIgnored private var accounts: [String: ProxyAccount] = [:]
    @ObservationIgnored private var disabledByUser: [ProxyAccount] = []
    /// The proxy's latest listing by auth file name; empty while it's unreachable.
    @ObservationIgnored private var proxyFiles: [String: ProxyAuthFile] = [:]
    @ObservationIgnored private var retired: Set<String> = []
    @ObservationIgnored private var usageReadings: [String: DatedLimits] = [:]
    @ObservationIgnored private var plans: [String: Dated<Plan>] = [:]
    @ObservationIgnored private var usageStates: [String: FetchState] = [:]
    @ObservationIgnored private var profileStates: [String: FetchState] = [:]
    /// Accounts whose token was refused; their plan is checked next.
    @ObservationIgnored private var profileRequested: Set<String> = []
    @ObservationIgnored private var inactiveStreaks: [String: Int] = [:]
    @ObservationIgnored private var writtenCaches: [String: Data] = [:]
    /// Kept across launches, so a relaunch never sends two requests back to back.
    @ObservationIgnored private var lastProviderRequest = UserDefaults.standard.object(forKey: "lastProviderRequest") as? Date {
        didSet { UserDefaults.standard.set(lastProviderRequest, forKey: "lastProviderRequest") }
    }
    @ObservationIgnored private var isPollingProxy = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    /// `isOffline` shows cached numbers only; used for screenshots and UI work.
    init(connection: ProxyConnection, isOffline: Bool = false) {
        self.connection = connection
        self.isOffline = isOffline
        reloadAccounts()
        loadCaches()
        recompute()
    }

    /// Starts or stops all network activity, localhost included.
    func setActive(_ isActive: Bool) {
        loops.forEach { $0.cancel() }
        loops = []
        recompute()
        guard isActive, !isOffline else { return }
        loops = [
            Task { await repeatEvery(Self.proxyInterval) { await $0.pollProxy() } },
            Task { await repeatEvery(Self.providerInterval) { await $0.runNextProviderJob(usageMinimumAge: RefreshPlan.period - 30) } },
        ]
    }

    /// Called when the panel opens: polls the proxy and re-reads one idle account,
    /// unless a provider request went out within the last minute.
    func panelDidOpen() {
        recompute()
        guard !loops.isEmpty else { return }
        Task { await pollProxy() }
        if isProviderSlotFree(at: .now), let job = nextJob(usageMinimumAge: Self.staleOnOpen) {
            Task { await run(job) }
        }
    }

    func refreshNow() {
        guard !loops.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        Task {
            await pollProxy()
            if let job = nextJob(usageMinimumAge: 0) { await run(job) }
            isRefreshing = false
        }
    }

    private func repeatEvery(_ interval: Duration, _ step: (PoolStore) async -> Void) async {
        while !Task.isCancelled {
            await step(self)
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - Proxy

    private func pollProxy() async {
        guard !isPollingProxy else { return }
        isPollingProxy = true
        defer { isPollingProxy = false }

        if let endpoint = connection.endpoint, let files = await proxy.authFiles(endpoint) {
            proxyFiles = Dictionary(files.map { ($0.name, $0) }) { first, _ in first }
            proxyReadAt = .now
            try? EbbPaths.retiredAccounts.forget(allBut: Set(files.filter(\.isDisabled).map(\.name)))
        } else {
            proxyFiles = [:]
            proxyReadAt = nil
        }
        reloadAccounts()
        writeSignalCaches()
        recompute()
        await syncProxyWeights()
    }

    /// Steers new threads toward free capacity: weight = plan size × free percent.
    private func syncProxyWeights() async {
        guard RoutingSettings.balancesSessions, let endpoint = connection.endpoint else { return }
        let now = Date.now
        for account in accounts.values where !isDisabled(account) {
            guard case let .paid(planWeight) = plans[account.email]?.value,
                  let listed = proxyFiles[account.name],
                  let limits = reading(for: account, at: now)
            else { continue }
            let target = ProxyWeight.target(planWeight: planWeight, freePercent: Pool.effectiveFree(limits, at: now))
            guard ProxyWeight.needsUpdate(current: listed.weight, target: target) else { continue }
            if await proxy.setWeight(target, for: account.name, endpoint) {
                proxyFiles[account.name]?.weight = target
            }
        }
    }

    /// Keeps `~/.cache/pool-limits` current for the `pool-limits` CLI without extra requests.
    private func writeSignalCaches() {
        for account in accounts.values {
            guard let quota = signals(for: account), ReadingChoice.hasFreshSignals(quota, now: .now) else { continue }
            let data = UsageLimit.encodeList(quota.limits)
            guard writtenCaches[account.email] != data else { continue }
            writtenCaches[account.email] = data
            EbbPaths.writeCache(data, to: EbbPaths.usageCache(for: account.email), date: quota.date)
        }
    }

    // MARK: - Providers

    private func runNextProviderJob(usageMinimumAge: TimeInterval) async {
        reloadAccounts()
        if let job = nextJob(usageMinimumAge: usageMinimumAge) { await run(job) }
    }

    /// Plan checks come first, since an account without a known plan can't be weighed.
    private func nextJob(usageMinimumAge: TimeInterval) -> Job? {
        let now = Date.now
        let profileDue = accounts.values
            .filter { account in
                if let retry = profileStates[account.email]?.retryNotBefore, retry > now { return false }
                if profileRequested.contains(account.email) { return true }
                let plan = plans[account.email]
                return ProfilePlan.isDue(lastCheck: plan?.date, plan: plan?.value, isRetired: isDisabled(account), now: now)
            }
            .map(\.email)
            .min()
        if let profileDue { return .profile(profileDue) }

        let eligible = usageStates.filter { isUsageEligible($0.key, now: now) }
        return RefreshPlan.nextAccount(in: eligible, minimumAge: usageMinimumAge, now: now).map(Job.usage)
    }

    /// Idle, paying, enabled accounts: the proxy has no recent headers for them.
    private func isUsageEligible(_ email: String, now: Date) -> Bool {
        guard let account = accounts[email], !isDisabled(account), case .paid = plans[email]?.value else { return false }
        return !ReadingChoice.hasFreshSignals(signals(for: account), now: now)
    }

    private func run(_ job: Job) async {
        guard await waitForProviderSlot() else { return }
        switch job {
        case let .usage(email): await readUsage(email)
        case let .profile(email): await checkPlan(email)
        }
        recompute()
    }

    private func isProviderSlotFree(at now: Date) -> Bool {
        guard let lastProviderRequest else { return true }
        return now.timeIntervalSince(lastProviderRequest) >= RefreshPlan.minimumSpacing
    }

    /// Returns false when the wait was cancelled because the item was hidden.
    private func waitForProviderSlot() async -> Bool {
        while let lastProviderRequest, !isProviderSlotFree(at: .now) {
            let wait = RefreshPlan.minimumSpacing - Date.now.timeIntervalSince(lastProviderRequest)
            guard (try? await Task.sleep(for: .seconds(wait))) != nil else { return false }
        }
        return !Task.isCancelled
    }

    private func readUsage(_ email: String) async {
        // Another trigger may have read this account while we waited.
        if let last = usageStates[email]?.lastAttempt, Date.now.timeIntervalSince(last) < RefreshPlan.minimumSpacing { return }
        // The proxy may have refreshed the token while we waited, too.
        guard let account = loadAccounts()[email] else { return }

        lastProviderRequest = .now
        usageStates[email, default: FetchState()].lastAttempt = .now
        let result = await accountClient.fetchUsage(account)
        switch result {
        case let .success(limits, cacheData):
            usageReadings[email] = DatedLimits(limits: limits, date: .now)
            usageStates[email]?.failures = 0
            usageStates[email]?.retryNotBefore = nil
            writtenCaches[email] = cacheData
            EbbPaths.writeCache(cacheData, to: EbbPaths.usageCache(for: email))
        case let .failed(_, retryAfter):
            Self.backOff(&usageStates, email, retryAfter: retryAfter)
            if result.isAuthFailure { profileRequested.insert(email) }
        }
    }

    private func checkPlan(_ email: String) async {
        if let last = profileStates[email]?.lastAttempt, Date.now.timeIntervalSince(last) < RefreshPlan.minimumSpacing { return }
        guard let account = loadAccounts()[email] else { return }

        lastProviderRequest = .now
        profileStates[email, default: FetchState()].lastAttempt = .now
        profileRequested.remove(email)
        switch await accountClient.fetchPlan(account) {
        case let .success(profile, cacheData):
            plans[email] = Dated(value: profile.plan, date: .now)
            profileStates[email]?.failures = 0
            profileStates[email]?.retryNotBefore = nil
            EbbPaths.writeCache(cacheData, to: EbbPaths.planCache(for: email))
            let streak = profile.plan == .inactive ? inactiveStreaks[email, default: 0] + 1 : 0
            inactiveStreaks[email] = streak
            await applyRetirement(to: account, plan: profile.plan, inactiveStreak: streak)
        case let .failed(_, retryAfter):
            Self.backOff(&profileStates, email, retryAfter: retryAfter)
        }
    }

    /// Disables a login whose plan ended, or re-enables one we disabled, through the proxy.
    /// Recorded only after the proxy accepts, so the list never claims an account we didn't touch.
    private func applyRetirement(to account: ProxyAccount, plan: Plan, inactiveStreak: Int) async {
        guard proxyFiles[account.name] != nil else { return }
        let action = Retirement.action(
            isDisabled: isDisabled(account),
            isRetiredByUs: retired.contains(account.name),
            plan: plan,
            inactiveStreak: inactiveStreak
        )
        guard action != .keep, let endpoint = connection.endpoint,
              await proxy.setDisabled(action == .retire, for: account.name, endpoint)
        else { return }
        proxyFiles[account.name]?.isDisabled = action == .retire
        try? EbbPaths.retiredAccounts.record(action, name: account.name)
        reloadAccounts()
    }

    private static func backOff(_ states: inout [String: FetchState], _ email: String, retryAfter: TimeInterval?) {
        var state = states[email] ?? FetchState()
        state.failures += 1
        state.retryNotBefore = .now + Backoff.delay(afterFailures: state.failures, retryAfter: retryAfter)
        states[email] = state
    }

    // MARK: - State

    private func isDisabled(_ account: ProxyAccount) -> Bool {
        proxyFiles[account.name]?.isDisabled ?? account.isDisabledInFile
    }

    private func signals(for account: ProxyAccount) -> DatedLimits? {
        proxyFiles[account.name]?.quota
    }

    private func reading(for account: ProxyAccount, at now: Date) -> [UsageLimit]? {
        ReadingChoice.best(signals: signals(for: account), usage: usageReadings[account.email], now: now)
    }

    private func readingSource(for account: ProxyAccount, at now: Date) -> ReadingChoice.Choice? {
        ReadingChoice.choose(signals: signals(for: account), usage: usageReadings[account.email], now: now)
    }

    /// Accounts on disk by email; when a login is duplicated, the enabled file wins.
    private func loadAccounts() -> [String: ProxyAccount] {
        Dictionary(ProxyAccount.loadAll(in: connection.authDirectory).map { ($0.email, $0) }) { first, second in
            first.isDisabledInFile ? second : first
        }
    }

    /// Picks up logins added with `cliproxyapi -claude-login`, drops deleted ones,
    /// and leaves out logins the user disabled by hand.
    private func reloadAccounts() {
        retired = EbbPaths.retiredAccounts.load()
        let all = loadAccounts()
        accounts = all.filter { _, account in !isDisabled(account) || retired.contains(account.name) }
        disabledByUser = all.values.filter { accounts[$0.email] == nil }
        for email in accounts.keys where usageStates[email] == nil {
            usageStates[email] = FetchState()
        }
        usageStates = usageStates.filter { accounts[$0.key] != nil }
        profileStates = profileStates.filter { accounts[$0.key] != nil }
        usageReadings = usageReadings.filter { accounts[$0.key] != nil }
        plans = plans.filter { accounts[$0.key] != nil }
    }

    /// Seeds from the shared cache so a relaunch shows numbers at once
    /// and does not re-read accounts that were read moments ago.
    private func loadCaches() {
        for email in accounts.keys {
            if let (data, modified) = EbbPaths.readCache(EbbPaths.usageCache(for: email)),
               let limits = try? UsageLimit.decodeList(from: data) {
                usageReadings[email] = DatedLimits(limits: limits, date: modified)
                usageStates[email]?.lastAttempt = modified
                writtenCaches[email] = data
            }
            if let (data, modified) = EbbPaths.readCache(EbbPaths.planCache(for: email)),
               let profile = try? JSONDecoder().decode(PlanProfile.self, from: data) {
                plans[email] = Dated(value: profile.plan, date: modified)
            }
        }
    }

    private func recompute() {
        let now = Date.now
        let members = accounts.values.filter { !isDisabled($0) }.map { account in
            PoolMember(plan: plans[account.email]?.value, signals: signals(for: account), usage: usageReadings[account.email])
        }
        let next = Pool.summarize(PoolMember.poolInput(members, now: now), at: now)
        if next != summary { summary = next }

        let details = makeDetails(at: now)
        if details != accountDetails { accountDetails = details }
        let usageAPIDate = accounts.values
            .filter { !isDisabled($0) }
            .compactMap { readingSource(for: $0, at: now) }
            .filter { $0.source == .usageAPI }
            .map(\.reading.date)
            .max()
        if usageAPIDate != usageAPIReadAt { usageAPIReadAt = usageAPIDate }
    }

    private func makeDetails(at now: Date) -> [AccountDetail] {
        let enabledWeights = Dictionary(accounts.values.filter { !isDisabled($0) }.compactMap { account in
            proxyFiles[account.name]?.weight.map { (account.email, $0) }
        }) { first, _ in first }
        let shares = ProxyWeight.shares(enabledWeights)
        let rows = accounts.values.map { account -> AccountDetail in
            let plan = plans[account.email]?.value
            guard !isDisabled(account) else {
                return AccountDetail(email: account.email, plan: plan, status: .retired)
            }
            let reading = readingSource(for: account, at: now)
            let limits = reading?.reading.limits ?? []
            let free = { (kind: UsageLimit.Kind) in limits.first { $0.kind == kind }.map { 100 - $0.used(at: now) } }
            let isCounted = reading?.isFresh == true && plan.map { if case .paid = $0 { true } else { false } } == true
            return AccountDetail(
                email: account.email,
                plan: plan,
                status: isCounted ? .active : .stale,
                sessionFree: reading == nil ? nil : free(.session) ?? 100,
                weeklyFree: free(.weeklyAll),
                share: shares[account.email],
                readAt: reading?.reading.date
            )
        }
        let userDisabled = disabledByUser.map { AccountDetail(email: $0.email, plan: plans[$0.email]?.value, status: .disabledByUser) }
        return (rows + userDisabled).sorted { $0.label < $1.label }
    }
}
