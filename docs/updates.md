# Updates

Ebb updates itself with [Sparkle 2](https://sparkle-project.org). Once a day it fetches the appcast from the latest GitHub Release:

```
https://github.com/lucasnsaraujo/ebb/releases/latest/download/appcast.xml
```

GitHub redirects that URL to the newest release that isn't a draft or prerelease, so each release only needs its own `appcast.xml` asset and no separate site. Settings → General has "Check for Updates…" and a switch for the daily check. `SUEnableAutomaticChecks` is set in `Info.plist`, so Sparkle never asks for permission on the second launch; the switch is the only control. Sparkle's system profile is off (its default), so the request carries the app and Sparkle versions in the User-Agent and nothing else.

The updater only starts in an installed `.app`. `swift run`, `--demo` and `--snapshot` never check. Ebb has no Dock icon, so Sparkle opens a scheduled update alert behind other windows; if Ebb may already post notifications, it also posts one that leads to the alert. An update never asks for notification permission.

## Signing

Ebb is ad-hoc signed and not notarized, because it has no Apple Developer ID. Updates are trusted through Sparkle's EdDSA signature instead:

- The public key is `SUPublicEDKey` in `Info.plist`, written by `build.sh`.
- The private key lives only in the `SPARKLE_PRIVATE_KEY` Actions secret, plus an offline backup held by the maintainer. It was generated in Sparkle's key format (base64 of a 32-byte Ed25519 seed) without the login Keychain, which `generate_keys` would otherwise use.
- The release workflow signs each zip with `generate_appcast --ed-key-file`, which writes the signature into the appcast.

## Does an update install on an ad-hoc, non-notarized app?

Yes. What Sparkle 2.10.1 does, from its source:

- `SUUpdateValidator.m` accepts a bundle update when **either** the old and new EdDSA keys match and the signature is valid, **or** the old and new Apple code signing identities match. A matching EdDSA key is enough, and the doc comment says it "allows change of Code Signing identity". The new app must still carry a valid code signature, and its own error text says "adhoc signing can be used at minimum".
- `SUPlainInstaller.m` removes `com.apple.quarantine` from the new bundle before moving it into place, so Gatekeeper never asks about an update. Only the first download from a browser is quarantined, which is why the README has the one-time first-open step.
- Ebb's executable doesn't use the Hardened Runtime, so library validation, which Sparkle's setup guide warns can stop an ad-hoc app from loading Sparkle, doesn't apply. (SwiftPM re-signs the embedded framework ad-hoc too.)

Tested end to end on macOS 27 with `sparkle-cli` built from the 2.10.1 tag, against a local appcast made by `generate_appcast`:

| Case | Result |
| --- | --- |
| Ad-hoc 0.0.1 → ad-hoc 0.1.0 | Installed; code signature valid; no quarantine on the result |
| Same, zip changed by one byte after signing | Rejected: "The update is improperly signed" (error 4005); 0.0.1 kept |

## Losing the key

Without the private key, no installed copy will accept a new update. Sparkle's key rotation needs a Developer ID signature, which Ebb doesn't have, so a lost key means users reinstall by hand once. Keep the backup.

## Releasing

Push a tag such as `v0.2.0`. `.github/workflows/release.yml` then runs the tests, builds a universal `Ebb.app` with `build.sh --bundle`, zips it with `ditto`, writes release notes from the merged pull requests, signs the zip into `appcast.xml` with `generate_appcast`, and publishes both as a GitHub Release. A tag with a hyphen (`v0.2.0-beta.1`) becomes a prerelease, which the `latest` URL skips, so installed copies don't see it.
