import EbbCore
import SwiftUI

/// The window under the menu bar item: the 5-hour and weekly windows side by side,
/// each with what comes back, and the accounts behind them on request.
struct PoolPanel: View {
    let store: PoolStore
    let visibility: Visibility
    let connection: ProxyConnection

    @State private var showsAccounts: Bool
    /// The setup steps to draw instead of working them out: `--snapshot` only.
    private let fixedSetup: ProxySetup?
    @AppStorage(ProviderDisplay.panelProviderKey) private var panelChoice = ""
    @AppStorage(ProviderDisplay.menuBarProviderKey) private var menuBarChoice = ""
    @AppStorage(ProxySetupView.skippedKey) private var skippedSetup = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    init(store: PoolStore, visibility: Visibility, connection: ProxyConnection, showsAccounts: Bool = LaunchOptions.demo == .accounts, setup: ProxySetup? = nil) {
        self.store = store
        self.visibility = visibility
        self.connection = connection
        _showsAccounts = State(initialValue: showsAccounts)
        fixedSetup = setup
    }

    /// The pool on show: the one picked here, else the menu bar's.
    private var provider: String? {
        store.state.providers.contains(panelChoice) ? panelChoice : store.menuBarProvider(choice: menuBarChoice)
    }

    private var summary: PoolSummary? {
        provider.flatMap { store.state.summaries[$0] }
    }

    /// The first-run steps, while CLIProxyAPI isn't running here or no key works; see `ProxySetup`.
    private var setup: ProxySetup? {
        if let fixedSetup { return fixedSetup }
        guard !store.isOffline, !LaunchOptions.isDemo, LaunchOptions.snapshotDirectory == nil else { return nil }
        return ProxySetup.needed(ProxySetup.Facts(
            answers: connection.answers, install: connection.install, hasBinary: connection.hasBinary,
            keyCheck: connection.keyCheck, managementKeyIsSet: connection.managementKeyIsSet, hasSavedKey: connection.hasSavedKey,
            isRemote: connection.isRemote, hasLogins: !store.state.details.isEmpty, isSkipped: skippedSetup
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            // With Reduce Motion the swap between the two cross-fades without the height easing along.
            if let setup {
                ProxySetupView(setup: setup, connection: connection, store: store)
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.2)) : .opacity)
            } else {
                pool
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.2)) : .opacity)
            }
            Divider()
                .padding(.top, 10)
                .padding(.bottom, 8)
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 300)
        // The menu bar window sizes itself to this; without it, expanding clips the content.
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: setup == nil)
        // Setup just ended, by a key or by skipping it: read at once rather than at the next poll.
        .onChange(of: setup == nil) { _, isDone in
            if isDone { store.refreshNow() }
        }
        .onAppear {
            PanelOpener.isPanelOpen = true
            store.panelDidOpen()
            if LaunchOptions.demo == .disclosure { playDisclosureDemo() }
        }
        .onDisappear { PanelOpener.isPanelOpen = false }
    }

    /// The pool on show, and its accounts on request.
    private var pool: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.outageAdvice != .none {
                ProxyDownNotice(store: store, connection: connection)
                    .padding(.bottom, 12)
            }
            if let summary {
                WindowPair(summary: summary, forecast: provider.flatMap { store.state.forecasts[$0] }, short: ProviderDisplay.shortWindow(provider))
                    .contentShape(.rect)
                    .onTapGesture(perform: toggleAccounts)
            } else {
                noReading
            }
            if let provider, let health = store.incidents[provider], let line = health.line(title: ProviderDisplay.title(provider)),
               let page = StatusPage.forProvider(provider) {
                IncidentLine(text: line, page: page.pageURL)
                    .padding(.top, 10)
            }
            AccountsDisclosure(isExpanded: showsAccounts, action: toggleAccounts)
                .padding(.top, 12)
            if showsAccounts {
                let healthOnly = store.state.details.filter(\.isHealthOnly)
                AccountsSection(
                    details: store.state.details.filter { $0.provider == provider && !$0.isHealthOnly },
                    healthOnly: healthOnly,
                    showsProviders: store.state.providers.count > 1 || !healthOnly.isEmpty,
                    short: ProviderDisplay.shortWindow(provider),
                    isOffline: store.isOffline,
                    hasManagementKey: connection.endpoint != nil,
                    proxyReadAt: store.proxyReadAt,
                    usageAPIReadAt: provider.flatMap { store.state.usageAPIReadAt[$0] },
                    proxyURL: connection.baseURL
                )
                    .padding(.top, 4)
                    // With Reduce Motion the panel's height snaps and only the rows cross-fade.
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.2)) : .opacity)
            }
        }
    }

    private func toggleAccounts() {
        withAnimation(Motion.disclosure(expanding: !showsAccounts, reduceMotion: reduceMotion)) {
            showsAccounts.toggle()
        }
    }

    /// Expands, then collapses, for screen recordings.
    private func playDisclosureDemo() {
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            toggleAccounts()
            try? await Task.sleep(for: .seconds(2.2))
            toggleAccounts()
        }
    }

    /// With pools from more than one provider, a pop-up picks the one on show.
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                EbbMark()
                    .frame(width: 14, height: 14)
                Text(verbatim: "Ebb")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            if store.state.providers.count > 1 {
                Spacer(minLength: 0)
                Picker("Provider", selection: Binding(get: { provider ?? "" }, set: { panelChoice = $0 })) {
                    ForEach(store.state.providers, id: \.self) { name in
                        Text(ProviderDisplay.title(name)).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.borderless)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, -4)
                .accessibilityLabel("Provider")
            }
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }

    private var hasOnlyRefusedTokens: Bool {
        let rows = store.state.details.filter { $0.provider == provider }
        return !rows.isEmpty && rows.allSatisfy { $0.status == .limitsUnavailable }
    }

    private var noReading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "–")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            Text(hasOnlyRefusedTokens ? String(localized: "Limits not available for these logins.") : String(localized: "No account could be read yet."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: store.isRefreshing && !reduceMotion)
                    .symbolEffect(.pulse, options: .repeat(.continuous), isActive: store.isRefreshing && reduceMotion)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh")

            if summary?.isPartial == true {
                Label("Partial", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Some accounts can't be read right now, so they're left out of these numbers.")
            }

            Spacer()

            Menu {
                Picker("Show in Menu Bar", selection: Binding(get: { visibility.mode }, set: { visibility.setMode($0) })) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Button("Open Proxy Panel") {
                    NSWorkspace.shared.open(connection.managementPage)
                }
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.diagnosticsText(), forType: .string)
                }
                Button("Settings…", action: showSettings)
                    .keyboardShortcut(",")
                Divider()
                Button("Quit Ebb") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .foregroundStyle(.secondary)
    }
}

