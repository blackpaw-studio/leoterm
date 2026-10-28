# Leo CI and releases

All Leo CI runs on one self-hosted runner: the Mac mini **Dionysus**
(`dionysus-leo`, labels `self-hosted,macOS,ARM64,leo`). Upstream Ghostty
workflows are **disabled**, not deleted, so upstream syncs stay clean.

## Workflows

| File | Trigger | What it does |
| --- | --- | --- |
| `leo-ci.yml` | push to `main`, same-repo PRs | CI script tests (`.github/scripts/leo/run-tests.sh`: every `tests/test_*.sh`), SwiftLint `--strict`, Zig GhosttyKit, `GhosttyTests` unit bundle (no UI tests) |
| `leo-build.yml` | `workflow_dispatch`, `workflow_call` | ReleaseFast GhosttyKit, Release `Leo.app` with the bundled leo + tmux, Developer ID sign, DMG, notarize, staple; uploads `Leo.dmg` + zip (14 days) |
| `leo-release.yml` | tag `leo-vX.Y.Z` | Calls `leo-ci` (must pass), then `leo-build`, signs the DMG for Sparkle, appends `appcast.xml`, publishes a GitHub Release |
| `leo-bump.yml` | `repository_dispatch` `leo-release`, `workflow_dispatch` | Verifies a new leo release and opens a PR that bumps `macos/Bundled/LEO_VERSION` (see "Bumping the bundled leo") |
| `leo-bump-release.yml` | merged PR from `bump/leo-*` into `main` | Tags the next patch `leo-vX.Y.Z`, which fires `leo-release` |

The build logic lives in `.github/scripts/leo/`, so you can run it locally.
Fork PRs never reach the runner: `leo-ci` skips PRs whose head repo differs.
The repo is private, so fork PR workflows are disabled at the repo level too.

Versioning:

- Releases use the tag version. Other builds use `<last release's X.Y.Z or 0.0.0>-dev.<shortsha>`.
  "Last release" is the highest `leo-v*` tag by semver (`git tag --sort=-v:refname`),
  not `git describe` (which picks the nearest tag by commit-graph distance).
- A release tag must be an ancestor of `origin/main`; `version.sh` fails the
  build otherwise, so a release can never ship a commit that hasn't landed on main.
- `CFBundleShortVersionString` is always strictly numeric `X.Y.Z` (Apple
  requires this): the release tag's version, or the last release's version
  for dev builds. The commit/dev identity instead goes in the `GhosttyCommit`
  Info.plist key (`version.sh`'s `short_version` vs `version`/`commit` outputs;
  set in `build-app.sh`).
- `CFBundleVersion` is `git rev-list --count HEAD`, which is monotonically
  increasing **only on `main`**: it counts commits reachable from `HEAD`, so
  a diverged branch can produce a build number lower than, equal to, or out
  of order with another branch's. A dev build's `CFBundleVersion` is only
  meaningfully ordered against other builds taken from `main`; don't compare
  it across branches.
- Only tags matching `^leo-v[0-9]+\.[0-9]+\.[0-9]+$` (a release tag, checked
  strictly) are meant to be releases. A tag with any other suffix (e.g. a
  `-rc1` prerelease) is not a valid release tag and is not something to rely
  on for the "last release" lookup either -- keep release tags plain
  `leo-vX.Y.Z`.
- Unit tests run by injecting the bundle into the host app, because `xcodebuild test` hangs while the Mac is locked. The runner requires a zero exit status and zero reported test failures; there is no tolerated/waived failure.

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

## Bundled daemon helpers

Leo.app carries its own leo daemon and tmux in `Contents/Helpers/` (see
`docs/plans/2026-10-20-app-bundled-daemon.md`).

- `macos/Bundled/LEO_VERSION` pins the leo release. `fetch-leo.sh` downloads
  its `darwin_universal` tarball and checks the sha256. `LEO_BINARY=<universal
  leo>` overrides it for dev builds; a release (`RELEASE_TAG` set) refuses it.
- `macos/Bundled/TMUX_VERSION` pins the tmux, libevent and utf8proc sources.
  `build-tmux.sh` builds a static universal tmux; `leo-build` caches it
  (keyed on the pin and the build/check scripts). `TMUX_BINARY=<built tmux>`
  reuses a build.
