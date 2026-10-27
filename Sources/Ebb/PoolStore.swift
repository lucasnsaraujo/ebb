import Foundation
import Observation
import EbbCore

/// What the panel and the menu bar show: one pool per provider, never blended.
struct PoolState: Equatable {
    var summaries: [String: PoolSummary] = [:]
    /// Every login, for the accounts panel: the only place accounts appear.
    var details: [AccountDetail] = []
    /// Providers with usage windows and at least one enabled login, in `Providers.all` order.
    var providers: [String] = []
    /// The provider with the most pooled weight.
    var defaultProvider: String?
    /// The newest usage-API reading per provider, among logins that rely on one.
    var usageAPIReadAt: [String: Date] = [:]
    var forecasts: [String: PoolForecast] = [:]
}


/// Keeps the pools fresh while the menu bar item is visible.
///
/// CLIProxyAPI's management API is the main source: free, polled every 30 s, carrying the
/// quota signals of each login's latest real response. Providers are asked only for idle
/// logins and plan checks, one request at a time and at least a minute apart: Claude directly
/// with the login's token from the proxy's folder, the others through the proxy's `api-call`,
/// which holds the token. With a proxy on another machine, Claude goes through `api-call` too.
@MainActor
@Observable
final class PoolStore {
    static let proxyInterval: Duration = .seconds(30)
    static let providerInterval: Duration = .seconds(RefreshPlan.minimumSpacing)
    /// Opening the panel re-reads an idle account whose reading is older than this.
    static let staleOnOpen: TimeInterval = 2 * 60

    /// An `api-call` login whose token was refused is tried again after this long.
    static let rejectedTokenRetry: TimeInterval = 6 * 60 * 60
    /// Each call to `muse-code/key` also mints a key, so Meta logins are read at most hourly.
    static let callMinimumAge: [String: TimeInterval] = [MetaProvider().proxyName: 60 * 60]

    private(set) var state = PoolState()
    /// When the proxy last answered; `nil` while it's unreachable.
    private(set) var proxyReadAt: Date?
    /// Why the last poll came back empty; `nil` until a poll has failed.
    private(set) var proxyFailure: ProxyOutage.Failure?
    private(set) var isRefreshing = false
    /// The login reset urgency raises most, for Settings → Routing.
    private(set) var strongestUrgency: UrgentLogin?

    private struct Dated<Value> {
        var value: Value
        var date: Date
    }

    private enum Job {
        case usage(String)
        case profile(String)
        /// A usage read through `api-call`, by auth file name.
        case call(String)
        /// A plan check through `api-call`, for Claude logins of a remote proxy.
        case planCall(String)
    }

    private enum CallKind {
        case usage, plan
    }

    @ObservationIgnored private let accountClient = AccountClient()
    @ObservationIgnored private let proxy = ProxyClient()
    @ObservationIgnored private let connection: ProxyConnection
    /// Never touches the network; shows cached numbers only.
    let isOffline: Bool
    /// By email. Accounts the user disabled by hand are left out of everything but the panel.
    @ObservationIgnored private var accounts: [String: ProxyAccount] = [:]
    @ObservationIgnored private var disabledByUser: [ProxyAccount] = []
    @ObservationIgnored private var managementLockout = ManagementLockout()
    @ObservationIgnored private var seenKeyAcceptances = 0
    /// The proxy's latest listing by auth file name. Kept while it's unreachable, so the numbers
    /// last read stay on show, dimmed by their age; weights aren't synced from it meanwhile.
    @ObservationIgnored private var proxyFiles: [String: ProxyAuthFile] = [:]
    @ObservationIgnored private var retired: Set<String> = []
    @ObservationIgnored private var usageReadings: [String: DatedLimits] = [:]
    @ObservationIgnored private var plans: [String: Dated<Plan>] = [:]
    @ObservationIgnored private var usageStates: [String: FetchState] = [:]
    @ObservationIgnored private var profileStates: [String: FetchState] = [:]
    /// Accounts whose token was refused; their plan is checked next.
    @ObservationIgnored private var profileRequested: Set<String> = []
    @ObservationIgnored private var inactiveStreaks: [String: Int] = [:]
    /// Claude tiers by email, for weight overrides.
    @ObservationIgnored private var tiers: [String: String] = [:]
    /// `api-call` logins, by auth file name.
    @ObservationIgnored private var callReadings: [String: DatedLimits] = [:]
    @ObservationIgnored private var callPlans: [String: String] = [:]
    @ObservationIgnored private var callStates: [String: FetchState] = [:]
    @ObservationIgnored private var callPlanStates: [String: FetchState] = [:]
    @ObservationIgnored private var rejectedTokens: Set<String> = []
    /// Logins whose provider said their subscription ended.
    @ObservationIgnored private var endedSubscriptions: Set<String> = []
    @ObservationIgnored private var callInactiveStreaks: [String: Int] = [:]
    @ObservationIgnored private var writtenCaches: [String: Data] = [:]
    /// The pools as last saved for the `ebb` command.
    @ObservationIgnored private var savedStatus: PoolStatus?
    /// Kept across launches, so a relaunch never sends two requests back to back.
    @ObservationIgnored private var lastProviderRequest = UserDefaults.standard.object(forKey: "lastProviderRequest") as? Date {
        didSet { UserDefaults.standard.set(lastProviderRequest, forKey: "lastProviderRequest") }
    }
    @ObservationIgnored private var isPollingProxy = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var ledger = DemandLedger()
    @ObservationIgnored private var alertTracker = UserDefaults.standard.data(forKey: PoolStore.alertTrackerKey)
        .flatMap { try? JSONDecoder().decode(AlertTracker.self, from: $0) } ?? AlertTracker()
    /// Made on the first alert, so a snapshot or demo never touches UserNotifications.
    @ObservationIgnored private var alertDelivery: AlertDelivery?
    private static let alertTrackerKey = "alertTracker"
    @ObservationIgnored private var expiryNudge = UserDefaults.standard.data(forKey: PoolStore.expiryNudgeKey)
        .flatMap { try? JSONDecoder().decode(ExpiryNudge.self, from: $0) } ?? ExpiryNudge()
    private static let expiryNudgeKey = "expiryNudge"
    @ObservationIgnored private var membership = UserDefaults.standard.data(forKey: PoolStore.membershipKey)
        .flatMap { try? JSONDecoder().decode(MembershipTracker.self, from: $0) } ?? MembershipTracker()
    static let membershipKey = "poolMembership"
    /// Each pool's public status while it has a problem; empty while all is well or unknown.
    private(set) var incidents: [String: ServiceHealth] = [:]
    @ObservationIgnored private var statusPageReads = StatusPageReads()
    @ObservationIgnored private var incidentTracker = UserDefaults.standard.data(forKey: PoolStore.incidentTrackerKey)
        .flatMap { try? JSONDecoder().decode(IncidentTracker.self, from: $0) } ?? IncidentTracker()
    @ObservationIgnored private var incidentDelivery: AlertDelivery?
    private static let incidentTrackerKey = "incidentTracker"
    @ObservationIgnored private var ledgerSavedAt = Date.now
    /// Written at most this often while polling, and when Ebb hides or quits.
    static let ledgerSaveInterval: TimeInterval = 5 * 60

