# Ebb: a macOS menu bar app for CLIProxyAPI

See how much of your Claude Code usage limit is free right now, across every account in your CLIProxyAPI pool. Codex is next.

Ebb is a native macOS menu bar app for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), the local proxy that pools Claude Code, Codex and other CLI subscriptions. If you run several Claude accounts behind it, Ebb reads them through CLIProxyAPI's management API and shows two numbers in the menu bar: the free share of the 5-hour limit and of the weekly limit, each weighted by plan size. It also tunes CLIProxyAPI's routing weights so the accounts drain evenly.

This README is a placeholder. Full docs come with the first release.

## Build

Requires macOS 26 or later and Xcode 26 or later.

```sh
./build.sh      # builds and installs ~/Applications/Ebb.app
swift test      # runs the unit tests
```

## License

MIT. Ebb is not affiliated with Anthropic. The Claude mark belongs to Anthropic.