/// The proxy didn't answer: says so and, for a Homebrew install on this Mac, starts it on request;
/// otherwise shows the command to run. A refused key points at Settings; a remote proxy gets
/// neither, since nothing here could start it. See `ProxyOutage` for the choice.
private struct ProxyDownNotice: View {
    let store: PoolStore
    let connection: ProxyConnection

    @Environment(\.openSettings) private var openSettings
    @State private var didCopy = false

    var body: some View {
        let advice = store.outageAdvice
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title(advice))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                switch advice {
                case .keyRefused:
                    Button("Settings…") {
                        NSApp.activate()
                        openSettings()
                    }
                case .start:
                    Button(connection.startState == .starting ? String(localized: "Starting…") : String(localized: "Start"), action: start)
                        .disabled(connection.startState == .starting)
                case let .command(command):
                    Button(didCopy ? String(localized: "Copied") : String(localized: "Copy")) { copy(command) }
                case .none, .remoteUnreachable:
                    EmptyView()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if case let .command(command) = advice {
                Text(verbatim: command)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            if case let .failed(message) = connection.startState {
                Text("Couldn't start: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func title(_ advice: ProxyOutage.Advice) -> String {
        switch advice {
        case .keyRefused: String(localized: "The proxy refused the management key")
        case let .remoteUnreachable(host): String(localized: "Can't reach the proxy at \(host)")
        case .start, .command, .none: String(localized: "CLIProxyAPI isn't running")
        }
    }

    private func start() {
        Task {
            await connection.startProxy()
            if connection.startState == .idle { store.proxyWasStarted() }
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopy = true
    }
}

enum Motion {
    /// Delay between consecutive rows as they cascade in.
    static let stagger = 0.03
    static let reveal = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Springs open, closes quicker. With Reduce Motion nothing moves: the height snaps, and the
    /// rows bring their own cross-fade.
    static func disclosure(expanding: Bool, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return expanding ? reveal : .smooth(duration: 0.2)
    }
}

// MARK: - Windows

private struct WindowPair: View {
    let summary: PoolSummary
    let forecast: PoolForecast?
    let short: ShortWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            HStack(alignment: .top, spacing: 20) {
                WindowColumn(
                    window: .session,
                    short: short,
                    freePercent: summary.session.freePercent,
                    line: GainLine.session(summary.session.resets.filter { $0.date > now }),
                    forecast: forecast?.session,
                    notes: PoolNotes.lines(summary, window: .session, now: now),
                    now: now,
                    inlineNote: PoolNotes.inline(summary)
                )
                WindowColumn(
                    window: .weekly,
                    short: short,
                    freePercent: summary.weekly.freePercent,
                    line: GainLine.weekly(summary.weekly.resets.filter { $0.date > now }),
                    forecast: forecast?.weekly,
                    notes: PoolNotes.lines(summary, window: .weekly, now: now),
                    now: now
                )
            }
        }
    }
}

private struct WindowColumn: View {
    let window: PoolWindow
    let short: ShortWindow
    let freePercent: Double
    let line: GainLine?
    let forecast: Pace.Forecast?
    let notes: [String]
    let now: Date
    var inlineNote: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = PoolLevel(freePercent)
        VStack(alignment: .leading, spacing: 0) {
            // One element for the title, the number and the meter, so VoiceOver reads the share once.
            VStack(alignment: .leading, spacing: 0) {
                Text(window.title(short))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "\(level.percent)%")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(level.percent)))
                        .foregroundStyle(level.warningTint ?? .primary)
                    Text("free")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Meter(free: freePercent, comingBack: Double(line?.points ?? 0), tint: level.warningTint ?? .primary)
                    .frame(height: 6)
                    .padding(.top, 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.title(short))
            .accessibilityValue(AccessibilityText.meter(freePercent: level.percent, comingBackPercent: line?.points ?? 0))
            GainLabel(window: window, short: short, line: line, forecast: forecast, notes: notes, now: now, inlineNote: inlineNote)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .smooth, value: level.percent)
    }
}

