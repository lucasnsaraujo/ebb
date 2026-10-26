import EbbCore
import SwiftUI

/// The window under the menu bar item: the 5-hour and weekly windows side by side,
/// each with what comes back, and the accounts behind them on request.
struct PoolPanel: View {
    let store: PoolStore
    let visibility: Visibility
    let connection: ProxyConnection

    @State private var showsAccounts = LaunchOptions.demo == .accounts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            if let summary = store.summary {
                WindowPair(summary: summary)
                    .contentShape(.rect)
                    .onTapGesture(perform: toggleAccounts)
            } else {
                noReading
            }
            AccountsDisclosure(isExpanded: showsAccounts, action: toggleAccounts)
                .padding(.top, 12)
            if showsAccounts {
                AccountsSection(
                    details: store.accountDetails,
                    isOffline: store.isOffline,
                    hasManagementKey: connection.endpoint != nil,
                    proxyReadAt: store.proxyReadAt,
                    usageAPIReadAt: store.usageAPIReadAt
                )
                    .padding(.top, 4)
                    .transition(.opacity)
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
        .onAppear {
            store.panelDidOpen()
            if LaunchOptions.demo == .disclosure { playDisclosureDemo() }
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

    private var header: some View {
        HStack(spacing: 6) {
            ClaudeMark()
                .fill(Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: 14, height: 14)
            Text("Ebb")
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }

    private var noReading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("–")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            Text("No account could be read yet.")
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
                    .symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: store.isRefreshing)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .accessibilityLabel("Refresh")

            if store.summary?.isPartial == true {
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

enum Motion {
    /// Delay between consecutive rows as they cascade in.
    static let stagger = 0.03
    static let reveal = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Springs open, closes quicker; a plain cross-fade with Reduce Motion.
    static func disclosure(expanding: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        return expanding ? reveal : .smooth(duration: 0.2)
    }
}

// MARK: - Windows

private struct WindowPair: View {
    let summary: PoolSummary

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            HStack(alignment: .top, spacing: 20) {
                WindowColumn(
                    window: .session,
                    freePercent: summary.session.freePercent,
                    line: GainLine.session(summary.session.resets.filter { $0.date > now }),
                    now: now
                )
                WindowColumn(
                    window: .weekly,
                    freePercent: summary.weekly.freePercent,
                    line: GainLine.weekly(summary.weekly.resets.filter { $0.date > now }),
                    now: now
                )
            }
        }
    }
}

private struct WindowColumn: View {
    let window: PoolWindow
    let freePercent: Double
    let line: GainLine?
    let now: Date

    var body: some View {
        let level = PoolLevel(freePercent)
        VStack(alignment: .leading, spacing: 0) {
            Text(window.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(level.percent)%")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(level.percent)))
                    .foregroundStyle(level.warningTint ?? .primary)
                Text("free")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Meter(free: freePercent, comingBack: Double(line?.points ?? 0), tint: level.warningTint ?? .primary)
                .frame(height: 6)
                .padding(.top, 5)
            GainLabel(window: window, line: line, now: now)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth, value: level.percent)
    }
}

/// Free share as a capsule; what comes back soon shows as a lighter segment after it.
private struct Meter: View {
    let free: Double
    let comingBack: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let freeWidth = width * min(max(free, 0), 100) / 100
                    HStack(spacing: 0) {
                        Rectangle().fill(tint).frame(width: freeWidth)
                        Rectangle().fill(tint.opacity(0.28)).frame(width: min(width * comingBack / 100, width - freeWidth))
                    }
                }
            }
            .clipShape(.capsule)
            .animation(.smooth, value: free)
            .accessibilityHidden(true)
    }
}

/// "+5% in next 4 h" or "+54% · Tue 22:00"; hovering shows the resets behind it.
private struct GainLabel: View {
    let window: PoolWindow
    let line: GainLine?
    let now: Date

    @State private var isHovering = false
    @State private var showsBreakdown = false
    @State private var pendingOpen: Task<Void, Never>?