- `embed-helpers.sh` (run by `build-app.sh`) installs both and stamps
  `LeoBundledLeoVersion` / `LeoBundledTmuxVersion`. `check-helper.sh` gates
  each: universal, system dylibs only, macOS 13 floor, exact version line.
- Xcode phases put `Resources/terminfo/74/tmux-256color` and
  `Library/LaunchAgents/<LEO_DAEMON_LABEL>.plist` in every build. "Leo dev
  helpers" copies `LEO_BINARY` / `TMUX_BINARY` build settings into a local
  build and signs them.
- `sign-package.sh` signs inside-out (`nested-code-paths.sh`), then gates on
  `check-bundle.sh`.

A local Release bundle with dev helpers. Sign it yourself afterwards: ad-hoc
each `nested-code-paths.sh` entry with `--options runtime`, but the outer app
without it, or library validation rejects the ad-hoc Sparkle at launch
("different Team IDs"); then run `check-bundle.sh`.

```sh
VERSION=0.0.0-dev SHORT_VERSION=0.0.0 BUILD=1 COMMIT=local DERIVED_DATA=/tmp/leo-dd \
  LEO_BINARY=<universal leo> TMUX_BINARY=<tmux from build-tmux.sh> \
  .github/scripts/leo/build-app.sh
```

## Bumping the bundled leo

A stable leo release (`vX.Y.Z` tag in `blackpaw-studio/leo`; prereleases
contain `-` and send nothing) dispatches `leo-release` to this repo with
`{version, sha256}` (`version` bare, no `v`; `sha256` is the
`leo_<version>_darwin_universal.tar.gz` hash). From there:

1. `leo-bump.yml` runs `bump-leo.sh`, which rejects anything but strict
   `X.Y.Z` and 64 lowercase hex, skips a version that isn't newer than the
   pin (`semver-gt.sh`), and checks the sha against that release's own
   `checksums.txt` before rewriting `LEO_VERSION`. `fetch-leo.sh` then
   downloads the tarball to confirm it. The payload only ever reaches scripts
   through `env:`, never `${{ }}` inside `run:`. That `verify` job runs the
   downloaded leo, so it has no PAT and no persisted credential; a separate
   `write` job holds `LEO_BUMP_TOKEN`, never runs the download, re-validates
   the version and sha `verify` outputs, and authenticates its push explicitly.
2. It force-pushes `bump/leo-<version>` (rebuilt on `main` every time) and
   opens the PR, or updates it if one is open. A newer dispatch opens a second
   PR; close the superseded one by hand.
3. CI runs on the PR. Merging it fires `leo-bump-release.yml`, which tags the
   next patch release: the highest strict `leo-vX.Y.Z` tag plus one patch
   (`next-leo-tag.sh`), at the merge commit. It tags only when the PR's full
   file list (from the API, so rebase merges count) is exactly
   `LEO_VERSION` (`check-bump-files.sh`). It never tags when a release tag
   already points at that commit, and refuses a commit that isn't a
   descendant of the latest release, so retrying an old run can't roll the
   version back. Runs are serialised (`concurrency`), and the push
   has no `--force`, so a lost race fails instead of moving a tag.
4. The tag fires `leo-release`, as in "Cut a release". Close the bump PR to
   skip a release; tag by hand to release some other change.

Both run on Dionysus like the rest of CI. `repository_dispatch` only runs the
workflow file on `main`. To test, dispatch by hand (needs a real release's
sha256, e.g. from its `checksums.txt`):

```sh
gh workflow run leo-bump.yml -R blackpaw-studio/leoterm -f version=X.Y.Z -f sha256=<sha256>
gh api repos/blackpaw-studio/leoterm/dispatches -f event_type=leo-release \
  -f 'client_payload[version]=X.Y.Z' -f 'client_payload[sha256]=<sha256>'
```

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
| `LEO_BUMP_TOKEN` | fine-grained PAT on `blackpaw-studio/leoterm`: Contents read/write, Pull requests read/write | used by `leo-bump.yml` and `leo-bump-release.yml` to push the bump branch, open the PR and push the release tag. A PAT, not `GITHUB_TOKEN`, because anything `GITHUB_TOKEN` creates triggers no workflows (no CI on the PR, no `leo-release` on the tag). Rotate before it expires or the bump flow stops silently. |

The Developer ID's private key also stays in Dionysus's **login** keychain
(unrelated to CI) because Evan signs local builds there.

