# Leo for iOS

UIKit + TCA app (`ios/Leo`), features in `ios/LeoFeatures`, shared models and
daemon client in `Packages/LeoKit`. `Leo.xcodeproj` is generated from
`project.yml` and committed: after editing `project.yml`, run
`cd ios && xcodegen generate` and commit the result (CI fails on drift).
Build with Xcode 26.5 (`DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer`);
Xcode 27 crashes on this code.

## Real-push E2E (simulator, real APNs)

`LeoPushE2ETests` also runs against a real daemon and the deployed relay; the
simulator (Apple silicon) receives sandbox APNs pushes for Debug builds.

1. Run an isolated daemon (built from leo `main`) with a fake `claude` first in
   its `PATH` that stays resident and, on cue, pipes
   `{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":<its --session-id>}`
   into `leo dispatch report` (the hook command leo passes in `--settings`).
   Spawn the agent and let it reach `working` (a `UserPromptSubmit` hook).
2. `TEST_RUNNER_LEO_PUSH_PHASE=pair` with a fresh `leo pair` payload. The
   daemon's `devices.json` then holds a `push` registration (grant, key, relay URL).
3. `TEST_RUNNER_LEO_PUSH_PHASE=tap TEST_RUNNER_LEO_PUSH_BODY="Waiting for your input"`
   (`TEST_RUNNER_LEO_PUSH_LAUNCH=warm` or cold): when `push-ready` appears,
   fire the hook instead of `simctl push`. The daemon pushes through the relay;
   the banner reads `<agent>` / `Waiting for your input` once the NSE decrypts it.

Screenshots from the 2026-10-11 run: `docs/screenshots/push-real-*.png`.

## CI

- `.github/workflows/leo-ios.yml` (paths `ios/**`, `Packages/LeoKit/**`, `images/Ghostty.icon/**`): LeoKit
  and LeoFeatures tests, XcodeGen drift check, unsigned simulator build, app tests.
- `.github/workflows/leo-relay.yml` (paths `relay/**`): `npm ci`, `npm test`, `tsc --noEmit`.
- The Mac `leo-ci` workflow has no path filter, so it already runs on
  `Packages/LeoKit/**` changes.

## TestFlight

`.github/workflows/leo-ios-testflight.yml` archives the Release build and uploads
it to TestFlight. Run it from Actions (Run workflow) or push a `leo-ios-vX.Y.Z`
tag (separate from the Mac `leo-v*` tags). The build number is the run number;
the marketing version is `MARKETING_VERSION` in `project.yml`.

Release signing is manual, with App Store profiles from fastlane match (team
`52M9C6892K`). The workflow runs `fastlane match appstore --readonly` into a
per-job keychain, archives and exports with `ios/ExportOptions.plist`, and
uploads the `.ipa` with `fastlane pilot` using the App Store Connect API key.
Xcode automatic signing is not used in CI: `-allowProvisioningUpdates` fails with
"Authentication failed: Make sure a bearer token was provided" on this key.
Debug builds still use automatic signing.

- Certificates and profiles live in the private repo `evandcoleman/match`
  (`ios/fastlane/Matchfile`). The App Store profiles are named
  `match AppStore studio.blackpaw.leo.ios` and
  `match AppStore studio.blackpaw.leo.ios.notification-service`; `project.yml`
  and `ExportOptions.plist` reference them by name.
- Fastlane is pinned by `ios/Gemfile.lock` (installed by `ruby/setup-ruby`).
- To renew or add a profile, run `bundle exec fastlane match appstore` (without
  `--readonly`) from `ios/` on a trusted machine, then re-run the workflow.

### Repository secrets

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID (UUID shown above the keys list) |
| `ASC_KEY_P8` | Full contents of the `AuthKey_<ID>.p8` file |
| `MATCH_PASSWORD` | Passphrase that encrypts the match repo |
| `MATCH_DEPLOY_KEY` | SSH private key of a read-only deploy key on `evandcoleman/match` |

### One-time setup

1. App Store Connect → Users and Access → Integrations → Team Keys: create an
   API key (App Manager is enough for upload). Download the `.p8` once, back it
   up in the Olympus vault, and add the three `ASC_*` secrets.
2. Add `MATCH_PASSWORD` and `MATCH_DEPLOY_KEY` (generate a key pair, add the
   public half as a read-only deploy key on the match repo).
3. Developer portal → Identifiers: `studio.blackpaw.leo.ios` and
   `studio.blackpaw.leo.ios.notification-service` exist with the app group on
   both and Push Notifications on the app ID (match the capabilities in
   `Leo.entitlements`); regenerate the match profiles after changing them.
4. App Store Connect → Apps → New App: bundle ID `studio.blackpaw.leo.ios`,
   name "Leo". The first upload fails until this record exists.
5. The runner needs Ruby via `ruby/setup-ruby` (no setup beyond that) and `jq`.
   `.github/scripts/leo/ios-signing.sh` gives each run a throwaway keychain
   (first in the search list, and the default) plus a profile-directory
   snapshot. The `always()` cleanup step deletes the keychain, restores the
   search list and default, and removes profiles installed during the run.
   The deploy key is written to `$RUNNER_TEMP` for the match step only and deleted
   afterwards.
6. After the first upload, add internal testers in TestFlight.
   (`ITSAppUsesNonExemptEncryption` is already `NO` in `Leo/Support/Info.plist`.)

### Local Release check

With the profiles installed (`fastlane match appstore --readonly` from `ios/`):

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer
cd ios
xcodebuild archive -project Leo.xcodeproj -scheme Leo -configuration Release \
  -destination "generic/platform=iOS" -archivePath /tmp/Leo.xcarchive
xcodebuild -exportArchive -archivePath /tmp/Leo.xcarchive \
  -exportPath /tmp/leo-export -exportOptionsPlist ExportOptions.plist
```
