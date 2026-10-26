# Ebb

Ebb is a macOS menu bar app that shows how much of your pooled Claude subscriptions is left. It reads the accounts you've logged in to [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and shows two numbers: free share of the 5-hour window and free share of the weekly window, each weighted by plan size.

This README is a placeholder. Full docs come with the first release.

## Build

Requires macOS 26 or later and Xcode 26 or later.

```sh
./build.sh      # builds and installs ~/Applications/Ebb.app
swift test      # runs the unit tests
```

## License

MIT. Ebb is not affiliated with Anthropic. The Claude mark belongs to Anthropic.
