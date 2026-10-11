# Leo for iOS

UIKit + TCA app (`ios/Leo`), features in `ios/LeoFeatures`, shared models and
daemon client in `Packages/LeoKit`. `Leo.xcodeproj` is generated from
`project.yml` and committed: after editing `project.yml`, run
`cd ios && xcodegen generate` and commit the result (CI fails on drift).
Build with Xcode 26.5 (`DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer`);
Xcode 27 crashes on this code.

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

Signing is automatic (`-allowProvisioningUpdates`) with an App Store Connect API
key; team `52M9C6892K`. No certificates are stored in the repo or secrets.

### Repository secrets

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key |
| `ASC_ISSUER_ID` | Issuer ID (UUID shown above the keys list) |
| `ASC_KEY_P8` | Full contents of the `AuthKey_<ID>.p8` file |

### One-time setup

1. App Store Connect → Users and Access → Integrations → Team Keys: create a
   key with the **Admin** role (cloud-managed signing needs it; App Manager is
   not enough). Download the `.p8` once, back it up in the Olympus vault, and
   add the three secrets above.
2. Developer portal → Identifiers: register `studio.blackpaw.leo.ios` and
   `studio.blackpaw.leo.ios.notification-service`, and enable Push
   Notifications on the app ID (automatic provisioning can create them; check
   the capabilities match `Leo.entitlements`).
3. App Store Connect → Apps → New App: bundle ID `studio.blackpaw.leo.ios`,
   name "Leo". The first upload fails until this record exists.
4. No keychain setup is needed on the runner: the key is read by path, and
   `.github/scripts/leo/ios-signing.sh` gives each run a throwaway keychain
   (first in the search list, and the default) plus a profile-directory
   snapshot. The `always()` cleanup step deletes the keychain, restores the
   search list and default, and removes profiles downloaded during the run.
5. After the first upload, add internal testers in TestFlight.
   (`ITSAppUsesNonExemptEncryption` is already `NO` in `Leo/Support/Info.plist`.)
