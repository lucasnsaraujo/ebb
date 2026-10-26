import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String {
    case general, connection, routing, about

    static let storageKey = "settingsTab"
}

struct SettingsView: View {
    let connection: ProxyConnection
    let visibility: Visibility

    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(visibility: visibility)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            ConnectionSettings(connection: connection)
                .tabItem { Label("Connection", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(SettingsTab.connection.rawValue)
            RoutingSettingsPane(connection: connection)
                .tabItem { Label("Routing", systemImage: "arrow.triangle.branch") }
                .tag(SettingsTab.routing.rawValue)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about.rawValue)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let visibility: Visibility

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
        }
        .formStyle(.grouped)
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
        panel.prompt = "Add"
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

private struct ConnectionSettings: View {
    let connection: ProxyConnection

    @State private var draftKey = ""

    var body: some View {
        Form {
            Section("CLIProxyAPI") {
                LabeledContent("Config file") {
                    Text(connection.configFile.map { abbreviated($0.path) } ?? "Not found; using defaults")
                        .textSelection(.enabled)
                        .foregroundStyle(connection.configFile == nil ? .secondary : .primary)
                }
                LabeledContent("Address", value: connection.config.baseURL.absoluteString)
                LabeledContent("Logins folder", value: abbreviated(connection.authDirectory.path))
                HStack {
                    Spacer()
                    if connection.configOverride != nil {
                        Button("Use Detected") { connection.setConfigOverride(nil) }
                    }
                    Button("Choose Config…", action: chooseConfig)
                }
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
                Text("The proxy keeps only a hash of this key, so Ebb asks once and stores it in your keychain. Without it, Ebb reads the logins folder and asks each provider directly, and routing and auto-retire stay off.")
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

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .data]
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connection.setConfigOverride(url.path)
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
        case .missing: "Not set"
        case .checking: "Checking…"
        case .valid: "Connected"
        case .rejected: "Rejected by the proxy"
        case .unreachable: "Proxy not reachable"
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

private struct RoutingSettingsPane: View {
    let connection: ProxyConnection

    @AppStorage(RoutingSettings.balancesSessionsKey) private var balancesSessions = true

    var body: some View {
        Form {
            Section {
                Toggle("Balance new sessions by remaining capacity", isOn: $balancesSessions)
                    .disabled(!connection.hasManagementAccess)
            } footer: {
                Text("Ebb sets each login's weight to its plan size times its free share, so the proxy sends new sessions where capacity is left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Proxy Routing") {
                LabeledContent("Strategy", value: connection.routingStrategy ?? "Unknown")
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

// MARK: - About

private struct AboutSettings: View {
    private static let repository = URL(string: "https://github.com/lucasnsaraujo/ebb")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Source") {
                    Link("github.com/lucasnsaraujo/ebb", destination: Self.repository)
                }
                LabeledContent("License", value: "MIT")
            } footer: {
                Text("Ebb is not affiliated with Anthropic. The Claude mark belongs to Anthropic.")
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
