# The `ebb` command

`ebb` prints the pools Ebb shows in the menu bar. It reads the status file the app saves at `~/Library/Application Support/Ebb/status.json` and makes no network calls, so it costs nothing to run as often as you like. The file holds pool percentages and reset times only: no account names, emails or tokens.

Install it from Settings → General → Command Line Tool. Ebb links `Ebb.app/Contents/Helpers/ebb` into `/usr/local/bin` when you can write to it, or else into `~/.local/bin`, so no admin password is needed.

## Commands

```text
ebb status [--json] [--provider NAME]
ebb statusline [--provider NAME]
```

`NAME` is CLIProxyAPI's provider name: `claude`, `codex`, `devin`, `antigravity`, `kimi` or `meta`. Without it, `statusline` shows the pool the menu bar shows, and `status` shows every pool.

`ebb status` prints each pool's short window (5-hour, or daily for Devin) and weekly window, with the capacity that comes back next:

```text
Claude (menu bar)
  5-hour  88% free  +12% at 20:05
  Weekly  45% free  +30% Tue 22:00
Codex
  5-hour  15% free
  Weekly  63% free
Updated 1m ago.
```

The words are always English; the clock follows your Mac's language and 12- or 24-hour setting, so the same refill reads `at 8:05 PM` on a US English Mac. `--json` always writes ISO 8601.

`ebb statusline` prints one line, such as `5h 88% · W 45%`. When the pool's newest reading is more than 10 minutes old, the same rule that dims the menu bar item, it adds the age: `5h 88% · W 45% · 25m old`, or `· stale` when there's no reading at all (the proxy isn't answering). Readings go old when the proxy stops answering, when Ebb quits, or when its menu bar item is hidden.

Both work the numbers out at the moment you run them, so a reset that landed after Ebb saved the file already counts as free.

## Exit status

`ebb status` exits with 1 and a message on standard error when Ebb hasn't saved any numbers yet, or when `--provider` names a pool Ebb doesn't have. In those cases `ebb statusline` exits with 0 and prints `Ebb: no data` or `Ebb: no kimi pool`, because Claude Code hides the status line of a command that fails. Both exit with 1 on an unknown command or option.

## JSON schema

`ebb status --json` prints this object. The schema only grows: new fields may appear, but existing ones keep their name, type and meaning until `schema_version` changes.

```json
{
  "schema_version": 1,
  "updated_at": "2026-10-26T19:34:00Z",
  "age_seconds": 60,
  "is_stale": false,
  "menu_bar_provider": "claude",
  "providers": [
    {
      "id": "claude",
      "name": "Claude",
      "is_partial": false,
      "read_at": "2026-10-26T19:33:40Z",
      "is_stale": false,
      "short_window": {
        "kind": "five_hours",
        "name": "5-hour",
        "free_percent": 88,
        "next_refill": { "at": "2026-10-26T20:05:00Z", "gain_percent": 12 }
      },
      "weekly": {
        "kind": "weekly",
        "name": "Weekly",
        "free_percent": 45,
        "next_refill": null
      }
    }
  ]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | `1` for this layout. |
| `updated_at` | string | When the app saved the file, ISO 8601 in UTC. |
| `age_seconds` | integer | Seconds since `updated_at`. |
| `is_stale` | boolean | True when `age_seconds` is over 600: Ebb quit, or its menu bar item is hidden. Ebb rewrites the file at least every 5 minutes while the item shows. |
| `menu_bar_provider` | string or null | The pool the menu bar shows. |
| `providers[].id` | string | CLIProxyAPI's provider name. |
| `providers[].name` | string | Display name. |
| `providers[].is_partial` | boolean | Some accounts can't be read right now and are left out of the numbers. |
| `providers[].read_at` | string or null | The pool's newest reading. `null` while the proxy doesn't answer and nothing else was read. Saved at most 5 minutes behind. |
| `providers[].is_stale` | boolean | True when `read_at` is `null` or over 10 minutes old, the rule that dims the menu bar item. |
| `providers[].short_window`, `providers[].weekly` | object | The two windows, never added together. |
| `….kind` | string | `five_hours`, `day` or `weekly`. Match on this. |
| `….name` | string | Display name: `5-hour`, `Daily` or `Weekly`. |
| `….free_percent` | integer | Plan-weighted share of the window still free, 0–100. |
| `….next_refill` | object or null | The next reset that gives back at least a whole point: `at` (ISO 8601) and `gain_percent` (whole pool points). |

With `--provider`, `providers` holds that one pool.

## Claude Code status line

Claude Code runs a [status line command](https://code.claude.com/docs/en/statusline) and shows what it prints. Add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "ebb statusline",
    "refreshInterval": 60
  }
}
```

Without `refreshInterval`, Claude Code re-runs the command only when the conversation changes. The 60-second timer keeps the numbers moving while a session sits idle. If Claude Code can't find `ebb`, write the full path from Settings, such as `~/.local/bin/ebb statusline`.

`ebb statusline` ignores the session JSON that Claude Code sends on standard input. To show it next to your own status line, call it from your script: `echo "$(your-status) | $(ebb statusline)"`.
