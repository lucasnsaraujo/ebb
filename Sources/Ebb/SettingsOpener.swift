import AppKit
import SwiftUI

/// Opens Settings in front of whatever was active. macOS never lets an accessory app take focus
/// from another app's window, so the window used to land behind it. For as long as Settings is
/// open Ebb counts as a regular app, Dock icon and all, and goes back to the menu bar when the
/// window closes, handing focus back to the app that had it. Every Settings… in the app goes
/// through here.
@MainActor
enum SettingsOpener {
    /// What SwiftUI names the window of its `Settings` scene.
    private static let windowIdentifier = "com_apple_SwiftUI_Settings_window"
    private static var presence = SettingsPresence()
    private static var closeWatcher: Task<Void, Never>?

    static func open(_ openSettings: OpenSettingsAction) {
        Task {
            watchForClose()
            if let policy = presence.willOpen(from: NSApp.activationPolicy(), handingFocusBackTo: appInFront) {
                NSApp.setActivationPolicy(policy)
                // The policy takes a moment to land; activating before it does nothing.
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.activate()
            openSettings()
            let asked = ContinuousClock.now
            while true {
                try? await Task.sleep(for: .milliseconds(50))
                // Closed again while it opened: SwiftUI keeps the window, hidden, and it must stay so.
                guard presence.isOpen else { return }
                if let window = NSApp.windows.first(where: { $0.isVisible && isSettingsWindow($0) }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                // Nothing opened, so nothing will close: once it clearly isn't coming, go back.
                hand(back: presence.windowMissing(after: ContinuousClock.now - asked))
            }
        }
    }

    /// The app to give focus back to: the one in front, or when that's Ebb, the one whose menus
    /// show, since an accessory app never takes the menu bar.
    private static var appInFront: pid_t? {
        let workspace = NSWorkspace.shared
        let ebb = ProcessInfo.processInfo.processIdentifier
        return [workspace.frontmostApplication, workspace.menuBarOwningApplication]
            .compactMap { $0?.processIdentifier }
            .first { $0 != ebb }
    }

    private static func watchForClose() {
        guard closeWatcher == nil else { return }
        closeWatcher = Task {
            for await notification in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification) {
                guard let window = notification.object as? NSWindow, isSettingsWindow(window) else { continue }
                hand(back: presence.didClose())
            }
        }
    }

    /// Focus goes first, while Ebb is still active and can give it away: switching to an accessory
    /// first left no app in front until the next click. A window closed from behind another app
    /// leaves focus where it is.
    private static func hand(back handback: SettingsPresence.Handback?) {
        guard let handback else { return }
        if NSApp.isActive, let app = handback.app.flatMap(NSRunningApplication.init(processIdentifier:)) {
            app.activate()
        }
        NSApp.setActivationPolicy(handback.policy)
    }

    /// SwiftUI's own identifier, or failing that a titled window hosting `SettingsView`.
    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window.identifier?.rawValue == windowIdentifier { return true }
        guard window.styleMask.contains(.titled), let content = window.contentView else { return false }
        return String(describing: type(of: content)).contains("SettingsView")
    }
}

/// Which activation policy Ebb needs, by whether a Settings window is open: `.regular` while one
/// is, so it can take focus from another app, and once it closes, the policy it had before, with
/// focus back on the app that had it. A second open while it's up changes nothing, nor does a
/// close that matches no open, and an app already regular, as a `swift run` build is, stays so.
struct SettingsPresence {
    /// What a close puts back: focus to `app`, then Ebb's own `policy`.
    struct Handback: Equatable {
        var app: pid_t?
        var policy: NSApplication.ActivationPolicy
    }

    /// How long a window may take to show before Ebb decides none is coming. A cold first open
    /// can take well over a tenth of a second, and giving up early puts Ebb back in the menu bar,
    /// where the window then opens behind the active app.
    static let patience = Duration.seconds(5)

    private(set) var isOpen = false
    private var handback: Handback?

    mutating func willOpen(from current: NSApplication.ActivationPolicy, handingFocusBackTo app: pid_t? = nil) -> NSApplication.ActivationPolicy? {
        guard !isOpen else { return nil }
        isOpen = true
        guard current != .regular else { return nil }
        handback = Handback(app: app, policy: current)
        return .regular
    }

    /// No window yet, `waited` after asking for one: nil while it may still come, then the same
    /// as a close.
    mutating func windowMissing(after waited: Duration) -> Handback? {
        guard waited >= Self.patience else { return nil }
        return didClose()
    }

    mutating func didClose() -> Handback? {
        guard isOpen else { return nil }
        isOpen = false
        defer { handback = nil }
        return handback
    }
}
