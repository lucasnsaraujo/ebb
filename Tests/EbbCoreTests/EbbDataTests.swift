import Foundation
import Testing
@testable import EbbCore

/// A throwaway home with Ebb's files and, beside them, everything `--uninstall-data` must leave alone.
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "ebb-data-\(UUID().uuidString)")
    var home: URL { root.appending(path: "home") }
    var system: URL { root.appending(path: "usr/local/bin") }
    var user: URL { home.appending(path: ".local/bin") }
    var data: EbbData { EbbData(home: home, commandDirectories: [system, user]) }

    private let manager = FileManager.default

    init() throws {
        for path in EbbData.homeRelativePaths where !path.hasSuffix(".plist") && !path.hasSuffix(".binarycookies") {
            try write("x", at: home.appending(path: path).appending(path: "file"))
        }
        for path in EbbData.homeRelativePaths where path.hasSuffix(".plist") || path.hasSuffix(".binarycookies") {
            try write("x", at: home.appending(path: path))
        }
    }

    deinit {
        try? manager.removeItem(at: root)
    }

    func write(_ text: String, at url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func link(_ directory: URL, to destination: String) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: directory.appending(path: "ebb").path, withDestinationPath: destination)
    }

    /// Everything under the root, as paths relative to it; a symbolic link counts as one entry.
    func everything() -> Set<String> {
        Set(((try? manager.subpathsOfDirectory(atPath: root.path)) ?? []).map { "/" + $0 })
    }

    func exists(_ url: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)) != nil
    }
}

@Suite struct EbbDataTests {
    @Test func removesEverythingEbbWritesAndNothingElse() throws {
        let box = try Sandbox()
        try box.write("port: 8317", at: box.home.appending(path: ".cli-proxy-api/config.yaml"))
        try box.write("{}", at: box.home.appending(path: ".cli-proxy-api/claude-a@example.com.json"))
        try box.write("x", at: box.home.appending(path: "Library/Application Support/Other/state"))
        try box.write("x", at: box.home.appending(path: "Library/Application Support/Ebb Notes/file"))
        try box.write("x", at: box.home.appending(path: "Library/Caches/com.example.other/file"))
        try box.write("x", at: box.home.appending(path: "Library/Preferences/com.example.other.plist"))
        try box.write("x", at: box.home.appending(path: ".config/other/settings"))
        try box.write("#!/bin/sh", at: box.user.appending(path: "other-tool"))
        try box.link(box.user, to: "/Applications/Ebb.app/Contents/Helpers/ebb")
        let before = box.everything()

        let removal = box.data.remove()

        #expect(removal.failures.isEmpty)
        let roots = EbbData.homeRelativePaths.map { "/home/" + $0 } + ["/home/.local/bin/ebb"]
        let after = box.everything()
        #expect(roots.allSatisfy { !after.contains($0) })
        // Whatever else vanished sat inside one of those locations.
        #expect(before.subtracting(after).allSatisfy { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } })
        #expect(after.isSuperset(of: [
            "/home/.cli-proxy-api/config.yaml", "/home/.cli-proxy-api/claude-a@example.com.json",
            "/home/Library/Application Support/Other/state", "/home/Library/Application Support/Ebb Notes/file",
            "/home/Library/Caches/com.example.other/file", "/home/Library/Preferences/com.example.other.plist",
            "/home/.config/other/settings", "/home/.local/bin/other-tool",
        ]))
    }

    @Test func everyPathStaysInsideHomeAndIsNamedForEbb() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let locations = EbbData(home: home, commandDirectories: []).locations

        #expect(locations.map(\.path) == EbbData.homeRelativePaths.map { home.appending(path: $0).path })
        for path in EbbData.homeRelativePaths {
            #expect(!path.hasPrefix("/") && !path.contains(".."), "\(path) leaves home")
            #expect(URL(fileURLWithPath: path).lastPathComponent.lowercased().contains("ebb"), "\(path) isn't named for Ebb")
            #expect(path.split(separator: "/").count >= 2, "\(path) would be a folder shared with other apps")
        }
    }

    @Test func removesTheCommandLinkOnlyWhenItPointsIntoAnEbbApp() throws {
        let box = try Sandbox()
        try box.link(box.system, to: "/Applications/Other.app/Contents/Helpers/ebb")
        try box.link(box.user, to: "/Applications/Ebb 2.app/Contents/Helpers/ebb")

        let removal = box.data.remove()

        #expect(removal.failures.isEmpty)
        #expect(box.exists(box.system.appending(path: "ebb")))
        #expect(!box.exists(box.user.appending(path: "ebb")))
    }

    @Test func leavesAnEbbThatIsAnotherProgram() throws {
        let box = try Sandbox()
        try box.write("#!/bin/sh", at: box.system.appending(path: "ebb"))

        _ = box.data.remove()

        #expect(box.exists(box.system.appending(path: "ebb")))
    }

    @Test func removesADanglingLinkToEbb() throws {
        let box = try Sandbox()
        try box.link(box.system, to: "/Applications/Ebb.app/Contents/Helpers/ebb")

        let removal = box.data.remove()

        #expect(removal.removed.contains(box.system.appending(path: "ebb")))
        #expect(!box.exists(box.system.appending(path: "ebb")))
    }

    @Test func unlinksAFolderThatIsASymbolicLinkWithoutFollowingIt() throws {
        let box = try Sandbox()
        let elsewhere = box.root.appending(path: "elsewhere")
        try box.write("keep", at: elsewhere.appending(path: "notes.txt"))
        let config = box.home.appending(path: ".config/ebb")
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(atPath: config.path, withDestinationPath: elsewhere.path)

        _ = box.data.remove()

        #expect(!box.exists(config))
        #expect(try String(contentsOf: elsewhere.appending(path: "notes.txt"), encoding: .utf8) == "keep")
    }

    @Test func listsOnlyWhatIsThereAndRemovesNothingFromAnEmptyHome() throws {
        let box = try Sandbox()
        let empty = EbbData(home: box.root.appending(path: "empty"), commandDirectories: [box.system])

        #expect(empty.existing().isEmpty)
        #expect(empty.remove() == EbbData.Removal())
        #expect(box.data.existing().count == EbbData.homeRelativePaths.count)
    }

    @Test func pathsDocListsExactlyWhatTheCommandRemoves() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/paths.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let listed = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"~/") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\",")) }

        #expect(listed.sorted() == EbbData.homeRelativePaths.map { "~/" + $0 }.sorted())
    }
}