    var body: some View {
        if let line {
            Text(text(for: line))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .underline(isHovering, pattern: .dot, color: .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentShape(.rect)
                .onHover(perform: hover)
                .popover(isPresented: $showsBreakdown, arrowEdge: .bottom) {
                    GainBreakdown(window: window, line: line, now: now)
                }
                .onAppear {
                    if LaunchOptions.demo == .hover, window == .session { openSoon() }
                }
                .accessibilityHint(breakdownSummary(line))
        } else {
            // Keeps both columns the same height.
            Text(verbatim: " ").font(.callout).hidden()
        }
    }

    private func text(for line: GainLine) -> String {
        switch window {
        case .session: "+\(line.points)% \(line.lastDate.map { TimeText.span(until: $0, now: now) } ?? "")"
        case .weekly: "+\(line.points)% · \(line.lastDate.map { TimeText.later($0, now: now) } ?? "")"
        }
    }

    private func breakdownSummary(_ line: GainLine) -> String {
        (line.items + line.later).map { "+\($0.points)% \(TimeText.later($0.date, now: now))" }.joined(separator: ", ")
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

private struct GainBreakdown: View {
    let window: PoolWindow
    let line: GainLine
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(window == .session ? "5-hour resets" : "Weekly resets")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 1)
            ForEach(line.items + line.later, id: \.date) { item in
                HStack(spacing: 18) {
                    Text("+\(item.points)%")
                        .fontWeight(.medium)
                    Spacer(minLength: 0)
                    Text(window == .session ? TimeText.soon(item.date, now: now) : TimeText.later(item.date, now: now))
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
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
        .accessibilityLabel(isExpanded ? "Hide accounts" : "Show accounts")
    }
}

private enum AccountColumns {
    static let meter: CGFloat = 38
    static let share: CGFloat = 34
    static let spacing: CGFloat = 8
}

private struct AccountsSection: View {
    let details: [AccountDetail]
    let isOffline: Bool
    let hasManagementKey: Bool
    let proxyReadAt: Date?
    let usageAPIReadAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            columnHeader
                .cascadeIn(index: 0)
            if details.count > Self.visibleRows {
                ScrollView {
                    rows
                }
                .frame(height: CGFloat(Self.visibleRows) * Self.rowPitch)
            } else {
                rows
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(freshness(now: context.date))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
            .cascadeIn(index: details.count + 1)
        }
    }

    /// Beyond this many logins the list scrolls instead of growing the panel.
    private static let visibleRows = 8
    private static let rowPitch: CGFloat = 23

    private var rows: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(details.enumerated()), id: \.element.id) { index, detail in
                AccountRow(detail: detail, index: index + 1)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: AccountColumns.spacing) {
            Spacer()
            Text("5h").frame(width: AccountColumns.meter)
            Text("Week").frame(width: AccountColumns.meter)
            Text("Share")
                .frame(width: AccountColumns.share, alignment: .trailing)
                .help("Share of new threads the proxy sends to each account")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.tertiary)
    }

    private func freshness(now: Date) -> String {
        if isOffline { return "Offline · cached readings only" }
        let proxy = proxyReadAt.map { "From proxy · \(TimeText.ago($0, now: now))" } ?? (hasManagementKey ? "Proxy unreachable" : "No management access")
        guard let usageAPIReadAt else { return proxy }
        return "\(proxy) · Usage API · \(TimeText.ago(usageAPIReadAt, now: now))"
    }
}

private struct AccountRow: View {
    let detail: AccountDetail
    let index: Int

    var body: some View {
        HStack(spacing: AccountColumns.spacing) {
            StatusDot(status: detail.status, readAt: detail.readAt)
            HStack(spacing: 5) {
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
            .help(detail.email)
            MiniMeter(free: detail.sessionFree, window: .session, isUncapped: false, index: index)
            MiniMeter(free: detail.weeklyFree, window: .weekly, isUncapped: detail.hasNoWeeklyCap, index: index)
            Text(detail.share.map { "\(Int($0.rounded()))%" } ?? "—")
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(detail.share == nil ? .tertiary : .secondary)
                .frame(width: AccountColumns.share, alignment: .trailing)
        }
        .font(.callout)
        .opacity(detail.status == .active ? 1 : 0.6)
        .animation(.smooth, value: detail)
        .cascadeIn(index: index)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusDot: View {
    let status: AccountDetail.Status
    let readAt: Date?

    var body: some View {
        Group {
            switch status {
            case .active: Circle().fill(.green)
            case .stale: Circle().fill(.yellow)
            case .retired: Circle().strokeBorder(.secondary, lineWidth: 1.2)
            case .disabledByUser: Circle().fill(.tertiary)
            }
        }
        .frame(width: 7, height: 7)
        .help(description)
        .accessibilityLabel(description)
    }

    private var description: String {
        switch status {
        case .active: "Counted in the pool"
        case .stale: readAt.map { "Last read \(TimeText.ago($0, now: .now)); counted as last seen" } ?? "Not read yet"
        case .retired: "Retired by Ebb: its plan isn't active"
        case .disabledByUser: "Disabled in the proxy"
        }
    }
}

/// A row's free share for one window; fills from empty when the row appears.
private struct MiniMeter: View {
    let free: Double?
    let window: PoolWindow
    /// Read, and the plan simply has no cap for this window.
    let isUncapped: Bool
    let index: Int

    @State private var isRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let free {
                let level = PoolLevel(free)
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(level.warningTint ?? .primary.opacity(0.75))
                                .frame(width: geometry.size.width * (isRevealed ? min(max(free, 0), 100) / 100 : 0))
                        }
                    }
                    .frame(height: 4)
                    .help("\(window.title): \(level.percent)% free")
                    .animation(.smooth, value: free)
            } else if isUncapped {
                Text("∞")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("No weekly limit")
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
