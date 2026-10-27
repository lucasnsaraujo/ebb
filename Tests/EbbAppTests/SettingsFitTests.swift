import AppKit
import EbbCore
import SwiftUI
import Testing
@testable import Ebb

/// Hosts each Settings pane the way the window does and measures it. A grouped form sized to its
/// content once grew the window past the bottom of the screen, with nothing to scroll. The panes
/// read Ebb's folders through the store, so this runs only in the throwaway home `ProxyOutageStoreTests` describes.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EBB_APP_TESTS"] == "1")) struct SettingsFitTests {
    private static let width: CGFloat = 480

    /// Every provider's plans, so the Plans form is the tallest a user can get.
    private func makeSettings() -> SettingsView {
        let connection = ProxyConnection()
        return SettingsView(connection: connection, visibility: Visibility(), store: DemoData.store(connection: connection), menuBarSettings: MenuBarSettings())
    }

    private func height(of view: some View) -> CGFloat {
        NSHostingView(rootView: view.frame(width: Self.width)).fittingSize.height
    }

    @Test(arguments: SettingsTab.allCases) func noPaneIsTallerThanTheCap(tab: SettingsTab) {
        let pane = height(of: makeSettings().pane(tab))
        #expect(pane > 0)
        #expect(pane <= SettingsView.maxPaneHeight, "\(tab)")
    }

    @Test func aFormTallerThanTheCapIsCappedRatherThanGrown() {
        let settings = makeSettings()
        #expect(height(of: PlanWeightSettings(store: settings.store)) > SettingsView.maxPaneHeight)
        #expect(height(of: settings.pane(.plans)) == SettingsView.maxPaneHeight)
    }

    @Test func aShortPaneKeepsItsOwnHeight() {
        let settings = makeSettings()
        let about = height(of: settings.pane(.about))
        #expect(about < SettingsView.maxPaneHeight)
        #expect(about == height(of: AboutSettings()))
    }
}