/// Free share as a capsule; what comes back soon shows as a lighter segment after it.
private struct Meter: View {
    let free: Double
    let comingBack: Double
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Capsule()
            .fill(contrast.track)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let freeWidth = width * min(max(free, 0), 100) / 100
                    HStack(spacing: 0) {
                        Rectangle().fill(tint).frame(width: freeWidth)
                        Rectangle().fill(tint.opacity(contrast == .increased ? 0.5 : 0.28)).frame(width: min(width * comingBack / 100, width - freeWidth))
                    }
                }
            }
            .clipShape(.capsule)
            .animation(reduceMotion ? nil : .smooth, value: free)
    }
}

/// "+5% in next 4 h" or "+54% · Tue 22:00"; hovering shows the resets behind it and the pace.
/// A predicted run-out takes the line's place, since it's the thing worth seeing unhovered;
/// what comes back stays in the meter and the hover card.
private struct GainLabel: View {
    let window: PoolWindow
    let short: ShortWindow
    let line: GainLine?
    let forecast: Pace.Forecast?
    let notes: [String]
    let now: Date

    /// Under this, a 5-hour run-out is tinted.
    private static let urgentRunOut: TimeInterval = 30 * 60

    @State private var isHovering = false
    @State private var showsBreakdown = false
    @State private var pendingOpen: Task<Void, Never>?

    /// Shown only when there's nothing else to say under the meter.
    var inlineNote: String?

    private var runOut: String? {
        forecast.flatMap { PaceText.inline($0, window: window, now: now) }
    }

    private var isUrgent: Bool {
        guard window == .session, case let .runsOut(within) = forecast?.outlook else { return false }
        return within.lowerBound < Self.urgentRunOut
    }

