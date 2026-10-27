import EbbCore
import Foundation
import Testing
@testable import Ebb

/// `ebb --uninstall-data` and docs/paths.md list the paths by hand; this keeps them in step with what the app writes.
@Suite struct EbbPathsTests {
    @Test func everyFileTheAppWritesIsOneTheUninstallCommandRemoves() {
        let removed = EbbData(home: EbbPaths.home).locations.map(\.path)
        let written = [
            EbbPaths.applicationSupport, EbbPaths.managementKeyFile, EbbPaths.demandFile, PoolStatus.defaultFile,
            EbbPaths.configDirectory, EbbPaths.modeFile,
            EbbPaths.retiredAccounts(remoteHost: nil).file, EbbPaths.retiredAccounts(remoteHost: "proxy.example.com").file,
            EbbPaths.cacheDirectory, EbbPaths.usageCache(for: "a@example.com"), EbbPaths.planCache(for: "a@example.com"),
        ]
        for url in written {
            #expect(removed.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }, "\(url.path) is written but not removed")
        }
    }
}
