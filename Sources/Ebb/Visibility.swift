import AppKit
import Observation

/// `~/.config/ebb/mode`: `always`, `apps` or `off`. Scripts may write it; Ebb applies it at once.
enum DisplayMode: String, CaseIterable, Identifiable {
    case always, apps, off

    var id: Self { self }

    var title: String {
        switch self {
        case .always: "Always"
        case .apps: "While Chosen Apps Are Running"
        case .off: "Never"
        }
    }
}

/// Decides whether the menu bar item is on screen. Event-driven: a file watcher
/// for the mode file and workspace notifications for the chosen apps, no polling.
@MainActor
@Observable
final class Visibility {
    private static let watchedAppsKey = "watchedApps"

    private(set) var mode: DisplayMode
    /// Bundle identifiers of the apps that show the item in `apps` mode.
    private(set) var watchedApps: [String]
    private var runningWatchedApps: Set<String> = []

    var isVisible: Bool {
        mode == .always || (mode == .apps && !runningWatchedApps.isEmpty)
    }

    @ObservationIgnored var onVisibilityChange: ((Bool) -> Void)?
    @ObservationIgnored private var modeWatcher: FileWatcher?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        mode = Self.readMode()
        watchedApps = UserDefaults.standard.stringArray(forKey: Self.watchedAppsKey) ?? []
        runningWatchedApps = Self.running(among: watchedApps)
        modeWatcher = FileWatcher(file: EbbPaths.modeFile) { [weak self] in self?.update { $0.mode = Self.readMode() } }
        watchWorkspace()
    }

    func setMode(_ newMode: DisplayMode) {
        try? FileManager.default.createDirectory(at: EbbPaths.configDirectory, withIntermediateDirectories: true)
        try? Data(newMode.rawValue.utf8).write(to: EbbPaths.modeFile)
        update { $0.mode = newMode }
    }

    func setWatchedApps(_ bundleIdentifiers: [String]) {
        UserDefaults.standard.set(bundleIdentifiers, forKey: Self.watchedAppsKey)
        update {
            $0.watchedApps = bundleIdentifiers
            $0.runningWatchedApps = Self.running(among: bundleIdentifiers)
        }
    }

    private func update(_ change: (Visibility) -> Void) {
        let wasVisible = isVisible
        change(self)
        if isVisible != wasVisible { onVisibilityChange?(isVisible) }
    }

    /// A missing or unreadable file means `always`, so a new install shows up.
    private static func readMode() -> DisplayMode {
        let text = (try? String(contentsOf: EbbPaths.modeFile, encoding: .utf8)) ?? ""
        return DisplayMode(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .always
    }

    private static func running(among bundleIdentifiers: [String]) -> Set<String> {
        let watched = Set(bundleIdentifiers)
        return Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter(watched.contains))
    }

    private func watchWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, isRunning) in [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let bundleIdentifier = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    guard let self, self.watchedApps.contains(bundleIdentifier) else { return }
                    self.update { visibility in
                        if isRunning {
                            visibility.runningWatchedApps.insert(bundleIdentifier)
                        } else {
                            // Another copy of the same app may still be open.
                            visibility.runningWatchedApps = Self.running(among: visibility.watchedApps)
                        }
                    }
                }
            })
        }
    }
}

/// Calls `onChange` on the main queue whenever `file` is written, replaced or deleted.
/// Watches the folder too, because editors and `mv` swap the file's inode.
@MainActor
final class FileWatcher {
    private let file: URL
    private let onChange: @MainActor () -> Void
    private var folderSource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        self.file = file
        self.onChange = onChange
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folderSource = makeSource(path: folder.path, events: .write)
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: file.path, events: [.write, .extend, .delete, .rename])
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if path != self.file.path || source.data.contains(.delete) || source.data.contains(.rename) {
                    self.watchFile()
                }
                self.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