    var body: some View {
        if let text = runOut ?? line.map(text(for:)) ?? (notes.isEmpty ? nil : inlineNote) {
            Text(text)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(isUrgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .underline(isHovering, pattern: .dot, color: .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentShape(.rect)
                .onHover(perform: hover)
                .popover(isPresented: $showsBreakdown, arrowEdge: .bottom) {
                    GainBreakdown(window: window, short: short, line: line, forecast: forecast, notes: notes, now: now)
                }
                .onAppear {
                    if LaunchOptions.demo == .hover, window == .session { openSoon() }
                }
                // The hover card's content, without hovering: read as the value, or opened by name.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityValue(details)
                .accessibilityAction(named: showsBreakdown ? Text("Hide Details") : Text("Show Details")) { showsBreakdown.toggle() }
        } else {
            // Keeps both columns the same height.
            Text(verbatim: " ").font(.callout).hidden()
        }
    }

    private func text(for line: GainLine) -> String {
        switch window {
        case .session: String(localized: "+\(line.points)% \(line.lastDate.map { TimeText.span(until: $0, now: now) } ?? "")")
        case .weekly: String(localized: "+\(line.points)% · \(line.lastDate.map { TimeText.later($0, now: now) } ?? "")")
        }
    }

    /// Everything the card says, in its order: the resets, the pace and its basis, the notes.
    private var details: String {
        var lines: [String] = []
        if let line {
            lines.append(String(localized: "\(window.title(short)) resets"))
            lines += (line.items + line.later).map { "+\($0.points)% \(window == .session ? TimeText.soon($0.date, now: now) : TimeText.later($0.date, now: now))" }
        }
        if let forecast {
            lines.append(PaceText.sentence(forecast, window: window, short: short, now: now))
            lines.append(PaceText.basis(forecast, window: window))
        }
        return (lines + notes).joined(separator: ", ")
    }

    private func hover(_ hovering: Bool) {
        isHovering = hovering
        pendingOpen?.cancel()
        if hovering {
            openSoon()
        } else {
            showsBreakdown = false
        }
    }

    private func openSoon() {
        pendingOpen = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            showsBreakdown = true
        }
    }
}

/// The resets behind the gain line, then the pace sentence and what it rests on.
struct GainBreakdown: View {
    let window: PoolWindow
    let short: ShortWindow
    let line: GainLine?
    let forecast: Pace.Forecast?
    /// How old the numbers are and what's left out of them; see `PoolNotes`.
    var notes: [String] = []
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let line {
                Text("\(window.title(short)) resets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 1)
                ForEach(line.items + line.later, id: \.date) { item in
                    HStack(spacing: 18) {
                        Text(verbatim: "+\(item.points)%")
                            .fontWeight(.medium)
                        Spacer(minLength: 0)
                        Text(window == .session ? TimeText.soon(item.date, now: now) : TimeText.later(item.date, now: now))
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
            }
            if let forecast {
                Text("Pace")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, line == nil ? 0 : 6)
                    .padding(.bottom, 1)
                Text(PaceText.sentence(forecast, window: window, short: short, now: now))
                    .fixedSize(horizontal: false, vertical: true)
                Text(PaceText.basis(forecast, window: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 150)
    }
}

// MARK: - Accounts

private struct AccountsDisclosure: View {
    let isExpanded: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Accounts")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(.quaternary.opacity(isHovering ? 1 : 0), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(isExpanded ? String(localized: "Hide accounts") : String(localized: "Show accounts"))
    }
}

private enum AccountColumns {
    static let meter: CGFloat = 38
    static let share: CGFloat = 34
    static let spacing: CGFloat = 8
}

private struct AccountsSection: View {
    let details: [AccountDetail]
    /// Logins of providers without usage windows, listed under the pool's own.
    let healthOnly: [AccountDetail]
    /// With logins from more than one provider, each row carries its provider's logo.
    let showsProviders: Bool
    let short: ShortWindow
    let isOffline: Bool
    let hasManagementKey: Bool
    let proxyReadAt: Date?
    let usageAPIReadAt: Date?
    let proxyURL: URL

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            columnHeader
                .cascadeIn(index: 0)
            if details.count + healthOnly.count > Self.visibleRows {
                ScrollView {
                    rows
                }
                .frame(height: CGFloat(Self.visibleRows) * Self.rowPitch)
            } else {
                rows
            }
            let held = details.filter(\.isStuckInCooldown)
            if !held.isEmpty {
                StuckCooldownLine(count: held.count, command: StuckCooldown.resetCommand(baseURL: proxyURL, authIndexes: held.compactMap(\.authIndex)))
                    .padding(.top, 2)
                    .cascadeIn(index: details.count + healthOnly.count + 1)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(freshness(now: context.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(contrast.faint)
            }
            .padding(.top, 2)
            .cascadeIn(index: details.count + healthOnly.count + 1)
        }
    }

    /// Beyond this many logins the list scrolls instead of growing the panel.
    private static let visibleRows = 8
    private static let rowPitch: CGFloat = 23

    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                AccountRow(detail: detail, short: short, showsProvider: showsProviders, index: index + 1)
            }
            if !healthOnly.isEmpty {
                Text("Health only")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(contrast.faint)
                    .padding(.top, details.isEmpty ? 0 : 3)
                    .help("These providers report no usage windows, so they never count toward a pool.")
                    .cascadeIn(index: details.count + 1)
                ForEach(Array(healthOnly.enumerated()), id: \.element.id) { index, detail in
                    AccountRow(detail: detail, short: short, showsProvider: showsProviders, index: details.count + index + 1)
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: AccountColumns.spacing) {
            Spacer()
            Text(verbatim: short.abbreviation).frame(width: AccountColumns.meter)
            Text("Week").frame(width: AccountColumns.meter)
            Text("Share")
                .frame(width: AccountColumns.share, alignment: .trailing)
                .help("Share of new threads the proxy sends to each account")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(contrast.faint)
    }

    private func freshness(now: Date) -> String {
        if isOffline { return String(localized: "Offline · cached readings only") }
        let proxy = proxyReadAt.map { String(localized: "From proxy · \(TimeText.ago($0, now: now))") }
            ?? (hasManagementKey ? String(localized: "No proxy reading") : String(localized: "No management access"))
        guard let usageAPIReadAt else { return proxy }
        return String(localized: "\(proxy) · Usage API · \(TimeText.ago(usageAPIReadAt, now: now))")
    }
}

/// Accounts the proxy keeps skipping though their quota is back. Ebb never resets them itself.
private struct StuckCooldownLine: View {
    let count: Int
    /// Empty when no held login has a usable auth index.
    let command: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(StuckCooldown.line(count: count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !command.isEmpty {
                Spacer(minLength: 0)
                Button("Copy Fix") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Copies the curl command for CLIProxyAPI's reset-quota call. Set MANAGEMENT_KEY to your management key before running it.")
            }
        }
    }
}

/// The provider's status page reports a problem with what this pool runs on.
private struct IncidentLine: View {
    let text: String
    let page: URL

    var body: some View {
        let host = page.host() ?? String(localized: "the status page")
        Link(destination: page) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(IncidentLabelStyle())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Open \(host)")
    }
}

private struct IncidentLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.orange)
            configuration.title
        }
    }
}

