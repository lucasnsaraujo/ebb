import Foundation
import Testing
@testable import EbbCore

private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "ebb-cli-\(UUID().uuidString)")
    var tool: URL { root.appending(path: "Ebb.app/Contents/Helpers/ebb") }
    var system: URL { root.appending(path: "usr/local/bin") }
    var user: URL { root.appending(path: "home/.local/bin") }
    var installer: CommandLineTool { CommandLineTool(tool: tool, directories: [system, user]) }

    init() throws {
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path)
        try? FileManager.default.removeItem(at: root)
    }

    func makeDirectory(_ url: URL, writable: Bool = true) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: url.path)
    }

    func destination(of link: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }
}

@Suite(.hangLimit) struct CommandLineToolTests {
    @Test func linksIntoTheFirstWritableFolder() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system)
        let link = try box.installer.install()
        #expect(link == box.system.appending(path: "ebb"))
        #expect(try box.destination(of: link) == box.tool.path)
    }

    @Test func fallsBackToTheUserFolderAndCreatesIt() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system, writable: false)
        let link = try box.installer.install()
        #expect(link == box.user.appending(path: "ebb"))
        #expect(try box.destination(of: link) == box.tool.path)
    }

    @Test func replacesALinkToAnotherCopyOfEbb() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system)
        try FileManager.default.createSymbolicLink(atPath: box.system.appending(path: "ebb").path, withDestinationPath: "/Applications/Ebb.app/Contents/Helpers/ebb")
        let link = try box.installer.install()
        #expect(try box.destination(of: link) == box.tool.path)
    }

    @Test func neverReplacesSomeoneElsesEbb() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system)
        let other = box.system.appending(path: "ebb")
        try Data("other tool".utf8).write(to: other)
        #expect(throws: CommandLineTool.InstallError.occupied(other)) { try box.installer.install() }
        #expect(try Data(contentsOf: other) == Data("other tool".utf8))
    }

    @Test func neverReplacesAnotherAppsHelperCalledEbb() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system)
        let other = box.system.appending(path: "ebb")
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: "/Applications/Other.app/Contents/Helpers/ebb")
        #expect(throws: CommandLineTool.InstallError.occupied(other)) { try box.installer.install() }
        #expect(try box.destination(of: other) == "/Applications/Other.app/Contents/Helpers/ebb")
    }

    @Test func aLinkToAnotherCopyOfEbbIsNotThisInstall() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system)
        try FileManager.default.createSymbolicLink(atPath: box.system.appending(path: "ebb").path, withDestinationPath: "/Applications/Ebb.app/Contents/Helpers/ebb")
        #expect(box.installer.installedLink == nil)
    }

    @Test func findsTheLinkItMade() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system, writable: false)
        #expect(box.installer.installedLink == nil)
        let link = try box.installer.install()
        #expect(box.installer.installedLink == link)
    }

    /// A quarantined app opened from Downloads runs from a temporary copy that's gone after it quits.
    @Test func aTranslocatedCopyIsNeverLinked() throws {
        let box = try Sandbox()
        try box.makeDirectory(box.system)
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/0A1B2C3D/d/Ebb.app/Contents/Helpers/ebb")
        let installer = CommandLineTool(tool: translocated, directories: [box.system, box.user])
        #expect(throws: CommandLineTool.InstallError.translocated) { try installer.install() }
        #expect(!FileManager.default.fileExists(atPath: box.system.appending(path: "ebb").path))
    }
}
