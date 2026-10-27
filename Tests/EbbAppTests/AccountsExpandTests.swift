import AppKit
import EbbCore
import SwiftUI
import Testing
@testable import Ebb

/// Hosts the panel the way the menu bar's window does, in a borderless window kept far off every
/// screen, and watches the window while the accounts expand and collapse: the hosting view resizes
/// the window to the content on its own, so the content's height must change in one step each way.
/// No screen means no display link, so an animated height can't be told from a snapped one here;
/// this guards the shape of the change, not its timing. Reads Ebb's folders through the store, so
/// it runs only in the throwaway home `ProxyOutageStoreTests` describes.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EBB_APP_TESTS"] == "1")) struct AccountsExpandTests {
    @MainActor private final class Samples {
        var contentHeights: [CGFloat] = []
        var windowHeights: [CGFloat] = []
    }

    @Test func theAccountsExpandAndCollapseInOneStepEach() async throws {
        let samples = Samples()
        let connection = ProxyConnection()
        connection.showDemoConnection()
        let panel = PoolPanel(store: DemoData.store(connection: connection), connection: connection, playsDisclosureDemo: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { samples.contentHeights.append($0) }
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.setContentSize(host.fittingSize)
        let collapsed = window.frame.height
        try #require(samples.contentHeights == [collapsed])

        let resizes = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { samples.windowHeights.append(window.frame.height) }
        }
        defer { NotificationCenter.default.removeObserver(resizes) }
        // The demo expands 1.2 s after the panel appears and collapses 2.2 s later.
        try await Task.sleep(for: .seconds(4))

        let expanded = try #require(samples.windowHeights.first)
        #expect(expanded > collapsed + 100)
        #expect(samples.windowHeights == [expanded, collapsed], "the window takes each height once, with nothing in between")
        #expect(samples.contentHeights == [collapsed, expanded, collapsed], "the content takes each height once, with nothing in between")
    }

    /// What made the window jump: the toggle animated the height, so the hosting view resized the
    /// window frame by frame. That shows offscreen as a transaction carrying an animation at the
    /// panel's root right before its height changes; the rows' own cascade only comes after it.
    @Test func theHeightChangesWithoutAnAnimation() async throws {
        @MainActor final class Events {
            let start = Date()
            var transactions: [(at: TimeInterval, isAnimated: Bool)] = []
            var heights: [(at: TimeInterval, height: CGFloat)] = []
        }
        let events = Events()
        let connection = ProxyConnection()
        connection.showDemoConnection()
        let panel = PoolPanel(store: DemoData.store(connection: connection), connection: connection, playsDisclosureDemo: true)
            .transaction { events.transactions.append((Date().timeIntervalSince(events.start), $0.animation != nil)) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { events.heights.append((Date().timeIntervalSince(events.start), $0)) }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: panel)
        defer { window.close() }
        // The demo expands 1.2 s after the panel appears and collapses 2.2 s later.
        try await Task.sleep(for: .seconds(4))

        let changes = events.heights.dropFirst()
        #expect(changes.count == 2)
        for change in changes {
            let animated = events.transactions.filter { $0.isAnimated && $0.at <= change.at && change.at - $0.at < 0.1 }
            #expect(animated.isEmpty, "the height went to \(change.height) inside an animated transaction")
        }
    }
}
