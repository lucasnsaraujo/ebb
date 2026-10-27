import AppKit
import SwiftUI

/// Opens Settings in front of whatever was active. macOS never lets an accessory app take focus
/// from another app's window, so the window used to land behind it. For as long as Settings is
/// open Ebb counts as a regular app, Dock icon and all, and goes back to the menu bar when the
/// window closes. Every Settings… in the app goes through here.
@MainActor
enum SettingsOpener {
    /// What SwiftUI names the window of its `Settings` scene.
    private static let windowIdentifier = "com_apple_SwiftUI_Settings_window"
    private static var presence = SettingsPresence()
    private static var closeWatcher: Task<Void, Never>?

    static func open(_ openSettings: OpenSettingsAction) {
        Task {
            if let policy = presence.willOpen() {
                NSApp.setActivationPolicy(policy)
                watchForClose()
                // The policy takes a moment to land; activating before it does nothing.
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.activate()
            openSettings()
            try? await Task.sleep(for: .milliseconds(150))
            guard let window = NSApp.windows.first(where: isSettingsWindow) else {
                // Nothing opened, so nothing will close: don't stay in the Dock.
                didClose()
                return
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private static func watchForClose() {
        guard closeWatcher == nil else { return }
        closeWatcher = Task {
            for await notification in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification) {
                guard let window = notification.object as? NSWindow, isSettingsWindow(window) else { continue }
                didClose()
            }
        }
    }

    private static func didClose() {
        if let policy = presence.didClose() { NSApp.setActivationPolicy(policy) }
    }

    /// SwiftUI's own identifier, or failing that a titled window hosting `SettingsView`.
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == windowIdentifier { return true }
        guard window.styleMask.contains(.titled), let content = window.contentView else { return false }
        return String(describing: type(of: content)).contains("SettingsView")
    }
}

/// Which activation policy Ebb needs, by whether a Settings window is open: `.regular` while one
/// is, so it can take focus from another app, and `.accessory` once it closes. A second open while
/// it's up changes nothing, nor does a close that matches no open.
struct SettingsPresence: Equatable {
    private(set) var isOpen = false

    mutating func willOpen() -> NSApplication.ActivationPolicy? {
        guard !isOpen else { return nil }
        isOpen = true
        return .regular
    }

    mutating func didClose() -> NSApplication.ActivationPolicy? {
        guard isOpen else { return nil }
        isOpen = false
        return .accessory
    }
}