    /// Set for fixed numbers that never change: `--snapshot` renders.
    @ObservationIgnored private let isFixed: Bool
    /// Off for offline and snapshot runs, so only the running app writes what the `ebb` command reads.
    @ObservationIgnored private let savesStatus: Bool

    /// `isOffline` shows cached numbers only; used for screenshots and UI work.
    init(connection: ProxyConnection, isOffline: Bool = false, savesStatus: Bool = true) {
        self.connection = connection
        self.isOffline = isOffline
        self.savesStatus = savesStatus && !isOffline
        isFixed = false
        if let data = try? Data(contentsOf: EbbPaths.demandFile) { ledger = DemandLedger.load(from: data) }
        reloadAccounts()
        loadCaches()
        recompute()
    }

    /// Shows the given numbers and never reads anything: `--demo` and `--snapshot`.
    init(connection: ProxyConnection, state: PoolState, proxyReadAt: Date?, proxyFailure: ProxyOutage.Failure? = nil, strongestUrgency: UrgentLogin? = nil, incidents: [String: ServiceHealth] = [:]) {
        self.connection = connection
        isOffline = false
        isFixed = true
        savesStatus = false
        self.state = state
        self.proxyReadAt = proxyReadAt
        self.proxyFailure = proxyFailure
        self.strongestUrgency = strongestUrgency
        self.incidents = incidents
    }

    /// A fixed Claude-only pool.
    convenience init(connection: ProxyConnection, summary: PoolSummary?, details: [AccountDetail], proxyReadAt: Date?) {
        let claude = ClaudeProvider().proxyName
        let state = PoolState(summaries: summary.map { [claude: $0] } ?? [:], details: details, providers: [claude], defaultProvider: claude)
        self.init(connection: connection, state: state, proxyReadAt: proxyReadAt)
    }

    /// The management key is set but the proxy didn't answer its last poll.
    var isProxyUnreachable: Bool {
        connection.endpoint != nil && proxyReadAt == nil
    }

    /// What the panel says about a proxy that didn't answer; `.none` until a poll has failed.
    var outageAdvice: ProxyOutage.Advice {
        ProxyOutage.advice(
            failure: proxyFailure, isRemote: connection.isRemote, host: connection.baseURL.host() ?? "",
            install: connection.install, configFile: connection.configFile?.path
        )
    }

    /// Ebb's own retirements on the proxy in use; a remote proxy keeps its own list.
    private var retiredAccounts: RetiredAccounts {
        EbbPaths.retiredAccounts(remoteHost: connection.isRemote ? connection.baseURL.host() : nil)
    }

    /// The pool the menu bar shows: the provider chosen in Settings while it has logins, else the default.
    func menuBarProvider(choice: String) -> String? {
        state.providers.contains(choice) ? choice : state.defaultProvider ?? state.providers.first
    }

    /// Starts or stops all network activity, localhost included.
    func setActive(_ isActive: Bool) {
        loops.forEach { $0.cancel() }
        loops = []
        if !isActive { saveLedger() }
        recompute()
        guard isActive, !isOffline, !isFixed else { return }
        loops = [
            Task { await repeatEvery(Self.proxyInterval, named: "proxy poll") { await $0.pollProxy() } },
            Task { await repeatEvery(Self.providerInterval, named: "provider read") { await $0.runNextProviderJob(usageMinimumAge: RefreshPlan.period - 30) } },
            // Checked each minute, read at most every five, so showing and hiding the item never adds reads.
            Task { await repeatEvery(.seconds(60), named: "status pages") { await $0.readStatusPagesIfDue() } },
        ]
    }

    // MARK: - Status pages

