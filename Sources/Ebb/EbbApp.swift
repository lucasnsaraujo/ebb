import AppKit
import ServiceManagement
import SwiftUI

@main
struct EbbApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { model.visibility.isVisible }, set: { _ in })) {
            PoolPanel(store: model.store, visibility: model.visibility, connection: model.connection)
        } label: {
            MenuBarLabel(summary: model.store.summary)
                .modifier(FirstRunSetup(connection: model.connection))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(connection: model.connection, visibility: model.visibility)
        }
    }
}

/// Wires visibility to fetching: no item on screen, no network.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let connection = ProxyConnection()
    let store: PoolStore
    let visibility = Visibility()

    private init() {
        store = PoolStore(connection: connection, isOffline: LaunchOptions.isOffline)
        visibility.onVisibilityChange = { [store] isVisible in store.setActive(isVisible) }
        store.setActive(visibility.isVisible)
        Task { [connection] in await connection.test() }
    }
}

/// Opens Settings once, the first time Ebb runs without a management key.
private struct FirstRunSetup: ViewModifier {
    let connection: ProxyConnection

    private static let offeredKey = "offeredSetup"
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            guard !LaunchOptions.isOffline, connection.keyState == .missing,
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
    /// Puts the app in a state worth a screenshot or recording: `--demo accounts|hover|disclosure|low`.
    /// `low` fakes a nearly empty pool in the menu bar to show its warning colors.
    static let demo: Demo? = value(after: "--demo").flatMap(Demo.init(rawValue:))

    enum Demo: String {
        case accounts, hover, disclosure, low
    }
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
        if let appearance = LaunchOptions.appearance { NSApp.appearance = NSAppearance(named: appearance) }
        registerLoginItemOnce()
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