private struct AccountRow: View {
    let detail: AccountDetail
    let short: ShortWindow
    let showsProvider: Bool
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: AccountColumns.spacing) {
            StatusDot(status: detail.status, readAt: detail.readAt, message: detail.healthMessage)
            HStack(spacing: 5) {
                if showsProvider {
                    ProviderLogo(provider: detail.provider)
                        .foregroundStyle(.secondary)
                }
                Text(detail.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let badge = detail.planBadge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(hoverLines.joined(separator: "\n"))
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                MiniMeter(free: detail.sessionFree, window: .session, short: short, isUncapped: false, index: index)
                MiniMeter(free: detail.weeklyFree, window: .weekly, short: short, isUncapped: detail.hasNoWeeklyCap, index: index)
                Text(verbatim: detail.share.map { "\(Int($0.rounded()))%" } ?? "—")
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(detail.share == nil ? .tertiary : .secondary)
                    .frame(width: AccountColumns.share, alignment: .trailing)
            }
        }
        .font(.callout)
        .opacity(detail.status == .active || detail.status == .health(.ok) ? 1 : 0.6)
        .animation(reduceMotion ? nil : .smooth, value: detail)
        .cascadeIn(index: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowLabel)
        .accessibilityValue(hoverLines.joined(separator: ", "))
    }

    private var hoverLines: [String] {
        [detail.email, detail.extraUsage?.text, detail.isStuckInCooldown ? String(localized: "Still held in cooldown by CLIProxyAPI, though its quota is back") : nil]
            .compactMap { $0 }
    }

    /// Text in place of the meters: for logins whose windows can't be read, or that have none.
    private var note: String? {
        switch detail.status {
        case .limitsUnavailable: String(localized: "Limits not available")
        case let .health(state):
            switch state {
            case .ok: ProviderDisplay.title(detail.provider)
            case let .coolingDown(until): until.map { String(localized: "Retry \(TimeText.later($0, now: .now))") } ?? String(localized: "Cooling down")
            case .failing: String(localized: "Failing")
            case .disabled: String(localized: "Disabled")
            }
        default: nil
        }
    }

    /// Name, plan, status, both windows and share, as one VoiceOver element; the hover lines are its value.
    private var rowLabel: String {
        let status = StatusDot.description(status: detail.status, readAt: detail.readAt, message: detail.healthMessage)
        if let note { return [detail.label, detail.planBadge, status, note].compactMap { $0 }.joined(separator: ", ") }
        return AccessibilityText.accountRow(
            name: detail.label, plan: detail.planBadge, status: status, short: short,
            sessionFree: detail.sessionFree.map { PoolLevel($0).percent }, weeklyFree: detail.weeklyFree.map { PoolLevel($0).percent },
            hasNoWeeklyCap: detail.hasNoWeeklyCap, share: detail.share.map { Int($0.rounded()) }
        )
    }
}