    private func readStatusPagesIfDue() async {
        var alerts: [PoolAlert] = []
        for provider in statusPageReads.due(state.providers, now: .now) {
            guard let page = StatusPage.forProvider(provider) else { continue }
            let request = URLRequest(url: page.summaryURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let result = try? await Transport.statusPages.data(for: request)
            // Hidden mid-read: the read didn't happen, so it isn't recorded.
            guard !Task.isCancelled else { return }
            let health = result.flatMap { data, response in
                (response as? HTTPURLResponse)?.statusCode == 200 ? page.health(from: data) : nil
            }
            statusPageReads.record(provider, health: health, now: .now)
            if let health {
                alerts += incidentTracker.alerts(provider: provider, title: ProviderDisplay.title(provider), health: health, now: .now)
            }
        }
        if statusPageReads.incidents != incidents { incidents = statusPageReads.incidents }
        UserDefaults.standard.set(try? JSONEncoder().encode(incidentTracker), forKey: Self.incidentTrackerKey)
        await incidentAlerts.deliver(alerts)
    }

    private var incidentAlerts: AlertDelivery {
        if let incidentDelivery { return incidentDelivery }
        let notifier: any Notifier = Bundle.main.bundleURL.pathExtension == "app" ? SystemNotifier() : SilentNotifier()
        let delivery = AlertDelivery(notifier: notifier, isEnabled: { AlertSettings.sendsIncidentAlerts })
        incidentDelivery = delivery
        return delivery
    }

    /// The user turned incident alerts on in Settings: asks for permission now.
    func enableIncidentAlerts() async -> Bool {
        await incidentAlerts.enable()
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

    /// The Mac woke: once the network is back, polls the proxy and re-reads the one account whose
    /// reading went stale longest ago. The loops fire on wake too, so this adds at most one request.
    func didWake() {
        guard !loops.isEmpty else { return }
        diagnostics.record("Woke from sleep")
        Task {
            try? await Task.sleep(for: .seconds(WakeRefresh.networkDelay))
            guard !loops.isEmpty else { return }
            await pollProxy()
            if let job = nextJobOnWake() { await run(job) }
        }
    }

    /// The user just started the proxy: polls again in a few seconds, and once more if it's
    /// still coming up, rather than waiting the loop's half minute.
    func proxyWasStarted() {
        guard !loops.isEmpty else { return }
        Task {
            for delay in [3, 5] where proxyReadAt == nil {
                try? await Task.sleep(for: .seconds(delay))
                await pollProxy()
            }
        }
    }

    /// Settings changed a plan weight: the pools re-weigh at once, the proxy on its next poll.
    func weightsDidChange() {
        recompute()
    }

    /// Settings pointed Ebb at another proxy: the logins folder may be out of reach now, or back.
    func connectionDidChange() {
        managementLockout = ManagementLockout()
        proxyFiles = [:]
        proxyReadAt = nil
        proxyFailure = nil
        // Another proxy has other logins, and a Claude login goes by email here but by file name
        // through a remote proxy: the next listing is a baseline, not a wave of joins.
        membership = MembershipTracker()
        saveAlertTracker()
        callStates = [:]
        callPlanStates = [:]
        callReadings = [:]
        callPlans = [:]
        // A login of the same name on the other proxy starts with no evidence against its plan.
        inactiveStreaks = [:]
        callInactiveStreaks = [:]
        endedSubscriptions = []
        rejectedTokens = []
        reloadAccounts()
        loadCaches()
        recompute()
        guard !loops.isEmpty else { return }
        Task { await pollProxy() }
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

    private func repeatEvery(_ interval: Duration, named name: String, _ step: (PoolStore) async -> Void) async {
        while !Task.isCancelled {
            Budget.wake(name)
            await step(self)
            try? await Task.sleep(for: interval)
        }
    }

    // MARK: - Proxy

    /// One read of the proxy's listing, without provider requests or weight changes: `--snapshot --live`.
    func readProxyOnce() async {
        await pollProxy(syncsWeights: false)
    }

    private func pollProxy(syncsWeights: Bool = true) async {
        guard !isPollingProxy else { return }
        isPollingProxy = true
        defer { isPollingProxy = false }

        let wasReachable = proxyReadAt != nil
        let endpoint = connection.endpoint
        // A refused key isn't sent again until the proxy's lockout would have ended; the last answer stands meanwhile.
        // Settings or the setup steps checked the key and the proxy took it: no reason to wait any longer.
        if connection.keyAcceptances != seenKeyAcceptances {
            seenKeyAcceptances = connection.keyAcceptances
            managementLockout.noteAccepted()
        }
        let isPaused = endpoint.map { !managementLockout.allowsRequest(with: $0.key, now: .now) } ?? false
        if !isPaused {
            let listing: ProxyClient.Listing? = if let endpoint { await proxy.authFiles(endpoint) } else { nil }
            switch listing {
            case let .files(files, version):
                managementLockout.noteAccepted()
                proxyFiles = Dictionary(files.map { ($0.name, $0) }) { first, _ in first }
                proxyReadAt = .now
                proxyFailure = nil
                connection.noteProxyVersion(version)
                try? retiredAccounts.forget(allBut: Set(files.filter(\.isDisabled).map(\.name)))
                if !wasReachable {
                    diagnostics.record("Proxy answered: \(files.count) logins, version \(version ?? "unknown")")
                    // A key checked while the proxy was down stays "unreachable" in Settings until it's checked again.
                    if connection.keyState == .unreachable { await connection.test() }
                }
            case let .refused(version, status, message):
                connection.noteProxyVersion(version)
                connection.noteKeyRefused()
                if let endpoint { managementLockout.noteRefusal(of: endpoint.key, status: status, message: message, now: .now) }
                if wasReachable || proxyFailure != .refused {
                    let isPausing = endpoint.map { !managementLockout.allowsRequest(with: $0.key, now: .now) } ?? false
                    diagnostics.record(managementLockout.isBanned(now: .now)
                        ? "Proxy locked this Mac out after too many wrong keys; asking again when that ends"
                        : isPausing ? "Proxy refused the key; asking again in 31 min, before its lockout could start" : "Proxy refused the request: \(message)")
                }
                proxyReadAt = nil
                proxyFailure = .refused
            case .unreachable:
                if wasReachable || proxyFailure != .unreachable { diagnostics.record("Proxy poll failed: no answer") }
                proxyReadAt = nil
                proxyFailure = .unreachable
            case nil:
                proxyFiles = [:]
                proxyReadAt = nil
                proxyFailure = nil
            }
        }
        reloadAccounts()
        writeSignalCaches()
        ledger.heartbeat(at: .now)
        recompute()
        if Date.now.timeIntervalSince(ledgerSavedAt) >= Self.ledgerSaveInterval { saveLedger() }
        if syncsWeights, proxyReadAt != nil { await syncProxyWeights() }
    }

    /// Never from a snapshot or demo, which must leave the user's files alone.
    func saveLedger() {
        guard !isFixed, !isOffline, LaunchOptions.snapshotDirectory == nil else { return }
        ledgerSavedAt = .now
        try? FileManager.default.createDirectory(at: EbbPaths.applicationSupport, withIntermediateDirectories: true)
        try? ledger.encoded().write(to: EbbPaths.demandFile, options: .atomic)
        saveAlertTracker()
    }

    private func saveAlertTracker() {
        UserDefaults.standard.set(try? JSONEncoder().encode(alertTracker), forKey: Self.alertTrackerKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(expiryNudge), forKey: Self.expiryNudgeKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(membership), forKey: Self.membershipKey)
    }

    private var delivery: AlertDelivery {
        if let alertDelivery { return alertDelivery }
        let notifier: any Notifier = Bundle.main.bundleURL.pathExtension == "app" ? SystemNotifier() : SilentNotifier()
        let delivery = AlertDelivery(notifier: notifier, isEnabled: { AlertSettings.isEnabled })
        alertDelivery = delivery
        return delivery
    }

    /// The user turned alerts on in Settings: asks for permission now. False when they can't show.
    func enableAlerts() async -> Bool {
        await delivery.enable()
    }

    /// Steers new threads toward free capacity: weight = what's left in the window that binds × reset urgency.
    private func syncProxyWeights() async {
        guard RoutingSettings.balancesSessions, let endpoint = connection.endpoint else {
            if strongestUrgency != nil { strongestUrgency = nil }
            return
        }
        let now = Date.now
        var logins: [(name: String, provider: String, planWeight: PlanWeight, limits: [UsageLimit], weight: Int?)] = []
        for account in accounts.values where !isDisabled(account) {
            guard case let .paid(planWeight) = claudePlan(account.email),
                  let listed = proxyFiles[account.name],
                  let limits = reading(for: account, at: now)
            else { continue }
            logins.append((account.name, ClaudeProvider().proxyName, planWeight, limits, listed.weight))
        }
        // The proxy's weighted round robin only weighs logins of one provider against each
        // other (its state key is provider and model), so each provider's plan scale stands alone.
        for file in listedFiles where file.hasUsageWindows && !file.isDisabled {
            guard case let .paid(planWeight) = plan(for: file),
                  let limits = ReadingChoice.best(signals: file.quota, usage: callReadings[file.name], now: now)
            else { continue }
            logins.append((file.name, file.provider, planWeight, limits, file.weight))
        }
        var urgent: [UrgentLogin] = []
        for login in logins {
            let resetsAt = ResetUrgency.weeklyReset(in: login.limits)
            let urgency = ResetUrgency.factor(weeklyResetsAt: resetsAt, now: now)
            urgent.append(UrgentLogin(provider: ProviderDisplay.title(login.provider), freePercent: Pool.effectiveFree(login.limits, at: now), factor: urgency, weeklyResetsAt: resetsAt))
            let target = ProxyWeight.target(login.planWeight, limits: login.limits, provider: login.provider, at: now)
            guard ProxyWeight.needsUpdate(current: login.weight, target: target) else { continue }
            if await proxy.setWeight(target, for: login.name, endpoint) {
                proxyFiles[login.name]?.weight = target
            }
        }
        let strongest = UrgentLogin.strongest(urgent)
        if strongest != strongestUrgency { strongestUrgency = strongest }
    }

    /// Keeps the cache current from proxy headers, so a relaunch shows numbers without extra requests.
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
        if let planCheck = planCheckDue(now: now) { return planCheck }
        let reads = eligibleReads(minimumAge: usageMinimumAge, now: now)
        return RefreshPlan.nextAccount(in: reads, minimumAge: usageMinimumAge, now: now).map(Self.job)
    }

    /// The wake's one read, if any. Never a plan check: the loop gets to those within the minute.
    private func nextJobOnWake() -> Job? {
        let now = Date.now
        let reads = eligibleReads(minimumAge: WakeRefresh.staleAge, now: now)
        return WakeRefresh.account(in: reads, lastRequest: lastProviderRequest, now: now).map(Self.job)
    }

    private func planCheckDue(now: Date) -> Job? {
        let direct = accounts.values
            .filter { account in
                if let retry = profileStates[account.email]?.retryNotBefore, retry > now { return false }
                if profileRequested.contains(account.email) { return true }
                let plan = plans[account.email]
                return ProfilePlan.isDue(lastCheck: plan?.date, plan: plan?.value, isRetired: isDisabled(account), now: now)
            }
            .map(\.email)
            .min()
        if let direct { return .profile(direct) }
        let listed = callPlanStates
            .filter { name, state in
                guard proxyReadAt != nil, let file = proxyFiles[name], !file.isDisabled || retired.contains(name) else { return false }
                if let retry = state.retryNotBefore, retry > now { return false }
                // An answer that named no tier still counts as checked, so it's asked again in hours, not minutes.
                let plan: Plan? = state.lastOutcome == .ok ? plan(for: file) : nil
                return ProfilePlan.isDue(lastCheck: state.lastAttempt, plan: plan, isRetired: file.isDisabled, now: now)
            }
            .keys
            .min()
        return listed.map(Job.planCall)
    }

    /// Claude usage reads and api-call reads share one queue: the account tried longest ago goes first.
    private func eligibleReads(minimumAge: TimeInterval, now: Date) -> [String: FetchState] {
        var eligible = Dictionary(uniqueKeysWithValues: usageStates.filter { isUsageEligible($0.key, now: now) }.map { ("usage:" + $0.key, $0.value) })
        for (name, callState) in callStates where isCallEligible(name, minimumAge: minimumAge, now: now) {
            eligible["call:" + name] = callState
        }
        return eligible
    }

    private static func job(forKey key: String) -> Job {
        key.hasPrefix("call:") ? .call(String(key.dropFirst(5))) : .usage(String(key.dropFirst(6)))
    }

    /// Idle logins with a usage call, each read at most every five minutes whatever asks;
    /// retired ones are re-read daily, ended ones after the confirmation interval, Meta at most hourly.
    private func isCallEligible(_ name: String, minimumAge: TimeInterval, now: Date) -> Bool {
        guard connection.endpoint != nil, proxyReadAt != nil, let file = proxyFiles[name],
              let provider = Providers.named(file.provider), provider.usageCall(for: file) != nil,
              !file.isDisabled || retired.contains(name),
              !ReadingChoice.hasFreshSignals(file.quota, now: now)
        else { return false }
        guard let last = callStates[name]?.lastAttempt else { return true }
        let age = if file.isDisabled {
            ProfilePlan.retiredInterval
        } else if endedSubscriptions.contains(name) {
            max(ProfilePlan.confirmationInterval, Self.callMinimumAge[file.provider] ?? 0)
        } else {
            max(minimumAge, RefreshPlan.period, Self.callMinimumAge[file.provider] ?? 0)
        }
        return now.timeIntervalSince(last) >= age
    }

    /// Idle, paying, enabled accounts: the proxy has no recent headers for them.
    private func isUsageEligible(_ email: String, now: Date) -> Bool {
        guard let account = accounts[email], !isDisabled(account), case .paid = plans[email]?.value else { return false }
        return !ReadingChoice.hasFreshSignals(signals(for: account), now: now)
    }

    private func run(_ job: Job) async {
        let chosenAt = Date.now
        guard await waitForProviderSlot() else { return }
        switch job {
        case let .usage(email): await readUsage(email, chosenAt: chosenAt)
        case let .profile(email): await checkPlan(email, chosenAt: chosenAt)
        case let .call(name): await readThroughProxy(name, kind: .usage, chosenAt: chosenAt)
        case let .planCall(name): await readThroughProxy(name, kind: .plan, chosenAt: chosenAt)
        }
        recompute()
    }

    private func isProviderSlotFree(at now: Date) -> Bool {
        RefreshPlan.isSlotFree(lastRequest: lastProviderRequest, now: now)
    }

    /// Returns false when the wait was cancelled because the item was hidden.
    private func waitForProviderSlot() async -> Bool {
        while let lastProviderRequest, !isProviderSlotFree(at: .now) {
            let wait = RefreshPlan.minimumSpacing - Date.now.timeIntervalSince(lastProviderRequest)
            guard (try? await Task.sleep(for: .seconds(wait))) != nil else { return false }
            Budget.wake("provider slot")
        }
        return !Task.isCancelled
    }

    private func readUsage(_ email: String, chosenAt: Date) async {
        // Another trigger may have read this account while we waited.
        guard RefreshPlan.isStillDue(usageStates[email], chosenAt: chosenAt) else { return }
        // The proxy may have refreshed the token while we waited, too.
        guard let account = loadAccounts()[email] else { return }

        lastProviderRequest = .now
        usageStates[email, default: FetchState()].lastAttempt = .now
        let result = await accountClient.fetchUsage(account)
        usageStates[email]?.lastOutcome = result.outcome
        diagnostics.record("\(diagnosticLabel(email: email)) usage: \(result.outcome.rawValue)")
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

    private func checkPlan(_ email: String, chosenAt: Date) async {
        guard RefreshPlan.isStillDue(profileStates[email], chosenAt: chosenAt) else { return }
        guard let account = loadAccounts()[email] else { return }

        lastProviderRequest = .now
        profileStates[email, default: FetchState()].lastAttempt = .now
        profileRequested.remove(email)
        let result = await accountClient.fetchPlan(account)
        profileStates[email]?.lastOutcome = result.outcome
        diagnostics.record("\(diagnosticLabel(email: email)) plan: \(result.outcome.rawValue)")
        switch result {
        case let .success(profile, cacheData):
            plans[email] = Dated(value: profile.plan, date: .now)
            // A lapsed profile names no useful tier; the last paid one still names the retired login.
            if profile.plan != .inactive { tiers[email] = profile.tier }
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

    /// One usage or plan read through the proxy. A refused token shows "Limits not available" and
    /// waits hours before the next try; it never touches the plan or retires the login.
    private func readThroughProxy(_ name: String, kind: CallKind, chosenAt: Date) async {
        let states = kind == .usage ? \PoolStore.callStates : \PoolStore.callPlanStates
        guard RefreshPlan.isStillDue(self[keyPath: states][name], chosenAt: chosenAt) else { return }
        guard let endpoint = connection.endpoint, let file = proxyFiles[name],
              let provider = Providers.named(file.provider),
              let call = kind == .usage ? provider.usageCall(for: file) : provider.planCall(for: file)
        else { return }

        lastProviderRequest = .now
        self[keyPath: states][name, default: FetchState()].lastAttempt = .now
        let parse = kind == .usage ? provider.readUsageCall : provider.readPlanCall
        let outcome = await proxy.apiCall(call, endpoint)
            .map { CallOutcome.read(proxyStatus: $0.status, body: $0.body, now: .now, parse: parse) } ?? .failed
        self[keyPath: states][name]?.lastOutcome = outcome.requestOutcome
        diagnostics.record("\(diagnosticLabel(provider: file.provider, name: name)) \(kind == .usage ? "usage" : "plan"): \(outcome.requestOutcome.rawValue)")
        switch outcome {
        case let .reading(reading):
            if let limits = reading.limits { callReadings[name] = DatedLimits(limits: limits, date: .now) }
            if let plan = reading.planName { callPlans[name] = plan }
            rejectedTokens.remove(name)
            self[keyPath: states][name]?.failures = 0
            self[keyPath: states][name]?.retryNotBefore = nil
            // Where a plan call exists, it alone speaks for the subscription.
            guard kind == .plan || provider.planCall(for: file) == nil else { return }
            if reading.hasEndedSubscription { endedSubscriptions.insert(name) } else { endedSubscriptions.remove(name) }
            let streak = reading.hasEndedSubscription ? callInactiveStreaks[name, default: 0] + 1 : 0
            callInactiveStreaks[name] = streak
            // The listing may have changed during the call; a login disabled by hand meanwhile stays the user's.
            let isDisabled = proxyFiles[name]?.isDisabled ?? file.isDisabled
            let action = Retirement.action(after: outcome, isDisabled: isDisabled, isRetiredByUs: retired.contains(name), inactiveStreak: streak)
            await apply(action, toFileNamed: name)
        case .tokenRejected:
            rejectedTokens.insert(name)
            self[keyPath: states][name]?.retryNotBefore = .now + Self.rejectedTokenRetry
        case let .rateLimited(retryAfter):
            Self.backOff(&self[keyPath: states], name, retryAfter: retryAfter)
        case .failed:
            Self.backOff(&self[keyPath: states], name, retryAfter: nil)
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
        await apply(action, toFileNamed: account.name)
    }

    /// Recorded only after the proxy accepts, so the list never claims a login we didn't touch.
    private func apply(_ action: Retirement.Action, toFileNamed name: String) async {
        guard action != .keep, proxyFiles[name] != nil, let endpoint = connection.endpoint else { return }
        let accepted = await proxy.setDisabled(action == .retire, for: name, endpoint)
        if let member = rosterAccount(forFileNamed: name),
           let alert = membership.alert(after: action, accepted: accepted, pool: member.pool, title: ProviderDisplay.title(member.pool), account: member.account, now: .now) {
            saveAlertTracker()
            Task { await delivery.deliver([alert]) }
        }
        guard accepted else { return }
        proxyFiles[name]?.isDisabled = action == .retire
        try? retiredAccounts.record(action, name: name)
        reloadAccounts()
    }

    /// A login's pool and membership id, by auth file name: the email of a Claude login read from disk.
    private func rosterAccount(forFileNamed name: String) -> (pool: String, account: PoolRoster.Account)? {
        if let file = proxyFiles[name], file.isReadThroughProxy(isRemote: connection.isRemote) {
            return (file.provider, PoolRoster.Account(id: name, plan: planTitle(provider: file.provider, plan: callPlans[name] ?? file.planName)))
        }
        guard let account = accounts.values.first(where: { $0.name == name }) else { return nil }
        return (ClaudeProvider().proxyName, PoolRoster.Account(id: account.email, plan: claudePlanTitle(account.email)))
    }

    /// The plan's name for a membership alert, "Max 20x" or "Team"; `nil` for one the weight table doesn't name.
    private func planTitle(provider: String, plan: String?) -> String? {
        guard let plan = plan?.lowercased() else { return nil }
        return PlanWeights.defaults[provider]?.first { $0.plan == plan }?.title
    }

    private func claudePlanTitle(_ email: String) -> String? {
        planTitle(provider: ClaudeProvider().proxyName, plan: tiers[email].flatMap(ClaudeProvider.planName(rateLimitTier:)))
    }

    private static func backOff(_ states: inout [String: FetchState], _ email: String, retryAfter: TimeInterval?) {
        var state = states[email] ?? FetchState()
        state.failures += 1
        state.retryNotBefore = .now + Backoff.delay(afterFailures: state.failures, retryAfter: retryAfter)
        states[email] = state
    }

    // MARK: - Diagnostics

    private var diagnostics: DiagnosticLog { connection.diagnostics }

    /// Everything Copy Diagnostics puts on the pasteboard; see `Diagnostics` for what's left out.
    func diagnosticsText(now: Date = .now) -> String {
        let report = DiagnosticsReport(
            ebbVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            proxyVersion: connection.proxyVersion,
            connection: connectionDescription(now: now),
            routingStrategy: connection.routingStrategy,
            accounts: diagnosticAccounts(),
            log: diagnostics.entries,
            secrets: [connection.endpoint?.key.value].compactMap { $0 },
            pools: state.summaries
        )
        return Diagnostics.text(report, now: now)
    }

    private func connectionDescription(now: Date) -> String {
        guard connection.endpoint != nil else { return "no management key" }
        let mode = connection.isRemote ? "remote" : "local"
        if let proxyReadAt { return "\(mode), reachable, polled \(Int(now.timeIntervalSince(proxyReadAt)))s ago" }
        return "\(mode), " + (proxyFailure == .refused ? "refused the key" : "unreachable")
    }

    private func diagnosticAccounts() -> [DiagnosticAccount] {
        state.details.map { detail in
            let outcome = detail.fileName.flatMap { callStates[$0]?.lastOutcome }
                ?? usageStates[detail.email]?.lastOutcome ?? profileStates[detail.email]?.lastOutcome
            return DiagnosticAccount(provider: detail.provider, name: detail.fileName ?? detail.email, status: detail.status.diagnosticsName, readAt: detail.readAt, outcome: outcome)
        }
    }

    private func diagnosticLabel(email: String) -> String {
        diagnosticLabel(provider: ClaudeProvider().proxyName, name: email)
    }

    private func diagnosticLabel(provider: String, name: String) -> String {
        Diagnostics.label(provider: provider, name: name, among: diagnosticAccounts())
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
    /// None at all for a remote proxy, whose folder is on another machine.
    private func loadAccounts() -> [String: ProxyAccount] {
        guard let directory = connection.localAuthDirectory else { return [:] }
        return Dictionary(ProxyAccount.loadAll(in: directory).map { ($0.email, $0) }) { first, second in
            first.isDisabledInFile ? second : first
        }
    }

    /// Picks up logins added with `cliproxyapi -claude-login`, drops deleted ones,
    /// and leaves out logins the user disabled by hand.
    private func reloadAccounts() {
        retired = retiredAccounts.load()
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

        // Logins reached through `api-call` come from the proxy's listing alone.
        let callable = Set(listedFiles.filter { file in
            Providers.named(file.provider).map { $0.usageCall(for: file) != nil } ?? false
        }.map(\.name))
        let planCallable = Set(listedFiles.filter { file in
            Providers.named(file.provider).map { $0.planCall(for: file) != nil } ?? false
        }.map(\.name))
        for name in callable where callStates[name] == nil {
            callStates[name] = FetchState()
        }
        for name in planCallable where callPlanStates[name] == nil {
            callPlanStates[name] = FetchState()
        }
        guard !proxyFiles.isEmpty else { return }
        callStates = callStates.filter { callable.contains($0.key) }
        callPlanStates = callPlanStates.filter { planCallable.contains($0.key) }
        callReadings = callReadings.filter { callable.contains($0.key) }
        callPlans = callPlans.filter { callable.contains($0.key) }
        rejectedTokens = rejectedTokens.filter(callable.contains)
        endedSubscriptions = endedSubscriptions.filter(callable.contains)
    }

    /// Seeds from the cache so a relaunch shows numbers at once
    /// and does not re-read accounts that were read moments ago.
    private func loadCaches() {
        for email in accounts.keys {
            if savesStatus { EbbPaths.moveLegacyCaches(for: email) }
            if let (data, modified) = EbbPaths.readCache(EbbPaths.usageCache(for: email)),
               let limits = try? UsageLimit.decodeList(from: data) {
                usageReadings[email] = DatedLimits(limits: limits, date: modified)
                usageStates[email]?.lastAttempt = modified
                writtenCaches[email] = data
            }
            if let (data, modified) = EbbPaths.readCache(EbbPaths.planCache(for: email)),
               let profile = try? JSONDecoder().decode(PlanProfile.self, from: data) {
                plans[email] = Dated(value: profile.plan, date: modified)
                tiers[email] = profile.tier
            }
        }
    }

    /// Plan sizes the user set in Settings, by `PlanWeights.overrideKey`.
    private var weightOverrides: [String: Double] {
        PlanWeights.savedOverrides()
    }

    /// A Claude plan, resized by the user's override for its tier.
    private func claudePlan(_ email: String) -> Plan? {
        guard let plan = plans[email]?.value else { return nil }
        guard case .paid = plan, let tier = tiers[email],
              let weight = PlanWeights.weight(provider: ClaudeProvider().proxyName, plan: ClaudeProvider.planName(rateLimitTier: tier), overrides: weightOverrides)
        else { return plan }
        return .paid(weight: weight)
    }

    /// An `api-call` or signals login's plan: ended, sized from the weight table, or unknown.
    private func plan(for file: ProxyAuthFile) -> Plan {
        if endedSubscriptions.contains(file.name) { return .inactive }
        let name = callPlans[file.name] ?? file.planName
        return PlanWeights.weight(provider: file.provider, plan: name, overrides: weightOverrides).map { .paid(weight: $0) } ?? .unknown
    }

    /// Logins read through the proxy's listing: every provider but Claude, whose auth files
    /// Ebb reads itself, unless the proxy is on another machine.
    private var listedFiles: [ProxyAuthFile] {
        proxyFiles.values.filter { $0.isReadThroughProxy(isRemote: connection.isRemote) }
    }

    private func recompute() {
        guard !isFixed else { return }
        let now = Date.now
        let claude = ClaudeProvider().proxyName
        var logins = accounts.values.filter { !isDisabled($0) }.map { account in
            ProviderLogin(provider: claude, member: PoolMember(plan: claudePlan(account.email), signals: signals(for: account), usage: usageReadings[account.email]))
        }
        for file in listedFiles where !file.isDisabled {
            let member = file.hasUsageWindows ? PoolMember(plan: plan(for: file), signals: file.quota, usage: callReadings[file.name]) : nil
            logins.append(ProviderLogin(provider: file.provider, member: member))
        }
        let pooled = Set(logins.filter { $0.member != nil }.map(\.provider))
        var usageAPIReadAt: [String: Date] = [:]
        let claudeUsageDate = accounts.values
            .filter { !isDisabled($0) }
            .compactMap { readingSource(for: $0, at: now) }
            .filter { $0.source == .usageAPI }
            .map(\.reading.date)
            .max()
        usageAPIReadAt[claude] = claudeUsageDate
        for file in listedFiles where !file.isDisabled {
            guard let choice = ReadingChoice.choose(signals: file.quota, usage: callReadings[file.name], now: now), choice.source == .usageAPI else { continue }
            usageAPIReadAt[file.provider] = max(usageAPIReadAt[file.provider] ?? .distantPast, choice.reading.date)
        }

        let summaries = ProviderPools.summarize(logins, at: now)
        let pools = poolAccounts(at: now)
        if !isOffline { recordDemand(pools) }
        let next = PoolState(
            summaries: summaries,
            details: makeDetails(at: now),
            providers: Providers.all.map(\.proxyName).filter(pooled.contains),
            defaultProvider: ProviderPools.defaultProvider(ProviderPools.pooledWeight(logins)),
            usageAPIReadAt: usageAPIReadAt,
            forecasts: Dictionary(uniqueKeysWithValues: summaries.map { provider, summary in
                (provider, PoolForecast(ledger: ledger, pool: summary, provider: provider, now: now))
            })
        )
        if next != state { state = next }
        if savesStatus { saveStatus(at: now) }
        // Only while polling: alerts must rest on fresh readings.
        if !loops.isEmpty, !isOffline, LaunchOptions.snapshotDirectory == nil { raiseAlerts(pools, at: now) }
    }

    /// Saves the pools for readers outside the app: when they change, and every few minutes so their age tells.
    private func saveStatus(at now: Date) {
        let choice = UserDefaults.standard.string(forKey: ProviderDisplay.menuBarProviderKey) ?? ""
        let readAt = Dictionary(uniqueKeysWithValues: state.providers.compactMap { provider in lastReadAt(for: provider).map { (provider, $0) } })
        let status = PoolStatus(summaries: state.summaries, providers: state.providers, readAt: readAt, menuBarProvider: menuBarProvider(choice: choice), updatedAt: now)
        guard status.needsWrite(after: savedStatus) else { return }
        do {
            try status.write()
            savedStatus = status
        } catch {
            NSLog("Ebb: saving the pool status failed: \(error.localizedDescription)")
        }
    }

    /// Every counted login's latest reading and plan weight, by pool.
    private func poolAccounts(at now: Date) -> [String: [PoolAccount]] {
        var pools: [String: [PoolAccount]] = [:]
        let claude = ClaudeProvider().proxyName
        for account in accounts.values where !isDisabled(account) {
            guard let plan = claudePlan(account.email), plan.weight.isPositive, let choice = readingSource(for: account, at: now) else { continue }
            pools[claude, default: []].append(PoolAccount(id: account.email, weight: plan.weight, limits: choice.reading.limits, readAt: choice.reading.date))
        }
        for file in listedFiles where !file.isDisabled && file.hasUsageWindows {
            let weight = plan(for: file).weight
            guard weight.isPositive, let choice = ReadingChoice.choose(signals: file.quota, usage: callReadings[file.name], now: now) else { continue }
            pools[file.provider, default: []].append(PoolAccount(id: file.name, weight: weight, limits: choice.reading.limits, readAt: choice.reading.date))
        }
        return pools
    }

    /// Feeds every counted login's latest reading to the ledger.
    private func recordDemand(_ pools: [String: [PoolAccount]]) {
        for provider in Providers.all.map(\.proxyName) {
            let group = pools[provider] ?? []
            ledger.keepAccounts(Set(group.map(\.id)), in: provider)
            let shortWindow = Providers.named(provider)?.shortWindow.horizon ?? Pool.sessionHorizon
            for account in group {
                ledger.record(account, pool: provider, shortWindow: shortWindow)
            }
        }
    }

    /// Run-out, "weekly back", "resets unused" and "joined the pool" alerts, each once; delivered only if the user wants them.
    private func raiseAlerts(_ pools: [String: [PoolAccount]], at now: Date) {
        // Time since boot including sleep: tells a changed clock from a sleeping Mac.
        let uptime = TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        var alerts: [PoolAlert] = []
        let nudgeBefore = expiryNudge
        let membershipBefore = membership
        // Only with a fresh listing: while the proxy is down, who's in the pool can't be told.
        if proxyReadAt != nil { alerts += membership.alerts(rosters: rosters(counted: pools)) }
        for (provider, summary) in state.summaries.sorted(by: { $0.key < $1.key }) {
            alerts += alertTracker.alerts(
                pool: provider, title: ProviderDisplay.title(provider), short: Providers.named(provider)?.shortWindow ?? .fiveHours,
                summary: summary, forecast: state.forecasts[provider], accounts: pools[provider] ?? [], now: now, uptime: uptime
            )
            alerts += expiryNudge.alerts(
                pool: provider, title: ProviderDisplay.title(provider), accounts: pools[provider] ?? [],
                totalWeight: summary.totalWeight.weekly, forecast: state.forecasts[provider]?.weekly, now: now
            )
        }
        if expiryNudge != nudgeBefore || membership != membershipBefore { saveAlertTracker() }
        guard !alerts.isEmpty else { return }
        saveAlertTracker()
        Task { await delivery.deliver(alerts) }
    }

    /// Every pool's logins for the membership alerts: all of them, the counted ones by plan, and Ebb's retirements.
    private func rosters(counted pools: [String: [PoolAccount]]) -> [PoolRoster] {
        let claude = ClaudeProvider().proxyName
        var present: [String: [String]] = [:]
        var retiredByEbb: [String: [String]] = [:]
        var plans: [String: [String: String]] = [:]
        for account in accounts.values + disabledByUser {
            present[claude, default: []].append(account.email)
            plans[claude, default: [:]][account.email] = claudePlanTitle(account.email)
            if isDisabled(account), retired.contains(account.name) { retiredByEbb[claude, default: []].append(account.email) }
        }
        for file in listedFiles where file.hasUsageWindows {
            present[file.provider, default: []].append(file.name)
            plans[file.provider, default: [:]][file.name] = planTitle(provider: file.provider, plan: callPlans[file.name] ?? file.planName)
            if file.isDisabled, retired.contains(file.name) { retiredByEbb[file.provider, default: []].append(file.name) }
        }
        return Providers.all.map(\.proxyName).compactMap { provider in
            guard let ids = present[provider] else { return nil }
            return PoolRoster(
                pool: provider, title: ProviderDisplay.title(provider), present: ids,
                counted: (pools[provider] ?? []).map { PoolRoster.Account(id: $0.id, plan: plans[provider]?[$0.id]) },
                retired: retiredByEbb[provider] ?? []
            )
        }
    }

    private func makeDetails(at now: Date) -> [AccountDetail] {
        let enabledWeights = Dictionary(accounts.values.filter { !isDisabled($0) }.compactMap { account in
            proxyFiles[account.name]?.weight.map { (account.email, $0) }
        }) { first, _ in first }
        let shares = ProxyWeight.shares(enabledWeights)
        let rows = accounts.values.map { account -> AccountDetail in
            let plan = claudePlan(account.email)
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
                readAt: reading?.reading.date,
                extraUsage: proxyFiles[account.name]?.extraUsage(at: now),
                // A cooldown seen before the proxy went down says nothing about it now.
                isStuckInCooldown: proxyReadAt == nil ? false : proxyFiles[account.name].map {
                    StuckCooldown.isStuck(health: $0.health, usage: usageReadings[account.email], signalsObservedAt: $0.signalsObservedAt, now: now)
                } ?? false,
                authIndex: proxyFiles[account.name]?.authIndex
            )
        }
        let userDisabled = disabledByUser.map { AccountDetail(email: $0.email, plan: plans[$0.email]?.value, status: .disabledByUser) }
        return (rows + userDisabled + listedDetails(at: now)).sorted { $0.label < $1.label }
    }

    /// Rows for logins reached through the proxy's listing; shares are within each provider.
    private func listedDetails(at now: Date) -> [AccountDetail] {
        let files = listedFiles
        var shares: [String: Double] = [:]
        for provider in Set(files.map(\.provider)) {
            let weights = Dictionary(files.filter { $0.provider == provider && !$0.isDisabled && $0.hasUsageWindows }.compactMap { file in
                file.weight.map { (file.name, $0) }
            }) { first, _ in first }
            shares.merge(ProxyWeight.shares(weights)) { first, _ in first }
        }
        return files.map { file in
            guard file.hasUsageWindows else {
                var row = AccountDetail(email: file.displayName, plan: nil, status: .health(file.health.state), provider: file.provider, fileName: file.name)
                row.healthMessage = file.health.message
                return row
            }
            let plan = plan(for: file)
            let planName = callPlans[file.name] ?? file.planName
            // Claude's badge is its multiplier, as when read from the folder.
            let title = file.provider == ClaudeProvider().proxyName ? nil : PlanWeights.defaults[file.provider]?.first { $0.plan == planName?.lowercased() }?.title
            guard !file.isDisabled else {
                let status: AccountDetail.Status = retired.contains(file.name) ? .retired : .disabledByUser
                return AccountDetail(email: file.displayName, plan: plan, status: status, provider: file.provider, fileName: file.name, planTitle: title)
            }
            let reading = ReadingChoice.choose(signals: file.quota, usage: callReadings[file.name], now: now)
            if reading == nil, rejectedTokens.contains(file.name) {
                return AccountDetail(email: file.displayName, plan: plan, status: .limitsUnavailable, provider: file.provider, fileName: file.name, planTitle: title)
            }
            let limits = reading?.reading.limits ?? []
            let free = { (kind: UsageLimit.Kind) in limits.first { $0.kind == kind }.map { 100 - $0.used(at: now) } }
            let isCounted = reading?.isFresh == true && plan.weight.isPositive
            return AccountDetail(
                email: file.displayName,
                plan: plan,
                status: isCounted ? .active : .stale,
                sessionFree: reading == nil ? nil : free(.session) ?? 100,
                weeklyFree: free(.weeklyAll),
                share: shares[file.name],
                readAt: reading?.reading.date,
                provider: file.provider,
                fileName: file.name,
                planTitle: title,
                extraUsage: file.extraUsage(at: now),
                isStuckInCooldown: StuckCooldown.isStuck(health: file.health, usage: callReadings[file.name], signalsObservedAt: file.signalsObservedAt, now: now),
                authIndex: file.authIndex
            )
        }
    }
}
