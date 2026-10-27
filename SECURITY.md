# Security

## Reporting a vulnerability

Report it privately through [GitHub's private vulnerability reporting](https://github.com/lucasnsaraujo/ebb/security/advisories/new). Please don't open a public issue or discussion. You'll get a first reply within a week.

Include the Ebb version, macOS version, and the steps to trigger it. Don't include real tokens or emails.

## What Ebb handles

- **Management key.** The key for CLIProxyAPI's management API is stored in `~/Library/Application Support/Ebb/management-key`, a file only your user can read (mode 0600, in a 0700 folder), and sent only to your own CLIProxyAPI, normally on `localhost`. With no key saved, Ebb reads a `.management-key` file in CLIProxyAPI's logins folder, if there is one, and saves that key once the proxy accepts it; after Forget Key it stops reading that file. Ebb never logs the key.
- **OAuth tokens.** Ebb reads the access tokens in CLIProxyAPI's Claude auth files to ask Anthropic for an account's limits; they go to Anthropic's API and nowhere else. Other providers are asked through CLIProxyAPI's `api-call` endpoint, which fills in the token, so Ebb never reads those tokens.
- **Usage history.** `~/Library/Application Support/Ebb/demand.json` keeps 14 days of pooled usage in 5-minute bins for the pace forecasts. Accounts appear in it only as hashes.
- **Pool status.** Ebb saves each pool's free percentages and reset times to `~/Library/Application Support/Ebb/status.json`, for the `ebb` command. The file holds no account names, emails or tokens.
- **Status pages.** For Claude and Codex pools, Ebb reads `status.claude.com` and `status.openai.com` public `summary.json` at most every 5 minutes while its item shows. The requests carry no account data.
- **No telemetry.** Ebb has no analytics or crash reporting and talks to no server of its own. Account data never leaves your machine except in those requests.

In scope: a path where the key, tokens or account emails are logged, written in plain text, or sent anywhere other than your CLIProxyAPI or the account's own provider.

Out of scope: vulnerabilities in CLIProxyAPI itself (report them to [that project](https://github.com/router-for-me/CLIProxyAPI)), and attacks that need an attacker who already has your user account.

## Supported versions

Only the latest release gets fixes.
