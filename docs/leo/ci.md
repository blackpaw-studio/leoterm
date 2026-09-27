# Leo CI and releases

All Leo CI runs on one self-hosted runner: the Mac mini **Dionysus**
(`dionysus-leo`, labels `self-hosted,macOS,ARM64,leo`). Upstream Ghostty
workflows are **disabled**, not deleted, so upstream syncs stay clean.

## Workflows

| File | Trigger | What it does |
| --- | --- | --- |
| `leo-ci.yml` | push to `main`, same-repo PRs | SwiftLint `--strict`, Zig GhosttyKit, `GhosttyTests` unit bundle (no UI tests) |
| `leo-build.yml` | `workflow_dispatch`, `workflow_call` | ReleaseFast GhosttyKit, Release `Leo.app`, Developer ID sign, DMG, notarize, staple; uploads `Leo.dmg` + zip (14 days) |
| `leo-release.yml` | tag `leo-vX.Y.Z` | Calls `leo-build`, signs the DMG for Sparkle, appends `appcast.xml`, publishes a GitHub Release |

The build logic lives in `.github/scripts/leo/`, so you can run it locally.
Fork PRs never reach the runner: `leo-ci` skips PRs whose head repo differs.
The repo is private, so fork PR workflows are disabled at the repo level too.

Versioning:

- Releases use the tag version. Other builds use `<latest leo-v tag or 0.0.0>-dev.<shortsha>`.
- `CFBundleVersion` is `git rev-list --count HEAD`.
- Unit tests run by injecting the bundle into the host app, because `xcodebuild test` hangs while the Mac is locked. `ConfigTests/errorsEmptyForValidConfig` always fails under that runner, so the script tolerates that one failure.

## Cut a release

```sh
git tag leo-vX.Y.Z && git push origin leo-vX.Y.Z
```

The tag must point at the commit you want to ship. The release is published
directly (not a draft), with `Leo.dmg`, `Leo-macos-universal.zip` and
`appcast.xml` attached. Sparkle reads
`https://github.com/blackpaw-studio/leoterm/releases/latest/download/appcast.xml`
(`macos/Sources/Features/Update/UpdateFeed.swift`).

> The repo is **private**. Until it is public or the appcast moves to a
> public host, anonymous clients (Sparkle) get a 404 on that URL, so
> auto-update will not find releases.

## One-off signed build

```sh
gh workflow run leo-build.yml -R blackpaw-studio/leoterm -f ref=<sha|branch|PR number|leo-vX.Y.Z>
```

The DMG and zip arrive as a run artifact. Always pass `-R blackpaw-studio/leoterm`,
because `gh` otherwise resolves to upstream `ghostty-org/ghostty`.

## Where keys live

All signing material lives in GitHub Actions secrets on
`blackpaw-studio/leoterm`, not on Dionysus. Each signing job builds a
throwaway keychain under `$RUNNER_TEMP` (`.github/scripts/leo/keychain.sh`),
uses it, then deletes it in an `if: always()` step — nothing persists on the
runner between jobs, and the same steps would work unmodified on
`macos-latest`. Dionysus stays the `runs-on` target only for cost/speed, not
because it holds credentials; the runner is still a LaunchAgent
(`~/actions-runner`, `./svc.sh status|stop|start`).

Secrets:

| Secret | Contents | Source / backup |
| --- | --- | --- |
| `MACOS_CERTIFICATE` | base64 of a `.p12` containing **only** `Developer ID Application: Evan Coleman (52M9C6892K)` (sha1 `1C6A4945…`) | 1Password *Olympus* → `Leo Developer ID p12` (file attachment + password) |
| `MACOS_CERTIFICATE_PWD` | password for that `.p12` | same 1Password item |
| `MACOS_CI_KEYCHAIN_PWD` | throwaway password for the per-job temp keychain | not backed up; rotate freely, `keychain.sh` regenerates the keychain every run |
| `APPLE_NOTARIZATION_KEY` | contents of `AuthKey_7W2NBJ7PA7.p8` | 1Password *Blackpaw Studio* → `App Store Connect Blackpaw Studio Admin` |
| `APPLE_NOTARIZATION_KEY_ID` | `7W2NBJ7PA7` | same item, field `key id` |
| `APPLE_NOTARIZATION_ISSUER` | issuer UUID | same item, field `issuer id` |
| `SPARKLE_PRIVATE_KEY` | base64 EdDSA private key (Sparkle `generate_keys`) | 1Password *Olympus* → `Leo Sparkle EdDSA key` |

The Developer ID's private key also stays in Dionysus's **login** keychain
(unrelated to CI) because Evan signs local builds there.

- **Toolchain**: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app` (Xcode 26.5's SDK breaks Zig linking) and Zig 0.16 from `~/.local/bin`.
- **Public key**: the Sparkle public key is in `macos/Ghostty-Info.plist` (`SUPublicEDKey`) and in `leo-build.yml` (`SPARKLE_PUBLIC_KEY`); keep both in sync with the `public key` field on the 1Password item.

### Rotating a secret

1. Generate/export the new value (see "Source / backup" above for where each
   one comes from; export a `.p12` for just the Developer ID identity by
   isolating it in a scratch keychain first — `security export` ignores any
   identity-name filter and otherwise dumps every identity in the keychain).
2. `echo -n '<value>' | gh secret set <NAME> -R blackpaw-studio/leoterm` (pipe
   file-based secrets with `cat`, e.g. the `.p12` via `base64` or the `.p8`
   directly). Never pass secret values as command-line arguments or print
   them.
3. Update the matching 1Password item (edits keep prior versions in history).
4. Run `leo-build` once (`gh workflow run leo-build.yml -R blackpaw-studio/leoterm`)
   to confirm the new secret works before relying on it for a release.
5. If you rotated the Developer ID cert or the notarization key, delete the
   superseded 1Password item version's file/credential only after confirming
   the new one signs and notarizes successfully.

### Team mismatch hazard

The Developer ID identity belongs to team `52M9C6892K`. The notarization API
key must belong to the **same** team/account that issued that identity — if
`APPLE_NOTARIZATION_KEY`/`_KEY_ID`/`_ISSUER` come from a different Apple
Developer team, notarization fails with a team or authorization error.
`check-signing.sh` authenticates with `notarytool history` before the build
starts specifically to catch this early; treat that failure as a
configuration problem to fix, not something to retry.

## After an upstream sync

Upstream syncs can add new workflows, and those start out **enabled**. Disable
them after each sync:

```sh
gh workflow list -R blackpaw-studio/leoterm --all
gh workflow disable -R blackpaw-studio/leoterm <file>.yml
```
