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

Nothing signing-related is in GitHub secrets. Everything is in Dionysus's
login keychain, which is why the runner is a LaunchAgent (`~/actions-runner`,
`./svc.sh status|stop|start`) rather than a daemon.

- **Developer ID**: `Developer ID Application: Evan Coleman (52M9C6892K)` in the login keychain.
- **Notarization**: `notarytool` keychain profile `leo-notary`. The source is the 1Password *Blackpaw Studio* item `App Store Connect Blackpaw Studio Admin` (key id, issuer id, `AuthKey_7W2NBJ7PA7.p8`). To recreate it: `xcrun notarytool store-credentials leo-notary --key <p8> --key-id … --issuer …`, then delete the `.p8`.
- **Sparkle EdDSA key**: keychain account `studio.blackpaw.leo` (Sparkle `generate_keys --account studio.blackpaw.leo`). It is backed up in 1Password *Olympus* → `Leo Sparkle EdDSA key`. To restore: `generate_keys --account studio.blackpaw.leo -f <file>`. The public key is in `macos/Ghostty-Info.plist` (`SUPublicEDKey`) and in `leo-build.yml`.
- **Toolchain**: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app` (Xcode 26.5's SDK breaks Zig linking) and Zig 0.16 from `~/.local/bin`.

### Keychain must be unlocked for the runner

`leo-build` starts with `check-signing.sh`, which fails fast with
`errSecInternalComponent` / "User interaction is not allowed" when the
runner's (Aqua) session sees the login keychain as locked. An unlocked
keychain in an ssh session does not carry over to the runner. The sign
step and `sign_update` in `leo-release` both need that session unlocked.

## After an upstream sync

Upstream syncs can add new workflows, and those start out **enabled**. Disable
them after each sync:

```sh
gh workflow list -R blackpaw-studio/leoterm --all
gh workflow disable -R blackpaw-studio/leoterm <file>.yml
```
