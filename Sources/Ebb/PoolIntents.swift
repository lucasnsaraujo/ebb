import AppIntents
import AppKit
import EbbCore

/// The providers with pools, by CLIProxyAPI's name.
enum PoolProvider: String, AppEnum {
    case claude, codex, devin, antigravity, kimi, meta

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [PoolProvider: DisplayRepresentation] = [
        .claude: "Claude", .codex: "Codex", .devin: "Devin", .antigravity: "Antigravity", .kimi: "Kimi", .meta: "Muse",
    ]
}

/// One pool as Shortcuts sees it: both windows apart, and the next refill.
struct PoolReading: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Pool Status"

    @Property(title: "Provider") var provider: String
    @Property(title: "Short Window") var shortWindow: String
    @Property(title: "Short Window Left (%)") var shortWindowFree: Int
    @Property(title: "Weekly Left (%)") var weeklyFree: Int
    @Property(title: "Next Refill") var nextRefill: Date?
    @Property(title: "Next Refill Window") var nextRefillWindow: String?
    @Property(title: "Next Refill Gain (%)") var nextRefillGain: Int?
    @Property(title: "Out of Date") var isStale: Bool

    var sentence = ""

    init() {
        provider = ""
        shortWindow = ""
        shortWindowFree = 0
        weeklyFree = 0
        isStale = false
    }

    init(_ answer: PoolAnswer) {
        self.init()
        provider = answer.provider
        shortWindow = answer.shortWindowTitle
        shortWindowFree = answer.shortWindowFree
        weeklyFree = answer.weeklyFree
        nextRefill = answer.nextRefill?.date
        nextRefillWindow = answer.nextRefill.map { $0.window == .weekly ? String(localized: "weekly") : answer.shortWindowTitle }
        nextRefillGain = answer.nextRefill?.gain
        isStale = answer.isStale
        sentence = answer.sentence()
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(provider): \(shortWindowFree)% \(shortWindow), \(weeklyFree)% weekly")
    }
}

enum PoolIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noData
    case noPool(String)
    case itemHidden

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noData: "Ebb has no numbers yet. They appear once its menu bar item has shown for a moment."
        case let .noPool(provider): "Ebb has no \(provider) pool."
        case .itemHidden: "Ebb's menu bar item is hidden right now. Choose when it shows in Ebb's Settings."
        }
    }
}

struct GetPoolStatus: AppIntent {
    static let title: LocalizedStringResource = "Get Pool Status"
    static let description = IntentDescription("How much of a provider's 5-hour (or daily) and weekly pools is left, and when capacity next comes back. Uses the numbers Ebb already has, without asking any provider.")

    @Parameter(title: "Provider", description: "Leave empty for the pool the menu bar shows.")
    var provider: PoolProvider?

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$provider) pool status")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<PoolReading> & ProvidesDialog {
        let status = PoolStatus.read()
        guard let answer = PoolAnswer(status, provider: provider?.rawValue, now: .now) else {
            if status != nil, let provider { throw PoolIntentError.noPool(PoolProvider.caseDisplayRepresentations[provider].map { String(localized: $0.title) } ?? provider.rawValue) }
            throw PoolIntentError.noData
        }
        let reading = PoolReading(answer)
        return .result(value: reading, dialog: IntentDialog(stringLiteral: reading.sentence))
    }
}

struct OpenEbb: AppIntent {
    static let title: LocalizedStringResource = "Open Ebb"
    static let description = IntentDescription("Opens Ebb's panel from the menu bar.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await PanelOpener.open() else { throw PoolIntentError.itemHidden }
        return .result()
    }
}

struct EbbShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetPoolStatus(),
            phrases: [
                "Get pool status in \(.applicationName)",
                "How much is left in \(.applicationName)",
                "Check my \(.applicationName) pool",
                "Get \(\.$provider) pool status in \(.applicationName)",
            ],
            shortTitle: "Pool Status",
            systemImageName: "gauge.with.dots.needle.50percent"
        )
        AppShortcut(
            intent: OpenEbb(),
            phrases: ["Open \(.applicationName)", "Show \(.applicationName)"],
            shortTitle: "Open Ebb",
            systemImageName: "menubar.arrow.up.rectangle"
        )
    }
}

/// Opens the menu bar panel the way a click would. SwiftUI's `MenuBarExtra` has no API for it,
/// so this presses the status item's button. False while the item is hidden.
@MainActor
enum PanelOpener {
    /// Set by the panel; a click on an open panel would close it.
    static var isPanelOpen = false

    static func open() async -> Bool {
        // Launched just for this intent, the item takes a moment to appear.
        var button = statusItemButton()
        for _ in 0..<10 where button == nil {
            try? await Task.sleep(for: .milliseconds(100))
            button = statusItemButton()
        }
        guard let button else { return false }
        NSApp.activate()
        if !isPanelOpen { button.performClick(nil) }
        return true
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        NSApp.windows
            .filter { $0.className == "NSStatusBarWindow" && $0.isVisible }
            .lazy
            .compactMap { $0.contentView.flatMap(findButton) }
            .first
    }

    private static func findButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(findButton).first
    }
}
