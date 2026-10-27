import AppKit
import Testing
@testable import Ebb

/// The policy Ebb switches to around its Settings window, so it can take focus from another app
/// while the window is open and leave the Dock once it closes.
@Suite struct SettingsPresenceTests {
    @Test func openingMakesEbbRegularAndClosingMakesItAnAccessoryAgain() {
        var presence = SettingsPresence()
        #expect(presence.willOpen() == .regular)
        #expect(presence.didClose() == .accessory)
    }

    @Test func aSecondOpenWhileTheWindowIsUpChangesNothing() {
        var presence = SettingsPresence()
        #expect(presence.willOpen() == .regular)
        #expect(presence.willOpen() == nil)
        #expect(presence.didClose() == .accessory)
    }

    @Test func aCloseWithNoOpenChangesNothing() {
        var presence = SettingsPresence()
        #expect(presence.didClose() == nil)
        #expect(presence.willOpen() == .regular)
        #expect(presence.didClose() == .accessory)
        #expect(presence.didClose() == nil)
    }
}
