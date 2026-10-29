import Foundation
import Testing
@testable import EbbCore

@Suite(.hangLimit) final class ManagementKeyFileTests {
    private let secret = "mgmt-example-0123456789"
    private let root = FileManager.default.temporaryDirectory.appending(path: "ebb-key-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var keyFile: ManagementKeyFile {
        ManagementKeyFile(url: root.appending(path: "Application Support/Ebb/management-key"))
    }

    private var loginsFolder: URL {
        root.appending(path: ".cli-proxy-api")
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func writeImportFile(_ text: String) throws {
        try FileManager.default.createDirectory(at: loginsFolder, withIntermediateDirectories: true)
        try text.write(to: loginsFolder.appending(path: ManagementKeyFile.importName), atomically: true, encoding: .utf8)
    }

    @Test func savedKeyIsReadableOnlyByTheOwner() throws {
        let folder = keyFile.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        try keyFile.save(#require(ManagementKey(secret)))

        #expect(try permissions(keyFile.url) == 0o600)
        #expect(try permissions(folder) == 0o700)
        #expect(keyFile.read()?.value == secret)
    }

    @Test func replacingTheKeyKeepsItOwnerOnly() throws {
        try keyFile.save(#require(ManagementKey("old-key")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.url.path)

        try keyFile.save(#require(ManagementKey(secret)))

        #expect(try permissions(keyFile.url) == 0o600)
        #expect(keyFile.read()?.value == secret)
    }

    @Test func readsTheKeyFileInTheLoginsFolderWithoutSavingIt() throws {
        try writeImportFile(secret + "\n")

        let loaded = keyFile.load(importingFrom: loginsFolder)

        #expect(loaded?.key.value == secret)
        #expect(loaded?.origin == .loginsFolder)
        #expect(!FileManager.default.fileExists(atPath: keyFile.url.path))
    }

    @Test func savedKeyWinsOverTheLoginsFolderCopy() throws {
        try keyFile.save(#require(ManagementKey(secret)))
        try writeImportFile("other-key")

        let loaded = keyFile.load(importingFrom: loginsFolder)

        #expect(loaded?.key.value == secret)
        #expect(loaded?.origin == .saved)
    }

    @Test func forgottenKeyIsNotImportedAgain() throws {
        try writeImportFile(secret)

        #expect(keyFile.load(importingFrom: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: keyFile.url.path))
    }

    @Test func blankKeyFileCountsAsNoKey() throws {
        try writeImportFile(" \n")

        #expect(keyFile.load(importingFrom: loginsFolder) == nil)
    }

    @Test func keyNeverPrintsItself() throws {
        struct Holder { let key: ManagementKey }
        let key = try #require(ManagementKey(secret))
        var dumped = ""
        dump(Holder(key: key), to: &dumped)

        for printed in ["\(key)", String(reflecting: key), "\(Holder(key: key))", String(reflecting: Holder(key: key)), dumped] {
            #expect(!printed.contains(secret))
        }
    }

    @Test func keyFileWorkLogsNothing() throws {
        try writeImportFile(secret)

        let logged = try capturingStandardError {
            let loaded = try #require(keyFile.load(importingFrom: loginsFolder))
            try keyFile.save(loaded.key)
            _ = keyFile.read()
            keyFile.delete()
        }

        #expect(!logged.contains(secret))
    }

    /// Everything written to stderr while `body` runs.
    private func capturingStandardError(_ body: () throws -> Void) throws -> String {
        var pipe: [Int32] = [0, 0]
        #expect(Darwin.pipe(&pipe) == 0)
        let saved = dup(STDERR_FILENO)
        dup2(pipe[1], STDERR_FILENO)
        defer {
            dup2(saved, STDERR_FILENO)
            close(saved)
        }
        try body()
        fflush(stderr)
        close(pipe[1])
        dup2(saved, STDERR_FILENO)
        let data = FileHandle(fileDescriptor: pipe[0], closeOnDealloc: true).readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
