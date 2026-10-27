import AppKit
import EbbCore
import ServiceManagement

/// `ebb --uninstall-data`: lists Ebb's files and links, and removes them only after a yes.
func uninstallData(isConfirmed: Bool) -> Never {
    // Quitting Ebb writes its usage ledger again, so it would undo the removal.
    guard NSRunningApplication.runningApplications(withBundleIdentifier: EbbData.bundleIdentifier).isEmpty else {
        fail("Ebb is running. Quit it first, then run this again.")
    }
    let data = EbbData()
    let present = data.existing()
    if present.isEmpty {
        print("No Ebb files found.")
    } else {
        print("This removes:")
        present.forEach { print("  \(shortPath($0))") }
        print("Ebb.app and CLIProxyAPI's config and logins stay.")
        if !isConfirmed {
            guard isatty(STDIN_FILENO) != 0 else { fail("Not a terminal, so nothing was removed. Add --yes to confirm.") }
            print("Remove these? Type yes to continue: ", terminator: "")
            fflush(stdout)
            guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                print("Nothing removed.")
                exit(0)
            }
        }
    }

    let removal = data.remove()
    // The files are gone; this makes macOS forget the settings it still holds in memory.
    UserDefaults.standard.removePersistentDomain(forName: EbbData.bundleIdentifier)
    removal.removed.forEach { print("Removed \(shortPath($0))") }
    for failure in removal.failures {
        FileHandle.standardError.write(Data("Couldn't remove \(shortPath(failure.url)): \(failure.reason)\n".utf8))
    }
    if unregisterLoginItem() {
        print("Removed Ebb's login item.")
    } else {
        print("If Ebb is still listed under System Settings → General → Login Items & Extensions, switch it off there.")
    }
    exit(removal.failures.isEmpty ? 0 : 1)
}

/// From the Ebb app's bundle only; run from this tool, macOS may not know the app, so a refusal isn't an error.
private func unregisterLoginItem() -> Bool {
    let service = SMAppService.mainApp
    guard service.status == .enabled || service.status == .requiresApproval else { return false }
    return (try? service.unregister()) != nil && service.status != .enabled
}

private func shortPath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}
