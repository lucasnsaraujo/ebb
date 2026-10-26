# Ebb: a macOS menu bar app for CLIProxyAPI

See how much of your coding-agent usage limits is free right now, across every account in your CLIProxyAPI pool.

Ebb is a native macOS menu bar app for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), the local proxy that pools Claude Code, Codex and other CLI subscriptions. Ebb reads your accounts through CLIProxyAPI's management API and shows, per provider, the free share of the short (5-hour or daily) limit and of the weekly limit, each weighted by plan size. Providers are never added together: a Claude 5-hour share and a Codex one are different allowances. Ebb also tunes CLIProxyAPI's routing weights so each provider's accounts drain evenly.

When a pool is being used fast enough to run out before it refills, the line under its meter says so, Battery style: "About 2 h left" for the 5-hour window, "Runs out ~Thu 14:00" for the weekly one. Hovering shows the pace of either window, including "Lasts until reset". The 5-hour pace is the recent rate while you work, with idle time left out; the weekly pace is your usual rhythm over the last week. Neither shows until there's enough history: about 15 minutes of work, or a day of use.

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

Ebb needs the proxy's management key for everything but Claude. Enter it once in Settings → Connection, or keep it in a `.management-key` file in CLIProxyAPI's logins folder and Ebb picks it up until you press Forget Key. Calls "through the proxy" use CLIProxyAPI's `api-call` endpoint: Ebb names the account and the proxy fills in its token, so Ebb never reads those tokens. Plan weights have defaults (Settings → Plans) that you can change.

This README is a placeholder. Full docs come with the first release.

## Build

Requires macOS 26 or later and Xcode 26 or later.

```sh
./build.sh      # builds and installs ~/Applications/Ebb.app
swift test      # runs the unit tests
```

`Ebb --demo` shows fake accounts of every provider with no network, for screenshots and testing. `Ebb --snapshot <dir>` renders the panel, every menu bar style and Settings → General offscreen to PNGs and quits; add `--demo` for the fake accounts.

## License

MIT. Ebb is not affiliated with Anthropic, OpenAI, Cognition, Google, Moonshot AI or Meta. Provider names and logos are trademarks of their owners; see [THIRD_PARTY.md](THIRD_PARTY.md).