private struct StatusDot: View {
    let status: AccountDetail.Status
    let readAt: Date?
    var message: String?

    var body: some View {
        let description = Self.description(status: status, readAt: readAt, message: message)
        Group {
            switch status {
            case .active: Circle().fill(.green)
            case .stale: Circle().fill(.yellow)
            case .retired: Circle().strokeBorder(.secondary, lineWidth: 1.2)
            case .disabledByUser, .health(.disabled): Circle().fill(.tertiary)
            case .limitsUnavailable: Circle().strokeBorder(.yellow, lineWidth: 1.2)
            case .health(.ok): Circle().fill(.green)
            case .health(.coolingDown): Circle().fill(.orange)
            case .health(.failing): Circle().fill(.red)
            }
        }
        .frame(width: 7, height: 7)
        .help(description)
        .accessibilityLabel(description)
    }

    static func description(status: AccountDetail.Status, readAt: Date?, message: String?) -> String {
        switch status {
        case .active: String(localized: "Counted in the pool")
        case .stale: readAt.map { String(localized: "Last read \(TimeText.ago($0, now: .now)); counted as last seen") } ?? String(localized: "Not read yet")
        case .retired: String(localized: "Retired by Ebb: its plan isn't active")
        case .disabledByUser, .health(.disabled): String(localized: "Disabled in the proxy")
        case .limitsUnavailable: String(localized: "The provider refused the proxy's token for its usage, so this login is left out of the pool")
        case .health(.ok): String(localized: "Working; this provider reports no usage windows")
        case .health(.coolingDown): message.map { String(localized: "Held back by the proxy: \($0)") } ?? String(localized: "Held back by the proxy")
        case .health(.failing): message.map { String(localized: "Failing: \($0)") } ?? String(localized: "Failing")
        }
    }
}

/// A row's free share for one window; fills from empty when the row appears.
private struct MiniMeter: View {
    let free: Double?
    let window: PoolWindow
    let short: ShortWindow
    /// Read, and the plan simply has no cap for this window.
    let isUncapped: Bool
    let index: Int

    @State private var isRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if let free {
                let level = PoolLevel(free)
                Capsule()
                    .fill(contrast.track)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(level.warningTint ?? .primary.opacity(contrast == .increased ? 1 : 0.75))
                                .frame(width: geometry.size.width * (isRevealed ? min(max(free, 0), 100) / 100 : 0))
                        }
                    }
                    .frame(height: 4)
                    .help(String(localized: "\(window.title(short)): \(level.percent)% free"))
                    .animation(reduceMotion ? nil : .smooth, value: free)
            } else if isUncapped {
                Text(verbatim: "∞")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("No weekly limit")
            } else {
                Text(verbatim: "—")
                    .font(.caption)
                    .foregroundStyle(contrast.faint)
                    .help("No reading")
            }
        }
        .frame(width: AccountColumns.meter)
        .onAppear {
            guard !reduceMotion else {
                isRevealed = true
                return
            }
            withAnimation(Motion.reveal.delay(0.08 + Motion.stagger * Double(index))) { isRevealed = true }
        }
    }
}

private struct CascadeIn: ViewModifier {
    let index: Int

    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : -5)
            .onAppear {
                let animation = reduceMotion ? Animation.easeOut(duration: 0.2) : Motion.reveal.delay(Motion.stagger * Double(index))
                withAnimation(animation) { isShown = true }
            }
    }
}

private extension View {
    /// Fades and settles in after `index` rows' worth of delay.
    func cascadeIn(index: Int) -> some View {
        modifier(CascadeIn(index: index))
    }
}

extension ColorSchemeContrast {
    /// Tertiary text and quaternary tracks read at the standard contrast; someone who asked
    /// for more gets them a step stronger.
    var faint: HierarchicalShapeStyle { self == .increased ? .secondary : .tertiary }
    var track: HierarchicalShapeStyle { self == .increased ? .tertiary : .quaternary }
}
