import Foundation
import Observation
import Sparkle
import UserNotifications

/// Sparkle's updater, started only in an installed app bundle, so `swift run`, `--demo` and `--snapshot` never check.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    let isStarted: Bool
    /// False while a check or an update is under way.
    private(set) var canCheckForUpdates = false
    var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let userDriverDelegate = UserDriverDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private init() {
        isStarted = Bundle.main.bundleURL.pathExtension == "app"
            && LaunchOptions.snapshotDirectory == nil && !LaunchOptions.isDemo
        controller = SPUStandardUpdaterController(startingUpdater: isStarted, updaterDelegate: nil, userDriverDelegate: userDriverDelegate)
        checksAutomatically = isStarted && controller.updater.automaticallyChecksForUpdates
        guard isStarted else { return }
        // Sparkle changes both on the main thread.
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncFromSparkle() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncFromSparkle() }
            },
        ]
    }

    private func syncFromSparkle() {
        canCheckForUpdates = controller.updater.canCheckForUpdates
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Ebb has no Dock icon, so Sparkle opens a scheduled update alert behind other windows, where it's easy
/// to miss. A notification points to it, only if Ebb may already post them: an update never asks for permission.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { await postUpdateAvailable(version: version) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [updateNotificationID])
    }
}

private let updateNotificationID = "update-available"

private func postUpdateAvailable(version: String) async {
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .authorized else { return }
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Ebb \(version) is available")
    content.body = String(localized: "Click to see what's new and install it.")
    try? await center.add(UNNotificationRequest(identifier: updateNotificationID, content: content, trigger: nil))
}
