import AppKit
import EbbCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String {
    case general, connection, routing, plans, about

    static let storageKey = "settingsTab"
}

struct SettingsView: View {
    let connection: ProxyConnection
    let visibility: Visibility
    let store: PoolStore
    let menuBarSettings: MenuBarSettings

    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(visibility: visibility, store: store, menuBarSettings: menuBarSettings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            ConnectionSettings(connection: connection, store: store)
                .tabItem { Label("Connection", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsTab.connection.rawValue)
            RoutingSettingsPane(connection: connection, store: store)
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
                .tag(SettingsTab.routing.rawValue)
            PlanWeightSettings(store: store)
                .tabItem { Label("Plans", systemImage: "scalemass") }
                .tag(SettingsTab.plans.rawValue)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about.rawValue)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

struct GeneralSettings: View {
    let visibility: Visibility
    let store: PoolStore
    @Bindable var menuBarSettings: MenuBarSettings

    @AppStorage(ProviderDisplay.menuBarProviderKey) private var menuBarChoice = ""
    @AppStorage(AlertSettings.isEnabledKey) private var sendsAlerts = true
    @AppStorage(AlertSettings.sendsIncidentAlertsKey) private var sendsIncidentAlerts = false
    @State private var areAlertsBlocked = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Show Ebb", selection: Binding(get: { visibility.mode }, set: { visibility.setMode($0) })) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                if visibility.mode == .apps {
                    WatchedAppsList(visibility: visibility)
                }
                if store.state.providers.count > 1 {
                    Picker("Pool", selection: $menuBarChoice) {
                        Text("Most Pooled Capacity").tag("")
                        ForEach(store.state.providers, id: \.self) { provider in
                            Text(ProviderDisplay.title(provider)).tag(provider)
                        }
                    }
                }
                MenuBarStylePicker(
                    selection: $menuBarSettings.style,
                    limit: menuBarSettings.limit,
                    pool: store.menuBarPool(for: store.menuBarProvider(choice: menuBarChoice), now: .now)
                )
                Picker("Limit", selection: $menuBarSettings.limit) {
                    ForEach(MenuBarLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .disabled(menuBarSettings.style.showsBothWindows)
            }
            Section {
                Toggle("Pool alerts", isOn: $sendsAlerts)
                    .onChange(of: sendsAlerts) { _, isOn in
                        guard isOn else { return }
                        Task { areAlertsBlocked = await !store.enableAlerts() }
                    }
                Toggle("Provider incidents", isOn: $sendsIncidentAlerts)
                    .onChange(of: sendsIncidentAlerts) { _, isOn in
                        guard isOn else { return }
                        Task { areAlertsBlocked = await !store.enableIncidentAlerts() }
                    }
            } header: {
                Text("Notifications")
            } footer: {
                Group {
                    if areAlertsBlocked && (sendsAlerts || sendsIncidentAlerts) {
                        Text("Notifications for Ebb are off in System Settings → Notifications.")
                    } else {
                        Text("Pool alerts: when a 5-hour pool is about to run out at the current pace, when weekly capacity comes back, and once per weekly reset when a meaningful share is about to reset unused. Provider incidents: when Claude's or OpenAI's status page reports a problem with what your pools run on.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, isOn in
                        do {
                            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchesAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            CommandLineToolSection()
            UpdatesSection(updater: .shared)
        }
        .formStyle(.grouped)
    }
}

private struct UpdatesSection: View {
    @Bindable var updater: Updater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                .disabled(!updater.isStarted)
            HStack {
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Once a day, Ebb asks GitHub whether a new release is out. The request names Ebb's version and nothing about your accounts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Links the `ebb` command from the app bundle onto the PATH.
private struct CommandLineToolSection: View {
    private static let installer = CommandLineTool(tool: Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(CommandLineTool.name)"))

    @State private var link = Self.installer.installedLink
    @State private var failure: String?

    private var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.installer.tool.path)
    }

    var body: some View {
        Section {
            LabeledContent("Status") {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else {
                    Text(link.map { String(localized: "Installed at \(abbreviated($0.path))") } ?? String(localized: "Not installed"))
                        .textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button(link == nil ? String(localized: "Install Command Line Tool") : String(localized: "Reinstall Command Line Tool"), action: install)
                    .disabled(!isBundled)
            }
        } header: {
            Text("Command Line Tool")
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        var text = String(localized: "Prints the pools in Terminal and in Claude Code's status line, from numbers Ebb already has. Installs into /usr/local/bin if you can write to it, otherwise ~/.local/bin, so no admin password is needed.")
        if let link, link.deletingLastPathComponent().path.hasSuffix("/.local/bin") {
            text += " " + String(localized: "If your shell can't find ebb, add ~/.local/bin to your PATH.")
        }
        return text
    }

    private func install() {
        do {
            link = try Self.installer.install()
            failure = nil
        } catch CommandLineTool.InstallError.occupied(let url) {
            failure = String(localized: "\(abbreviated(url.path)) is another program")
        } catch CommandLineTool.InstallError.noWritableFolder {
            failure = String(localized: "No folder on your PATH Ebb can write to")
        } catch {
            failure = String(localized: "Couldn't install: \(error.localizedDescription)")
        }
    }
}

private struct WatchedAppsList: View {
    let visibility: Visibility

    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(visibility.watchedApps, id: \.self, selection: $selection) { bundleIdentifier in
                AppRow(bundleIdentifier: bundleIdentifier)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 96)
            HStack(spacing: 0) {
                Button(action: addApp) { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .accessibilityLabel("Add App")
                Divider().frame(height: 14)
                Button {
                    visibility.setWatchedApps(visibility.watchedApps.filter { $0 != selection })
                    selection = nil
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .disabled(selection == nil)
                .accessibilityLabel("Remove App")
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        visibility.setWatchedApps(visibility.watchedApps + added.filter { !visibility.watchedApps.contains($0) })
    }
}

private struct AppRow: View {
    let bundleIdentifier: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                Text(bundleIdentifier)
                    .foregroundStyle(.secondary)
            }
        }
        .help(bundleIdentifier)
    }
}

// MARK: - Connection

struct ConnectionSettings: View {
    let connection: ProxyConnection
    let store: PoolStore

    @State private var draftKey = ""
    @State private var draftURL: String
    @State private var urlNote: URLNote?

    private enum URLNote: Equatable {
        case warning(String)
        case refusal(String)
    }

    init(connection: ProxyConnection, store: PoolStore) {
        self.connection = connection
        self.store = store
        _draftURL = State(initialValue: connection.managementURL?.absoluteString ?? "")
        _urlNote = State(initialValue: connection.managementURL.flatMap { Self.note(for: ManagementURL.validate($0.absoluteString)) })
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Config file") {
                    Text(connection.configFile.map { abbreviated($0.path) } ?? String(localized: "Not found; using defaults"))
                        .textSelection(.enabled)
                        .foregroundStyle(connection.configFile == nil ? .secondary : .primary)
                }
                LabeledContent("Address", value: connection.baseURL.absoluteString)
                LabeledContent("Logins folder") {
                    Text(connection.localAuthDirectory.map { abbreviated($0.path) } ?? String(localized: "Not read: the proxy is on another machine"))
                        .foregroundStyle(connection.isRemote ? .secondary : .primary)
                }
                HStack {
                    Spacer()
                    if connection.configOverride != nil {
                        Button("Use Detected") { useConfig(nil) }
                    }
                    Button("Choose Config…", action: chooseConfig)
                }
            } header: {
                Text(verbatim: "CLIProxyAPI")
            }
            Section {
                TextField("Management URL", text: $draftURL, prompt: Text(verbatim: "https://proxy.example.com:8317"))
                    .onSubmit(useURL)
                if let urlNote {
                    switch urlNote {
                    case let .warning(text): Text(text).font(.caption).foregroundStyle(.secondary)
                    case let .refusal(text): Text(text).font(.caption).foregroundStyle(.red)
                    }
                }
                HStack {
                    if connection.isRemote {
                        Button("Use Config File") { setURL(nil) }
                    }
                    Spacer()
                    Button("Use URL", action: useURL)
                        .disabled(draftURL.trimmingCharacters(in: .whitespaces).isEmpty || draftURL == connection.managementURL?.absoluteString)
                }
            } header: {
                Text("Remote Proxy")
            } footer: {
                Text("For CLIProxyAPI on a server or homelab. Replaces the address from the config file; the management key below is sent there, and every login, Claude's included, is read from the proxy's listing. Plain http is allowed only on a private network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") { KeyStatus(state: connection.keyState) }
                SecureField("Management key", text: $draftKey)
                    .onSubmit(save)
                HStack {
                    if connection.endpoint != nil {
                        Button("Forget Key", role: .destructive) { connection.forgetKey() }
                    }
                    Spacer()
                    Button("Test") { Task { await connection.test() } }
                        .disabled(connection.endpoint == nil)
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draftKey.isEmpty)
                }
            } header: {
                Text("Management Key")
            } footer: {
                Text("The proxy keeps only a hash of this key, so Ebb asks once and stores it in a file only you can read, in Ebb's Application Support folder. A .management-key file in the logins folder is picked up on its own until you forget the key. Without the key, a proxy on this Mac still has its Claude logins read from the logins folder, with routing and auto-retire off; a proxy on another machine can't be read at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        let key = draftKey
        Task {
            await connection.save(key: key)
            if connection.keyState == .valid { draftKey = "" }
        }
    }

    private func useURL() {
        let verdict = ManagementURL.validate(draftURL)
        urlNote = Self.note(for: verdict)
        switch verdict {
        case let .ok(url), let .unencrypted(url): setURL(url)
        case .refused: break
        }
    }

    private func setURL(_ url: URL?) {
        connection.setManagementURL(url)
        draftURL = url?.absoluteString ?? ""
        if url == nil { urlNote = nil }
        store.connectionDidChange()
    }

    private static func note(for verdict: ManagementURL.Verdict) -> URLNote? {
        switch verdict {
        case .ok: nil
        case .unencrypted: .warning("Plain http: the management key crosses your network unencrypted.")
        case let .refused(message): .refusal(message)
        }
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .data]
        panel.prompt = String(localized: "Use")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useConfig(url.path)
    }

    /// Another config can name another proxy, so the old proxy's numbers mustn't linger.
    private func useConfig(_ path: String?) {
        connection.setConfigOverride(path)
        store.connectionDidChange()
    }
}

private struct KeyStatus: View {
    let state: ProxyConnection.KeyState

    var body: some View {
        HStack(spacing: 6) {
            if state == .checking {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
        }
    }

    private var text: String {
        switch state {
        case .missing: String(localized: "Not set")
        case .checking: String(localized: "Checking…")
        case .valid: String(localized: "Connected")
        case .rejected: String(localized: "Rejected by the proxy")
        case .unreachable: String(localized: "Proxy not reachable")
        }
    }

    private var color: Color {
        switch state {
        case .valid: .green
        case .rejected: .red
        case .unreachable: .orange
        case .missing, .checking: .secondary
        }
    }
}

// MARK: - Routing

struct RoutingSettingsPane: View {
    let connection: ProxyConnection
    let store: PoolStore

    @AppStorage(RoutingSettings.balancesSessionsKey) private var balancesSessions = true

    var body: some View {
        Form {
            Section {
                Toggle("Balance new sessions by remaining capacity", isOn: $balancesSessions)
                    .disabled(!connection.hasManagementAccess)
            } footer: {
                Text("Ebb sets each login's weight so the proxy sends new sessions where capacity is left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Why This Weight") {
                Text("Plan size × free share × reset urgency. Weekly capacity a login hasn't used by its reset is lost, so in the last two days before that reset its weight rises steadily, up to double. The weight changes only when it moves by more than 10%.")
                    .foregroundStyle(.secondary)
                if balancesSessions, let urgent = store.strongestUrgency {
                    Text(urgent.explanation(now: .now))
                }
            }
            Section("Proxy Routing") {
                LabeledContent("Strategy", value: connection.routingStrategy ?? String(localized: "Unknown"))
                if !connection.hasManagementAccess {
                    Text("Needs the management key.")
                        .foregroundStyle(.secondary)
                } else if let strategy = connection.routingStrategy, strategy != ProxyClient.weightedRoundRobin {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Weights only take effect with weighted round robin. The proxy uses \(strategy) now.")
                            .foregroundStyle(.secondary)
                        Button("Use Weighted Round Robin") {
                            Task { await connection.useWeightedRouting() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await connection.refreshRoutingStrategy() }
    }
}

// MARK: - Plans

/// The size each plan counts with, relative to its provider's base plan. Only plans of one
/// provider are ever compared, so each provider's numbers stand alone.
private struct PlanWeightSettings: View {
    let store: PoolStore

    @State private var overrides = UserDefaults.standard.dictionary(forKey: PlanWeights.overridesKey) as? [String: Double] ?? [:]

    var body: some View {
        Form {
            if store.state.providers.isEmpty {
                Text("Plans appear here once Ebb reads a pool.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.state.providers, id: \.self) { provider in
                Section(ProviderDisplay.title(provider)) {
                    ForEach(PlanWeights.defaults[provider] ?? []) { row in
                        LabeledContent {
                            TextField(row.localizedTitle, value: weight(provider, row), format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                        } label: {
                            Text(row.localizedTitle)
                            Text(row.localizedSource)
                        }
                    }
                }
            }
            if !overrides.isEmpty {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { save([:]) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func weight(_ provider: String, _ row: PlanDefault) -> Binding<Double> {
        let key = PlanWeights.overrideKey(provider: provider, plan: row.plan)
        return Binding {
            overrides[key] ?? row.weight
        } set: { value in
            var next = overrides
            next[key] = value > 0 && value != row.weight ? value : nil
            save(next)
        }
    }

    private func save(_ next: [String: Double]) {
        overrides = next
        UserDefaults.standard.set(next, forKey: PlanWeights.overridesKey)
        store.weightsDidChange()
    }
}

// MARK: - About

private struct AboutSettings: View {
    private static let repository = URL(string: "https://github.com/lucasnsaraujo/ebb")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Source") {
                    Link(destination: Self.repository) { Text(verbatim: "github.com/lucasnsaraujo/ebb") }
                }
                LabeledContent("License") { Text(verbatim: "MIT") }
            } footer: {
                Text("Ebb is not affiliated with Anthropic, OpenAI, Cognition, Google, Moonshot AI or Meta. Provider names and logos are trademarks of their owners.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private func abbreviated(_ path: String) -> String {
    let home = EbbPaths.home.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
