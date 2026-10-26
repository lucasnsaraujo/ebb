# Contributing

Thanks for helping. A few things keep changes easy to review:

- Open an issue first for anything bigger than a small fix. Use the bug, feature or provider request form; questions go to Discussions.
- Run `swift build` and `swift test` before sending a pull request. CI runs both.
- Pool math lives in `Sources/EbbCore` and has unit tests. Add a test that fails without your change.
- Provider-specific code (endpoints, header names, plan sizes) belongs behind the `Provider` protocol in `Sources/EbbCore/Provider.swift`.
- Never commit real account data. Test fixtures use `example.com` addresses and fake IDs.
- Report security problems privately, as described in [SECURITY.md](SECURITY.md).
