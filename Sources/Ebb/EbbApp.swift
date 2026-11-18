import AppKit
import EbbCore
import ServiceManagement
import SwiftUI

@main
struct EbbApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.shared
    @AppStorage(ProviderDisplay.menuBarProviderKey) private var menuBarChoice = ""
    @AppStorage(ProxyPool.selectionKey) private var poolChoice = ProxyPool.claude

    private var shown: PoolSource {
        model.source(model.shownPool(choice: poolChoice))
    }

    /// The panel's Claude | Antigravity switch, once the Antigravity proxy has an address.
    private var poolSwitch: Binding<ProxyPool>? {
        model.offersPoolSwitch ? Binding(get: { model.shownPool(choice: poolChoice) }, set: { poolChoice = $0 }) : nil
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.visibility.isVisible && !LaunchOptions.rendersOffscreen }, set: { _ in })) {
            PoolPanel(store: shown.store, connection: shown.connection, pool: poolSwitch)
        } label: {
            MenuBarLabel(
                store: shown.store, settings: model.menuBarSettings, provider: shown.store.menuBarProvider(choice: menuBarChoice),
                isShowing: model.visibility.isVisible
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                connection: model.connection, visibility: model.visibility, store: model.store, menuBarSettings: model.menuBarSettings,
                antigravity: model.antigravity
            )
        }
    }
}

/// Wires visibility to fetching: no item on screen, no network.
@MainActor
final class AppModel {
    static let shared = AppModel()

    /// First, so it runs before the properties below touch any of Ebb's folders.
    private let hasThrowawayHome: Void = Budget.requireThrowawayHome()
    let connection = ProxyConnection(diagnostics: DiagnosticLog())
    let store: PoolStore
    /// The second proxy, read alongside the first so switching shows numbers at once. Left out
    /// of demos and fixed snapshots, which draw one pool.
    let antigravity: PoolSource?
    let visibility = Visibility()
    let menuBarSettings = MenuBarSettings()
    private var wakeObserver: NSObjectProtocol?
    private var hasCheckedConnection = false

    private init() {
        if LaunchOptions.isDemo {
            antigravity = nil
            store = DemoData.store(connection: connection)
            connection.showDemoConnection()
            visibility.showAlwaysForDemo()
            visibility.onVisibilityChange = { [store] isVisible in store.setActive(isVisible) }
            return
        }
        if LaunchOptions.snapshotDirectory != nil {
            antigravity = LaunchOptions.isLive ? Self.antigravitySource() : nil
            store = LaunchOptions.isLive ? PoolStore(connection: connection, savesStatus: false) : Snapshot.claudeOnly(connection: connection)
            return
        }
        store = PoolStore(connection: connection, isOffline: LaunchOptions.isOffline)
        antigravity = Self.antigravitySource()
        let stores = [store] + [antigravity?.store].compactMap { $0 }
        visibility.onVisibilityChange = { [weak self] isVisible in
            stores.forEach { $0.setActive(isVisible) }
            if isVisible { self?.checkConnectionOnce() }
        }
        stores.forEach { $0.setActive(visibility.isVisible) }
        if visibility.isVisible { checkConnectionOnce() }
        // Only the stores hear about wake; the item's visibility never changes for it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { stores.forEach { $0.didWake() } }
        }
    }

    /// Only the Claude pool writes what the `ebb` command reads.
    private static func antigravitySource() -> PoolSource {
        let connection = ProxyConnection(diagnostics: DiagnosticLog(), pool: .antigravity)
        return PoolSource(connection: connection, store: PoolStore(connection: connection, isOffline: LaunchOptions.isOffline, savesStatus: false))
    }

    var offersPoolSwitch: Bool {
        antigravity?.connection.hasAddress == true
    }

    /// The pool picked in the panel, or Claude's while there's no other to show.
    func shownPool(choice: ProxyPool) -> ProxyPool {
        offersPoolSwitch ? choice : .claude
    }

    func source(_ pool: ProxyPool) -> PoolSource {
        pool == .antigravity ? antigravity ?? claude : claude
    }

    var claude: PoolSource {
        PoolSource(connection: connection, store: store)
    }

    /// Answered before the panel first opens, so its setup steps don't start on a guess. Waits for the
    /// item to show: a hidden Ebb sends nothing, not even this.
    private func checkConnectionOnce() {
        guard !hasCheckedConnection else { return }
        hasCheckedConnection = true
        Task { [connection, antigravity] in
            await connection.test()
            if !connection.hasSavedKey, !LaunchOptions.isOffline { await connection.lookForProxy() }
            await antigravity?.connection.test()
        }
    }
}

/// Flags for development and screenshots; a normal launch passes none.
enum LaunchOptions {
    /// Shows cached numbers and never touches the network.
    static let isOffline = CommandLine.arguments.contains("--offline")
    /// Fake logins of every provider tier, with no network and no saved key: `--demo`, and always with `--record`.
    static let isDemo = CommandLine.arguments.contains("--demo") || recordDirectory != nil
    /// Puts the demo in a state worth a screenshot or recording: `--demo accounts|hover|disclosure|low|down|stale|locked|locked-lasts`.
    /// `low` fakes a nearly empty pool in the menu bar to show its warning colors; `down` a proxy
    /// that isn't answering (give it a `--key-file`, since the notice needs a key); `stale` readings
    /// old enough for the hover cards to date them; `locked` a Claude pool with a Max 20x whose
    /// week is spent, running out at this pace, and `locked-lasts` the same pool lasting.
    static let demo: Demo? = value(after: "--demo").flatMap(Demo.init(rawValue:))

