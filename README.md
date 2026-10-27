# Ebb: a macOS menu bar app for CLIProxyAPI

See how much of your coding-agent usage limits is free right now, across every account in your CLIProxyAPI pool.

Ebb is a native macOS menu bar app for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), the local proxy that pools Claude Code, Codex and other CLI subscriptions. Ebb reads your accounts through CLIProxyAPI's management API and shows, per provider, the free share of the short (5-hour or daily) limit and of the weekly limit, each weighted by plan size. An account that has used up its weekly limit counts as having no 5-hour capacity until its week resets, since it can't serve any. Providers are never added together: a Claude 5-hour share and a Codex one are different allowances. Ebb also tunes CLIProxyAPI's routing weights so each provider's accounts drain evenly, favoring weekly capacity in its last two days before a reset, when it would otherwise expire unused.

When a pool is being used fast enough to run out before it refills, the line under its meter says so, Battery style: "About 2 h left" for the 5-hour window, "Runs out ~Thu 14:00" for the weekly one. Hovering shows the pace of either window, including "Lasts until reset". The 5-hour pace is the recent rate while you work, with idle time left out; the weekly pace is your usual rhythm over the last week. Neither shows until there's enough history: about 15 minutes of work, or a day of use.

Ebb can also notify you when a 5-hour pool is about to run out at the current pace, and when weekly capacity comes back ("Claude weekly back +55%"). It asks for permission the first time an alert is due, never at launch, and Settings → General turns alerts off.

## Providers

| Provider | Windows | Source |
| --- | --- | --- |
| Claude | 5-hour, weekly | Proxy quota signals; idle accounts from Anthropic's usage endpoint |
| Codex | 5-hour, weekly | Proxy quota signals; idle accounts from `wham/usage` through the proxy |
| Devin | daily, weekly | Proxy quota signals |
| Antigravity | 5-hour, weekly | `retrieveUserQuotaSummary` through the proxy |
| Kimi | 5-hour, weekly | `/coding/v1/usages` through the proxy |
| Meta Muse | 5-hour, weekly | `muse-code/key` through the proxy; shows "Limits not available" while the proxy can't send the device-code token |
| xAI, Vertex, Gemini API key, AI Studio, OpenAI-compatible, plugins | none | Health only: status and cooldown. Never counted in a pool. |

While Claude's or OpenAI's public status page reports a problem with what a pool runs on (the Claude API and Claude Code, or Codex and the Responses API), the panel shows one line such as "Claude: degraded performance", linked to the page. Ebb reads those pages at most every 5 minutes, only while its menu bar item shows, and can send a notification (Settings → General, off by default). Hovering an account in the accounts panel shows paid extra usage when it's on: Claude's overage status, or Codex credits left.

Ebb needs the proxy's management key for everything but Claude. Enter it once in Settings → Connection, or keep it in a `.management-key` file in CLIProxyAPI's logins folder and Ebb picks it up until you press Forget Key. Calls "through the proxy" use CLIProxyAPI's `api-call` endpoint: Ebb names the account and the proxy fills in its token, so Ebb never reads those tokens. Plan weights have defaults (Settings → Plans) that you can change.

This README is a placeholder. Full docs come with the first release.

## Command line

Settings → General → Install Command Line Tool puts an `ebb` command on your PATH. `ebb status` prints every pool, `ebb status --json` prints the same in a [documented schema](docs/cli.md#json-schema), and `ebb statusline` prints one line such as `5h 88% · W 45%`. Use that line in your shell prompt or in Claude Code's status line:

```json
{
  "statusLine": { "type": "command", "command": "ebb statusline", "refreshInterval": 60 }
}
```

The command reads the numbers the app already saved and never touches the network. See [docs/cli.md](docs/cli.md).

## Shortcuts and Siri

Ebb adds two actions to Shortcuts, Spotlight and Siri. **Get Pool Status** returns a provider's 5-hour (or daily) and weekly free share and its next refill, as separate values; leave the provider empty for the pool the menu bar shows. **Open Ebb** opens the panel. Say "Check my Ebb pool" or "Get Codex pool status in Ebb". Like the command, both use the numbers Ebb already has.

## Build

Requires macOS 26 or later and Xcode 26 or later.

```sh
./build.sh      # builds and installs ~/Applications/Ebb.app, with the ebb command and App Intents metadata
swift test      # runs the unit tests
```

`Ebb --demo` shows fake accounts of every provider with no network, for screenshots and testing. `Ebb --snapshot <dir>` renders the panel, every menu bar style and Settings → General and Routing offscreen to PNGs and quits; add `--demo` for the fake accounts.

## License

MIT. Ebb is not affiliated with Anthropic, OpenAI, Cognition, Google, Moonshot AI or Meta. Provider names and logos are trademarks of their owners; see [THIRD_PARTY.md](THIRD_PARTY.md).
