# Paths

Everything Ebb writes outside `Ebb.app`. `ebb --uninstall-data` removes exactly the first list below, and the Homebrew cask's `zap` stanza is the same list.

## Homebrew cask `zap`

```ruby
zap trash: [
  "~/.config/ebb",
  "~/Library/Application Support/Ebb",
  "~/Library/Caches/io.github.lucasnsaraujo.ebb",
  "~/Library/HTTPStorages/io.github.lucasnsaraujo.ebb",
  "~/Library/HTTPStorages/io.github.lucasnsaraujo.ebb.binarycookies",
  "~/Library/Preferences/io.github.lucasnsaraujo.ebb.plist",
  "~/Library/Saved Application State/io.github.lucasnsaraujo.ebb.savedState",
]
```

A test (`EbbDataTests`) fails when this block and the list in `Sources/EbbCore/EbbData.swift` differ.

## What each path holds

| Path | What Ebb keeps there |
| --- | --- |
| `~/Library/Application Support/Ebb` | `management-key` (the CLIProxyAPI key, mode 0600), `demand.json` (14 days of pooled usage, accounts as hashes) and `status.json` (what the `ebb` command reads) |
| `~/Library/Caches/io.github.lucasnsaraujo.ebb` | Each idle account's last usage and plan reading, named by its email; Sparkle's update downloads in `org.sparkle-project.Sparkle` |
| `~/Library/Preferences/io.github.lucasnsaraujo.ebb.plist` | Ebb's settings, plan weights, alert state, and Sparkle's last-check time |
| `~/.config/ebb` | `mode` (when the menu bar item shows) and `retired.json` (the logins Ebb disabled because their plan ended) |
| `~/Library/HTTPStorages/io.github.lucasnsaraujo.ebb` and `.binarycookies` | macOS's cookie store for Ebb's requests; Ebb sets no cookies, so these usually don't exist |
| `~/Library/Saved Application State/io.github.lucasnsaraujo.ebb.savedState` | macOS's window restoration state, if it made any |

## Beyond the list

- **The `ebb` command link.** Settings → General → Install Command Line Tool links `ebb` into `/usr/local/bin` or `~/.local/bin`. `ebb --uninstall-data` removes that link when it points into an Ebb app, and leaves any other program called `ebb` alone. The cask's own link (`binary` stanza) is Homebrew's to remove.
- **The login item.** Ebb registers itself with `SMAppService` on first launch, which macOS lists under System Settings → General → Login Items & Extensions. It isn't a file. `ebb --uninstall-data` asks macOS to remove it and says so when it can't; a cask can't reach it either, and macOS drops the entry once `Ebb.app` is gone.
- **Notifications.** If you allowed them, macOS keeps Ebb's permission in System Settings → Notifications until the app is deleted.

## Never removed

`ebb --uninstall-data` doesn't touch CLIProxyAPI's config file or its logins folder (usually `~/.cli-proxy-api`), and it doesn't delete `Ebb.app`. It refuses to run while Ebb is open, since quitting Ebb writes its usage ledger again.
