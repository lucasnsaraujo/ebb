import AppKit
import EbbCore
import SwiftUI

/// The panel's body on a fresh Mac, in place of the pool, until CLIProxyAPI runs and takes a
/// management key. Ebb never edits the proxy's files: each change there is a command to copy.
/// `ProxySetup` decides when it shows and which step is open.
struct ProxySetupView: View {
    /// Set by Continue Without a Key, which shows only while some login can be read without one.
    static let skippedKey = "skippedSetup"
    private static let quickStart = URL(string: "https://help.router-for.me/introduction/quick-start.html")!

    let setup: ProxySetup
    let connection: ProxyConnection
    let store: PoolStore

    @AppStorage(skippedKey) private var isSkipped = false
    @State private var draftKey = ""
    @State private var provider = ProxySetup.loginProviders[0]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            proxyStep
            accountStep
            keyStep
            // Claude logins are read without the proxy or a key, so whoever has some can skip from any step.
            if setup.hasLogins {
                Button("Continue Without a Key") { isSkipped = true }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("Ebb then reads only the Claude logins on this Mac, with routing and auto-retire off. You can add a key later in Settings → Connection.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : Motion.reveal, value: setup)
        .task {
            // Looks again every few seconds while open, so a command run in Terminal shows here on its own.
            guard LaunchOptions.snapshotDirectory == nil else { return }
            while !Task.isCancelled {
                await connection.lookForProxy()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Steps

    private var proxyStep: some View {
        SetupStep(number: 1, title: proxyTitle, progress: proxyProgress, hasContent: proxyHasContent) {
            switch setup.proxy {
            case .notInstalled:
                CopyableCommand(text: "brew install \(ProxyInstall.formula)")
                Link("Other ways to install", destination: Self.quickStart)
                    .font(.callout)
            case let .stopped(install) where install.launch == nil:
                CopyableCommand(text: install.command(configFile: connection.configFile?.path))
            case .stopped:
                if case let .failed(message) = connection.startState {
                    Text("Couldn't start: \(message)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .looking, .running:
                EmptyView()
            }
        } accessory: {
            if case let .stopped(install) = setup.proxy, install.launch != nil {
                Button(connection.startState == .starting ? String(localized: "Starting…") : String(localized: "Start"), action: start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(connection.startState == .starting)
                    .help("Runs brew services start \(ProxyInstall.formula), which also starts it at login.")
            }
        }
    }

    /// A Homebrew install starts from the button beside the title, so it has nothing below it unless that failed.
    private var proxyHasContent: Bool {
        switch setup.proxy {
        case .notInstalled: true
        case let .stopped(install):
            if case .failed = connection.startState { true } else { install.launch == nil }
        case .looking, .running: false
        }
    }

    private var proxyTitle: LocalizedStringKey {
        switch setup.proxy {
        case .looking: "Looking for CLIProxyAPI…"
        case .notInstalled: "Install CLIProxyAPI"
        case .stopped: "Start CLIProxyAPI"
        case .running: "CLIProxyAPI is running"
        }
    }

    private var proxyProgress: SetupProgress {
        switch setup.proxy {
        case .looking: .looking
        case .notInstalled, .stopped: .current
        case .running: .done
        }
    }

    private var accountStep: some View {
        let progress: SetupProgress = setup.hasLogins ? .done : setup.proxy == .running ? .current : .upcoming
        return SetupStep(number: 2, title: setup.hasLogins ? "^[\(store.state.details.count) account](inflect: true) signed in" : "Sign in to an account", progress: progress) {
            if let command = ProxySetup.loginCommand(provider: provider, install: connection.install, configFile: connection.configFile?.path) {
                CopyableCommand(text: command)
            }
        } accessory: {
            Picker("Provider", selection: $provider) {
                ForEach(ProxySetup.loginProviders, id: \.self) { name in
                    Text(ProviderDisplay.title(name)).tag(name)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, -4)
        }
    }

    private var keyStep: some View {
        SetupStep(number: 3, title: "Enter the management key", progress: setup.key == .waiting ? .upcoming : .current) {
            if setup.key == .managementOff {
                Text("CLIProxyAPI's management API is off. Set a secret-key under management in its config file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let configFile = connection.configFile {
                    Button("Show Config File") {
                        NSWorkspace.shared.activateFileViewerSelecting([configFile])
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            keyField
            switch setup.key {
            case .refused:
                Text("\(Text("CLIProxyAPI refused this key.").foregroundStyle(.red)) Five wrong keys lock this Mac out for 30 minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .needed, .checking:
                Text("The secret-key you set under management in CLIProxyAPI's config file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .managementOff, .waiting:
                EmptyView()
            }
        }
    }

    private var keyField: some View {
        let isChecking = setup.key == .checking
        return HStack(spacing: 8) {
            SecureField("Management key", text: $draftKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
                .disabled(isChecking)
            Button(action: connect) {
                Text("Connect")
                    .opacity(isChecking ? 0 : 1)
                    .overlay {
                        if isChecking { ProgressView().controlSize(.mini) }
                    }
            }
            .buttonStyle(.borderedProminent)
            .disabled(ManagementKey(draftKey) == nil || isChecking)
        }
    }

    // MARK: - Actions

    private func start() {
        Task {
            await connection.startProxy()
            guard connection.startState == .idle else { return }
            store.proxyWasStarted()
            await connection.lookForProxy()
        }
    }

    private func connect() {
        let key = draftKey
        guard ManagementKey(key) != nil else { return }
        Task {
            await connection.save(key: key)
            if connection.keyState == .valid { draftKey = "" }
        }
    }
}

private enum SetupProgress: Equatable {
    case looking, current, done, upcoming
}

/// A numbered step: a check once done, its content only while it's the one to act on.
private struct SetupStep<Content: View, Accessory: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let progress: SetupProgress
    /// Whether the open step draws anything below its title.
    let hasContent: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        number: Int, title: LocalizedStringKey, progress: SetupProgress, hasContent: Bool = true,
        @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.number = number
        self.title = title
        self.progress = progress
        self.hasContent = hasContent
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            indicator
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.body.weight(progress == .current ? .semibold : .regular))
                        .foregroundStyle(titleStyle)
                        .fixedSize(horizontal: false, vertical: true)
                    if progress == .current {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                if progress == .current, hasContent {
                    VStack(alignment: .leading, spacing: 7) {
                        content
                    }
                    .transition(reduceMotion ? .opacity.animation(.easeInOut(duration: 0.2)) : .opacity.combined(with: .offset(y: -4)))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var titleStyle: AnyShapeStyle {
        switch progress {
        case .current, .looking: AnyShapeStyle(.primary)
        case .done: AnyShapeStyle(.secondary)
        case .upcoming: AnyShapeStyle(.tertiary)
        }
    }

    private var indicator: some View {
        Group {
            switch progress {
            case .looking:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
                    .symbolEffect(.pulse, options: .repeat(.continuous), isActive: reduceMotion)
            case .current:
                Image(systemName: "\(number).circle.fill")
                    .foregroundStyle(.primary)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .upcoming:
                Image(systemName: "\(number).circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.body)
        .imageScale(.large)
        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        .frame(width: 18)
        .accessibilityLabel(accessibilityStatus)
    }

    private var accessibilityStatus: String {
        switch progress {
        case .looking: String(localized: "Checking")
        case .current: String(localized: "Step \(number)")
        case .done: String(localized: "Done")
        case .upcoming: String(localized: "Step \(number), later")
        }
    }
}

/// A Terminal command with a button that copies it.
private struct CopyableCommand: View {
    let text: String

    @State private var didCopy = false
    @State private var resetCopy: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .foregroundStyle(didCopy ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel(didCopy ? String(localized: "Copied") : String(localized: "Copy"))
        }
        .padding(.vertical, 7)
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7, style: .continuous))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        resetCopy?.cancel()
        resetCopy = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