- **Toolchain**: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app` (Xcode 26.5's SDK breaks Zig linking) and Zig 0.16 from `~/.local/bin`.
- **Public key**: `macos/Ghostty-Info.plist`'s `SUPublicEDKey` is the single source of truth (Xcode bakes it into the built app; there is no separate workflow copy). Keep it in sync with the `public key` field on the 1Password item. `sparkle-key-check.sh` derives the expected public key from `SPARKLE_PRIVATE_KEY` and diffs it against this same plist value before every release signs anything.

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

## Auto-update (on)

The repo is public, so Sparkle auto-update is **on** (B-115). Leo finds and
installs its own updates from GitHub Releases.

- `macos/Ghostty-Info.plist` no longer sets `SUEnableAutomaticChecks`, and
  `build-app.sh` doesn't touch it either (it used to delete it at build time;
  don't reintroduce that). The feed URL (`UpdateFeed`) and `SUPublicEDKey` are
  unchanged.
- `AppDelegate.ghosttyConfigDidChange` applies `UpdatePolicy.settings`, which
  maps the `auto-update` config to Sparkle:
  - `off`: no background checks, no automatic downloads.
  - `check`: background checks; an available update shows the update pill.
  - `download`: background checks and silent downloads, installed on quit.
  - unset: Leo leaves both alone, so Sparkle asks once ("check automatically?")
    through the update pill's permission popover: on a fresh install's second
    launch, and on an existing install's first launch of a B-115 build.
    The popover is the only prompt: Sparkle's standard alert never asks too,
    even though Sparkle asks before the first window is on screen. The
    request waits for the first terminal window's pill, and survives the
    last window closing (B-128).
    Every earlier build stored `SUEnableAutomaticChecks = NO` in the user's
    defaults, which beats Info.plist, so `UpdateDefaultsMigration` clears it
    (and `SUAutomaticallyUpdate`) once, behind the `LeoAutoUpdateDefaultsReset`
    marker. Setting `auto-update` writes Sparkle's stored answer, so clearing
    it again later keeps that answer and doesn't bring the prompt back.
- The manual **Check for Updates…** menu item always works, whatever
  `auto-update` says.
- **Debug builds can check but never install.** Under `DEBUG`,
  `UpdatePolicy.installsAllowed` is false, and every path Sparkle could install
  through is closed:
  - `auto-update` (set or unset) never turns automatic downloads on, and a
    permission answer can't either (`UpdatePolicy.settings`, `gatedPermission`).
  - `UpdateDriver` gates every reply: before a download, Install becomes
    Dismiss; once an update is downloaded or installing (`showReady`, or
    `showUpdateFound` at a later stage), every choice becomes Skip, because
    Sparkle still installs a dismissed staged update on quit.
  - Sparkle's standard alert still shows its "Automatically download and
    install updates" checkbox. If someone ticks it, the delegate refuses the
    next background check (`UpdatePolicy.mayCheck`), so Sparkle's silent
    download-and-install-on-quit driver never runs. The next launch or config
    reload turns the setting back off.
  - The popover says "Debug build: installing is disabled" and disables Install.

  The debug `CFBundleVersion` is 1, so Check for Updates… in a debug build
  always reports the newest release as available. That exercises the feed
  without touching the app. XCTest hosts never start the updater, and the UI
  tests launch the app with `-SUEnableAutomaticChecks NO`.
- `leo-release.yml` generates and publishes `appcast.xml` on every release.
  `macos/Tests/Update/Fixtures/appcast.xml` is a verbatim copy of the published
  appcast, and `AppcastFixtureTests` checks the newest item, its version and
  its `edSignature` parse. Refresh the copy when the appcast format changes;
  it doesn't need to track every release.

Going-public checklist (done 2026-09-30 unless noted):

1. [x] Remove `SUEnableAutomaticChecks` from `macos/Ghostty-Info.plist`.
2. [x] Update the `build-app.sh` comment (no script change needed).
3. [x] Confirm `https://github.com/blackpaw-studio/leoterm/releases/latest/download/appcast.xml`
   resolves anonymously (no auth prompt, no 404).
4. [ ] Evan: after the next release, run Check for Updates… on a real
   (non-debug) install and confirm the full Sparkle flow (download, verify,
   install, relaunch).

## After an upstream sync

Upstream syncs can add new workflows, and those start out **enabled**. Disable
them after each sync:

```sh
gh workflow list -R blackpaw-studio/leoterm --all
gh workflow disable -R blackpaw-studio/leoterm <file>.yml
```
