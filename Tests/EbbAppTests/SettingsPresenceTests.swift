import AppKit
import Testing
@testable import Ebb

/// The policy Ebb switches to around its Settings window, so it can take focus from another app
/// while the window is open, and leave the Dock and give focus back once it closes.
@Suite struct SettingsPresenceTests {
    @Test func openingMakesEbbRegularAndClosingMakesItAnAccessoryAgain() {
        var presence = SettingsPresence()
        #expect(presence.willOpen(from: .accessory) == .regular)
        #expect(presence.didClose()?.policy == .accessory)
    }

    @Test func aSecondOpenWhileTheWindowIsUpChangesNothing() {
        var presence = SettingsPresence()
        #expect(presence.willOpen(from: .accessory) == .regular)
        #expect(presence.willOpen(from: .accessory) == nil)
        #expect(presence.didClose()?.policy == .accessory)
    }

    @Test func aCloseWithNoOpenChangesNothing() {
        var presence = SettingsPresence()
        #expect(presence.didClose() == nil)
        #expect(presence.willOpen(from: .accessory) == .regular)
        #expect(presence.didClose()?.policy == .accessory)
        #expect(presence.didClose() == nil)
    }

    @Test func anAppAlreadyRegularStaysRegular() {
        var presence = SettingsPresence()
        #expect(presence.willOpen(from: .regular) == nil)
        #expect(presence.isOpen)
        #expect(presence.didClose() == nil)
    }

    @Test func closingHandsFocusBackToTheAppThatHadIt() {
        var presence = SettingsPresence()
        #expect(presence.willOpen(from: .accessory, handingFocusBackTo: 42) == .regular)
        #expect(presence.didClose() == SettingsPresence.Handback(app: 42, policy: .accessory))
    }

    /// A cold first open can take well over a tenth of a second; giving up then put Ebb back in
    /// the menu bar before the window came, and the window opened behind the active app.
    @Test func aSlowFirstOpenStillWaitsForTheWindow() {
        var presence = SettingsPresence()
        #expect(presence.willOpen(from: .accessory, handingFocusBackTo: 42) == .regular)
        #expect(presence.windowMissing(after: .seconds(1)) == nil)
        #expect(presence.isOpen)
        #expect(presence.windowMissing(after: .seconds(10)) == SettingsPresence.Handback(app: 42, policy: .accessory))
        #expect(!presence.isOpen)
    }
}
