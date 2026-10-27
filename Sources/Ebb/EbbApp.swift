import AppKit
import EbbCore
import ServiceManagement
import SwiftUI

@main
struct EbbApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.shared
    @AppStorage(ProviderDisplay.menuBarProviderKey) private var menuBarChoice = ""

    private var menuBarProvider: String? {
        model.store.menuBarProvider(choice: menuBarChoice)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.visibility.isVisible && LaunchOptions.snapshotDirectory == nil }, set: { _ in })) {
            PoolPanel(store: model.store, visibility: model.visibility, connection: model.connection)
        } label: {
            MenuBarLabel(store: model.store, settings: model.menuBarSettings, provider: menuBarProvider)
                .modifier(FirstRunSetup(connection: model.connection))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(connection: model.connection, visibility: model.visibility, store: model.store, menuBarSettings: model.menuBarSettings)
        }
    }
}

/// Wires visibility to fetching: no item on screen, no network.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let connection = ProxyConnection(diagnostics: DiagnosticLog())
    let store: PoolStore
    let visibility = Visibility()
    let menuBarSettings = MenuBarSettings()
    private var wakeObserver: NSObjectProtocol?

    private init() {
        if LaunchOptions.isDemo {
            store = DemoData.store(connection: connection)
            visibility.onVisibilityChange = { [store] isVisible in store.setActive(isVisible) }
            return
        }
        if LaunchOptions.snapshotDirectory != nil {
            store = LaunchOptions.isLive ? PoolStore(connection: connection, savesStatus: false) : Snapshot.claudeOnly(connection: connection)
            return
        }
        store = PoolStore(connection: connection, isOffline: LaunchOptions.isOffline)
        visibility.onVisibilityChange = { [store] isVisible in store.setActive(isVisible) }
        store.setActive(visibility.isVisible)
        Task { [connection] in await connection.test() }
        // Only the store hears about wake; the item's visibility never changes for it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [store] _ in
            MainActor.assumeIsolated { store.didWake() }
        }
    }
}

/// Opens Settings once, the first time Ebb runs without a management key.
private struct FirstRunSetup: ViewModifier {
    let connection: ProxyConnection

    private static let offeredKey = "offeredSetup"
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            guard !LaunchOptions.isOffline, !LaunchOptions.isDemo, connection.keyState == .missing,
                  !UserDefaults.standard.bool(forKey: Self.offeredKey)
            else { return }
            UserDefaults.standard.set(true, forKey: Self.offeredKey)
            UserDefaults.standard.set(SettingsTab.connection.rawValue, forKey: SettingsTab.storageKey)
            NSApp.activate()
            openSettings()
        }
    }
}

/// Flags for development and screenshots; a normal launch passes none.
enum LaunchOptions {
    /// Shows cached numbers and never touches the network.
    static let isOffline = CommandLine.arguments.contains("--offline")
    /// Fake logins of every provider tier, with no network and no saved key: `--demo`.
    static let isDemo = CommandLine.arguments.contains("--demo")
    /// Puts the demo in a state worth a screenshot or recording: `--demo accounts|hover|disclosure|low|down`.
    /// `low` fakes a nearly empty pool in the menu bar to show its warning colors; `down` a proxy
    /// that isn't answering (give it a `--key-file`, since the notice needs a key).
    static let demo: Demo? = value(after: "--demo").flatMap(Demo.init(rawValue:))

    enum Demo: String {
        case accounts, hover, disclosure, low, down
    }
    /// Renders the panel, the menu bar styles and Settings → General, Routing and Connection offscreen into this folder and quits: `--snapshot <dir>`.
    static let snapshotDirectory: URL? = value(after: "--snapshot").map { URL(fileURLWithPath: $0) }
    /// With `--snapshot`, renders what the running proxy reports instead of fixed numbers: `--live`.
    static let isLive = CommandLine.arguments.contains("--live")
    /// With `--snapshot`, reads the live proxy using the management key in this file: `--key-file <path>`.
    static let snapshotKey: ManagementKey? = value(after: "--key-file")
        .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        .flatMap(ManagementKey.init)
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
        if let directory = LaunchOptions.snapshotDirectory {
            let model = AppModel.shared
            if LaunchOptions.isLive {
                Task {
                    await model.store.readProxyOnce()
                    Snapshot.write(store: model.store, connection: model.connection, visibility: model.visibility, to: directory, prefix: "live")
                    try? model.store.diagnosticsText().write(to: directory.appending(path: "live-diagnostics.txt"), atomically: true, encoding: .utf8)
                    exit(0)
                }
                return
            }
            if LaunchOptions.isDemo {
                // The snapshot runs under its own bundle identifier, so these choices stay out of the app's settings.
                for provider in model.store.state.providers {
                    UserDefaults.standard.set(provider, forKey: ProviderDisplay.panelProviderKey)
                    Snapshot.write(store: model.store, connection: model.connection, visibility: model.visibility, to: directory, prefix: "demo-\(provider)")
                }
            } else {
                Snapshot.write(store: model.store, connection: model.connection, visibility: model.visibility, to: directory, prefix: "claude")
            }
            Snapshot.writeMenuBar(to: directory)
            Snapshot.writeSettings(model: model, to: directory)
            exit(0)
        }
        if let appearance = LaunchOptions.appearance { NSApp.appearance = NSAppearance(named: appearance) }
        registerLoginItemOnce()
        _ = Updater.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.store.saveLedger()
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
