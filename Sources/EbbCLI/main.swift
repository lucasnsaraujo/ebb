import EbbCore
import Foundation

// The `ebb` command. It reads only the status file the app saves and never touches the network;
// `--uninstall-data` is the one command that changes anything, and only Ebb's own files.

let usage = """
Usage:
  ebb status [--json] [--provider NAME]   Each pool's 5-hour (or daily) and weekly free share
  ebb statusline [--provider NAME]        One line, such as "5h 88% · W 45%"
  ebb --uninstall-data [--yes]            Remove Ebb's settings, caches, key and command link; asks first

NAME is a CLIProxyAPI provider such as claude or codex; without it, the pool the menu bar shows.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()
var provider: String?
var isJSON = false
var isConfirmed = false
while !arguments.isEmpty {
    switch arguments.removeFirst() {
    case "--json" where command == "status": isJSON = true
    case "--yes" where command == "--uninstall-data": isConfirmed = true
    case "--provider":
        guard !arguments.isEmpty else { fail(usage) }
        provider = arguments.removeFirst()
    case let other: fail("Unknown option \(other)\n\n\(usage)")
    }
}

if command == "--uninstall-data" { uninstallData(isConfirmed: isConfirmed) }

let status = PoolStatus.read()
let now = Date.now
switch command {
case "statusline":
    print(StatusReport.statusline(status, provider: provider, now: now))
case "status":
    guard var status else { fail("Ebb hasn't saved any numbers yet. Open Ebb and keep its menu bar item showing.") }
    if let provider {
        guard let pool = status.pool(named: provider) else { fail("Ebb has no \(provider) pool.") }
        status.providers = [pool]
    }
    if isJSON {
        FileHandle.standardOutput.write(StatusReport.json(status, now: now) + Data("\n".utf8))
    } else {
        print(StatusReport.text(status, now: now))
    }
case "help", "--help", "-h":
    print(usage)
default:
    fail("Unknown command \(command)\n\n\(usage)")
}
