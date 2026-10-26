# Security

## Reporting a vulnerability

Report it privately through [GitHub's private vulnerability reporting](https://github.com/lucasnsaraujo/ebb/security/advisories/new). Please don't open a public issue or discussion. You'll get a first reply within a week.

Include the Ebb version, macOS version, and the steps to trigger it. Don't include real tokens or emails.

## What Ebb handles

- **Management key.** The key for CLIProxyAPI's management API is stored in the macOS Keychain and sent only to your own CLIProxyAPI, normally on `localhost`.
- **OAuth tokens.** Ebb reads the access tokens in CLIProxyAPI's auth files to ask each provider for an account's limits. They go to that provider's API and nowhere else.
- **No telemetry.** Ebb has no analytics or crash reporting and talks to no server of its own. Account data never leaves your machine except in those requests.

In scope: a path where the key, tokens or account emails are logged, written in plain text, or sent anywhere other than your CLIProxyAPI or the account's own provider.

Out of scope: vulnerabilities in CLIProxyAPI itself (report them to [that project](https://github.com/router-for-me/CLIProxyAPI)), and attacks that need an attacker who already has your user account or Keychain access.

## Supported versions

Only the latest release gets fixes.