    enum Demo: String {
        case accounts, hover, disclosure, low, down, stale, locked
        case lockedLasts = "locked-lasts"
    }
    /// Renders the panel, its setup steps, the menu bar styles and every Settings tab offscreen into this folder and quits: `--snapshot <dir>`.
    static let snapshotDirectory: URL? = value(after: "--snapshot").map { URL(fileURLWithPath: $0) }
    /// Renders the launch media offscreen into this folder and quits: `--record <dir>`. See `Recorder`.
    static let recordDirectory: URL? = value(after: "--record").map { URL(fileURLWithPath: $0) }
    /// Draws into files only, so the menu bar item stays out of the menu bar.
    static var rendersOffscreen: Bool { snapshotDirectory != nil || recordDirectory != nil }
    /// With `--snapshot`, renders what the running proxy reports instead of fixed numbers: `--live`.
    static let isLive = CommandLine.arguments.contains("--live")
    /// With `--snapshot --live`, the pool to read and draw with its switch: `--pool claude|antigravity`.
    /// The Antigravity address comes from the argument domain: `-antigravity.managementURL <url>`.
    static let pool = value(after: "--pool").flatMap(ProxyPool.init(rawValue:))
    /// With `--snapshot`, reads the live proxy using the management key in this file: `--key-file <path>`.
    static let snapshotKey: ManagementKey? = value(after: "--key-file")
        .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        .flatMap(ManagementKey.init)
    /// Runs against a stand-in proxy inside the process, counts requests and timer wakes, writes them to this file and quits: `--budget-report <file>`. See `Budget`.
    static let budgetReport: URL? = value(after: "--budget-report").map { URL(fileURLWithPath: $0) }
    /// How long a budget run lasts: `--budget-seconds <n>`.
    static let budgetSeconds = value(after: "--budget-seconds").flatMap(Double.init) ?? 60
    /// Keeps the menu bar item hidden, ignoring `~/.config/ebb/mode`: `--hidden`.
    static let forcesHidden = CommandLine.arguments.contains("--hidden")
    /// Forces the panel's appearance: `--appearance light|dark`.
    static let appearance: NSAppearance.Name? = value(after: "--appearance").map { $0 == "dark" ? .darkAqua : .aqua }

    private static func value(after flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let loginItemKey = "registeredLoginItem"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = LaunchOptions.recordDirectory {
            Recorder.write(model: AppModel.shared, to: directory)
            exit(0)
        }
        if let directory = LaunchOptions.snapshotDirectory {
            let model = AppModel.shared
            if LaunchOptions.isLive {
                Task {
                    let source = model.source(LaunchOptions.pool ?? .claude)
                    await source.store.readProxyOnce()
                    if LaunchOptions.pool != nil { await source.store.readCallLoginsOnce() }
                    let prefix = LaunchOptions.pool.map { "live-\($0.rawValue)" } ?? "live"
                    Snapshot.write(store: source.store, connection: source.connection, to: directory, prefix: prefix, pool: LaunchOptions.pool)
                    try? source.store.diagnosticsText().write(to: directory.appending(path: "\(prefix)-diagnostics.txt"), atomically: true, encoding: .utf8)
                    exit(0)
                }
                return
            }
            if LaunchOptions.isDemo {
                // The snapshot runs under its own bundle identifier, so these choices stay out of the app's settings.
                for provider in model.store.state.providers {
                    UserDefaults.standard.set(provider, forKey: ProviderDisplay.panelProviderKey)
                    Snapshot.write(store: model.store, connection: model.connection, to: directory, prefix: "demo-\(provider)")
                }
            } else {
                Snapshot.write(store: model.store, connection: model.connection, to: directory, prefix: "claude")
            }
            Snapshot.writeMenuBar(to: directory)
            Snapshot.writeSettings(model: model, to: directory)
            Snapshot.writeSetup(model: model, to: directory)
            Snapshot.writeNoReading(model: model, to: directory)
            exit(0)
        }
        if let appearance = LaunchOptions.appearance { NSApp.appearance = NSAppearance(named: appearance) }
        registerLoginItemOnce()
        _ = Updater.shared
        if let file = LaunchOptions.budgetReport { Budget.finish(after: LaunchOptions.budgetSeconds, writingTo: file) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.store.saveLedger()
        AppModel.shared.antigravity?.store.saveLedger()
    }

    /// Registers once, so turning it off in System Settings sticks.
    private func registerLoginItemOnce() {
        guard Bundle.main.bundleURL.pathExtension == "app",
              !UserDefaults.standard.bool(forKey: Self.loginItemKey)
        else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: Self.loginItemKey)
        } catch {
            NSLog("Ebb: login item registration failed: \(error.localizedDescription)")
        }
    }
}
