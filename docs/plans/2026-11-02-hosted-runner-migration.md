# Leo CI migration plan: self-hosted Dionysus runner → GitHub-hosted runners

**Bottom line:** every workflow can move to standard GitHub-hosted runners with no paid runner and no new secrets.

- The signing workflows already get all their key material from GitHub secrets. Each run builds a throwaway keychain under `$RUNNER_TEMP` (`keychain.sh`, `ios-signing.sh`).
- The repo is public, so standard hosted runners cost nothing.
- No branch protection exists. The only ruleset is the org "Default Branch Protections", which has just a `deletion` rule. So check names are free to change.
- `gh api …/actions/runners` lists no runners. The self-hosted runner is either already deregistered or the token can't see it.
- Two things only a box we control can do:
  - **Tart VM e2e.** It isn't in any workflow; it's a manual check on Dionysus.
  - **The host test tier** (`LEO_HOST_TESTS=1`). It might work on hosted runners; that hasn't been tested.

Corrections to the brief:
- **Zig is 0.16.0, not 0.15.2.** `build.zig.zon` has `minimum_zig_version = "0.16.0"`, the bench workflow pins 0.16.0, and `docs/leo/ci.md` says the runner used Zig 0.16 from `~/.local/bin`.
- **The bench's Xcode step silently falls back** to the newest Xcode 26.x when 26.3 is missing. `ci.md` says Xcode 26.5's SDK breaks Zig linking, so the release path must fail hard on a missing 26.3 instead.

## Orchestrator decisions (2026-11-02)

Evan asked to move all workflows off the self-hosted runner (now offline). Calls made, reversible, open to veto:
- **D1:** no `test-macos-host` CI job. The host tier is known to fail on hosted macos-26 (titlebar insets, split-view drags, prompt-idle) and the focus tests skip there, so a non-blocking job would be permanently red noise. The host tier becomes a documented local pre-release check (`LEO_HOST_TESTS=1 .github/scripts/leo/run-unit-tests.sh`) in `docs/leo/ci.md`; drop `LEO_HOST_TESTS` from leo-ci.yml and the check-test-log host-skip assertion stays (it only fires when the variable is set).
- **D2:** no paid runner. Revisit only if leo-build runs out of disk/time.
- **D3:** Tart e2e stays manual on an Apple-silicon Mac.
- Fork-PR guard dropped on leo-ci, leo-relay, leo-ios as proposed; kept on leo-bump-release.
- No PR (repo rule). Work on branch `ci/hosted-runners`; the orchestrator merges to main with Evan's approval. Workflows that need branch verification may gain a `workflow_dispatch` trigger.

## 1. Per-workflow inventory

The `macos-26` image (from today's bench run 41491112800) has Xcode `26.0` through `26.6`, at paths like `/Applications/Xcode_26.3.app` and `/Applications/Xcode_26.5.app` (underscore, not the box's `Xcode-26.3.0.app`).

All 13 secrets exist in GitHub: `APPLE_NOTARIZATION_{KEY,KEY_ID,ISSUER}`, `ASC_{KEY_ID,ISSUER_ID,KEY_P8}`, `LEO_BUMP_TOKEN`, `MACOS_CERTIFICATE{,_PWD}`, `MACOS_CI_KEYCHAIN_PWD`, `MATCH_{DEPLOY_KEY,PASSWORD}`, `SPARKLE_PRIVATE_KEY`. None of them is read from files on the box. **No secrets need adding.**

| Workflow | What it used from the box | Hosted label | Setup steps | Secrets | Blockers |
|---|---|---|---|---|---|
| **leo-ci.yml** (`test-macos`, also `workflow_call` from release) | Xcode-26.3.0 path, zig 0.16 in `~/.local/bin`, swiftlint, GNU `timeout`, `/usr/bin/ruby` (script tests); host tier on (real key focus, surfaces, WebKit); fork guard; 120 min | `macos-26` | Same as the bench: `DEVELOPER_DIR` pinned to `/Applications/Xcode_26.3.app/Contents/Developer` with a `test -d` hard fail; `mlugg/setup-zig` 0.16.0; coreutils with only `timeout` symlinked; swiftlint 0.63.3 portable zip; caches for zig, LeoKit `.build` and DerivedData | none | Host tier is lost (decision D1). Already green on hosted, run time 13–25 min. |
| **leo-ci-hosted-bench.yml** | – | – | Delete it; its job becomes leo-ci's job | – | – |
| **leo-build.yml** (dispatch and call) | Xcode-26.3.0, zig, `curl`/`make`/`clang` for tmux; `hdiutil`, `codesign`, `notarytool`, `stapler`, `spctl`; netrc auth flag; 150 min | `macos-26` | Pinned `DEVELOPER_DIR`; setup-zig 0.16.0. Nothing else: `build-tmux.sh` uses release tarballs (no autotools needed), `fetch-leo.sh` uses plain curl and `blackpaw-studio/leo` is **public**, and the netrc flag is harmless because the only SwiftPM dependency is public Sparkle (no `~/.netrc` needed). | `MACOS_*`, `APPLE_NOTARIZATION_*` (present) | (a) Disk/RAM on a standard runner (3 vCPU, 7 GB) for a universal ReleaseFast build is untested. (b) `hdiutil create` is known to fail intermittently with "Resource busy" on hosted runners. (c) Hosted images may have Gatekeeper assessments disabled, which would make `spctl --assess` pass trivially. Unverified; check the log for `source=Notarized Developer ID`. |
| **leo-release.yml** (`ci` → `build` → `publish`) | `publish`: python3, `xmllint`, `gh`, `shasum`, `curl` (Sparkle tools downloaded and pinned); 30 min | `macos-26` (Sparkle's `sign_update` is a macOS binary) | `runs-on` change only, plus a dry-run dispatch path (step 2a) | `SPARKLE_PRIVATE_KEY` (present) | No dry run exists today; only a tag push runs it. |
| **leo-bump.yml** (`verify`, `write`) | `verify` runs the downloaded leo binary and `lipo` (needs macOS); `write` uses git and gh; 20/10 min | `macos-26` for both (one shell environment, so no BSD-vs-GNU differences; minutes are free) | none | `LEO_BUMP_TOKEN` (present; a PAT that will expire) | none |
| **leo-bump-release.yml** | git, gh; 10 min | `macos-26` | none | `LEO_BUMP_TOKEN` | Keep its same-repo guard: it is semantic, and `test_bump-workflows.sh` asserts it. |
| **leo-relay.yml** | node/npm from the box (this host has node 26.7.0); fork guard; 15 min | `ubuntu-24.04` | `actions/setup-node`, SHA-pinned, `node-version: 26`, `cache: npm`, `cache-dependency-path: relay/package-lock.json` | none | none (vitest-pool-workers and wrangler run on Linux) |
| **leo-ios.yml** | Xcode-26.5.0 (Xcode 27 crashes on this code), xcodegen (this host has 2.42.0), "iPhone 17 Pro" simulator; fork guard; 60 min | `macos-26` | `DEVELOPER_DIR=/Applications/Xcode_26.5.app/…`; xcodegen 2.42.0 pinned (release zip via `gh release download`, or brew pinned to that version); a simulator-exists check that fails clearly | none | The simulator runtime for 26.5 on the image is unverified; the first run shows it. A different xcodegen version would produce a spurious drift diff, so it must match 2.42.0. |
| **leo-ios-testflight.yml** | Xcode-26.5.0; **rbenv Ruby 3.3.4 at `~/.rbenv`**, gems in `RUNNER_TOOL_CACHE`; `jq`; launchd runner with no locale (hence the `LANG` env) | `macos-26` | Replace the rbenv step with `ruby/setup-ruby` (SHA-pinned, `ruby-version: 3.3.4`, `bundler-cache: true`, `working-directory: ios`). Keep `ios-signing.sh` (works on ephemeral runners), match over the read-only deploy key, and `LANG`. | `ASC_*`, `MATCH_*` (present) | No dry run today: a dispatch always uploads. `BUILD_NUMBER=github.run_number` keeps increasing (it's per workflow, not per runner). |

**Fork-PR guard (my default; Evan can veto):** drop the `head.repo == repository` guard from leo-ci, leo-relay and leo-ios.
- Hosted fork-PR runs get a read-only token and no secrets.
- Fork PRs cannot write caches that main or tag runs read.
- Keep GitHub's default approval requirement for first-time contributors.
- Keep the guard on leo-bump-release.

**Keychain approach:** no decision needed. The ephemeral keychains in `keychain.sh` and `ios-signing.sh` were built to run unchanged on hosted runners (`ci.md`, "Where keys live").

## 2. Decisions for Evan

1. **D1: host test tier** (real key focus, surfaces, WebKit; it only ran on Dionysus).
   - **Recommend:** add a second leo-ci job `test-macos-host` with `LEO_HOST_TESTS=1` and `continue-on-error: true`. Hosted macOS runners have a logged-in desktop session, so it may just work.
   - If it's green for about 5 runs, make it blocking. If it can't work there, drop it and run `LEO_HOST_TESTS=1 run-unit-tests.sh` locally on Dionysus before each `leo-v` tag.
   - Not recommended: keeping a self-hosted runner only for this. That is the thing being retired.
2. **D2: paid larger runner** (e.g. `macos-26-xlarge`, billed even on public repos).
   - **Recommend no.** Releases are rare and there's a 150 min timeout.
   - Revisit only if the leo-build test dispatch in step 2a runs out of disk or time. First try freeing disk by deleting the unused `/Applications/Xcode_26.{0,1,2,4,6}*` copies at job start.
3. **D3: Tart bundled-daemon e2e.** It is not in any workflow; it's a manual check with the golden `leo-vm` image on Dionysus. Hosted arm64 macOS runners have no nested virtualization.
   - **Recommend:** keep it manual on any Apple-silicon Mac Evan controls (Tart doesn't need a runner).
   - Optional backlog idea, not for now: add a pre-release checklist line to `ci.md` for changes that touch the bundled daemon.

## 3. Implementation batches

Within a batch the items share no files, so they can go to parallel `implement` dispatches at medium effort (this is mechanical YAML work). Every push to main needs Evan's approval of the exact command.

**Batch 1 (parallel, one PR branch)**
- **1a.** Rewrite `leo-ci.yml` from the bench job and delete `leo-ci-hosted-bench.yml`. Keep:
  - the filename, job id `test-macos`, `workflow_call`, `push: main`, and an unfiltered `pull_request` trigger. `test_ci-runs-script-tests.sh` and `test_release-runs-ci.sh` parse these.
  - the "Build GhosttyKit" step text (`test_ci-zig-version-string.sh`).

  Change:
  - Drop the timing marks and summary, and `LEO_HOST_TESTS`.
  - Hard-pin Xcode 26.3: no fallback, fail if missing.
  - Save caches only when `github.event_name == 'push' && github.ref == 'refs/heads/main'`. PRs and tag calls restore from main. This keeps per-SHA DerivedData keys from churning the 10 GB cache limit.
  - Upload the test log `if: failure()`.
  - Add the D1 job if approved.
- **1b.** `leo-relay.yml`: `ubuntu-24.04` plus setup-node 26; drop the fork guard.
- **1c.** `leo-ios.yml`: `macos-26`, Xcode_26.5 path, pinned xcodegen 2.42.0, simulator check; drop the fork guard.
- **1d.** `leo-bump.yml` and `leo-bump-release.yml`: `runs-on: macos-26` only.

Verification for batch 1:
- The PR runs leo-ci (all script tests, including `test_bump-workflows.sh`), leo-relay and leo-ios, because each workflow's path filter includes its own file. All three must be green.
- Dispatch `gh workflow run leo-bump.yml -R blackpaw-studio/leoterm --ref <branch> -f version=<current pin> -f sha256=<current pin sha>`, taking both from `macos/Bundled/LEO_VERSION`. Expect `verify` green with `bump=false` and `write` skipped. **Never dispatch a newer version** (see risks).
- leo-bump-release can only be exercised by a real bump merge. The change is just `runs-on`, so accept that.

**Batch 2 (after batch 1 is merged; leo-release calls leo-ci)**
- **2a.** leo-build and leo-release:
  - `leo-build.yml`: pinned Xcode 26.3 path, setup-zig 0.16.0.
  - `sign-package.sh`:
    - Retry `hdiutil create` up to 3 times with a short backoff.
    - Before `spctl`, check whether assessments are enabled (`spctl --status`). If they aren't, run `sudo spctl --global-enable`. That's `--master-enable` before macOS 15; I'm not certain of the exact flag behaviour on these images, so the implementer should verify it.
    - Add tests in `tests/` for the retry, test-first.
  - `leo-release.yml`: change `publish` to `runs-on: macos-26` and add a no-input `workflow_dispatch` dry run.
    - On dispatch, `build` gets `release-tag: ''`, which produces a dev version.
    - "Publish release" gets `if: github.event_name == 'push'`.
    - On dispatch, upload `dist/appcast.xml` as an artifact instead of publishing.
- **2b.** `leo-ios-testflight.yml`:
  - `macos-26`, Xcode_26.5 path, `ruby/setup-ruby` 3.3.4 with bundler-cache.
  - Add a `workflow_dispatch` input `upload` (boolean, **default false**). The upload step runs only when `github.event_name == 'push' || inputs.upload`.

Verification for batch 2:
- **2a.** Run `gh workflow run leo-build.yml -R blackpaw-studio/leoterm --ref <branch>`. Download the artifact and check locally:
  - `stapler validate` on the app and the DMG;
  - `spctl -a -t open --context context:primary-signature -vv Leo.dmg`;
  - `lipo -archs` on `Leo.app/Contents/MacOS/Leo` and on `Helpers/{leo,tmux}`;
  - the log's spctl output says `Notarized Developer ID`, not "assessments disabled".

  Then merge. A dispatch trigger has to exist on the default branch before the workflow can be dispatched, so the release dry run can only happen after merging. Run `gh workflow run leo-release.yml` on main and expect:
  - the appcast artifact is identical to the published one (`releases/latest/download/appcast.xml`) apart from one new dev item;
  - `gh release list` shows no new release.

  The real proof is the next `leo-v` tag Evan cuts, followed by Check for Updates on a real install (item 4 of the going-public checklist in `ci.md`).
- **2b.** Run `gh workflow run leo-ios-testflight.yml --ref <branch> -f upload=false` and expect match, archive and export to go green, with no upload. Then, with Evan's approval, run one real upload (dispatch with `upload=true`, or a `leo-ios-vX.Y.Z` tag).

**Batch 3 (docs and cleanup)**
- `docs/leo/ci.md`:
  - The runner section says Dionysus. Change it to hosted runners.
  - Update the toolchain note to the hosted Xcode paths and setup-zig 0.16.
  - It says "repo is private, fork PRs disabled". That's stale: the repo is public.
  - Document the dry-run commands.
- `ios/README.md`, lines 57 and 84: replace the rbenv instructions with setup-ruby.
- Update the memory notes `leo-ci-release.md` and `ci-runner-no-main-screen.md` (the latter is moot now).
- Retire the runner on Dionysus: `~/actions-runner/svc.sh uninstall` and `./config.sh remove`. This needs Evan's approval, since it changes the box.

## 4. Risks

| Risk | Reversible? | Mitigation |
|---|---|---|
| Pushing a `leo-v*` tag runs the full release; a published release plus `appcast.xml` is served at `releases/latest/download/appcast.xml`, and Sparkle clients auto-update from it | **No**, once users have installed the update | Never test by tagging. Use the build dispatch and the dry-run release dispatch. Gate "Publish release" on `event_name == 'push'`, and add a script-test assertion for that gate. |
| TestFlight upload | **No** (builds can only be expired, not deleted; the build number is used up) | `upload` defaults to false; the first real upload needs Evan's approval |
| leo-bump dispatched with a newer version opens a real PR; merging it auto-tags a release | PR yes, tag no | Dry-run only with the currently pinned version. Close any stray bump PR without merging. |
| A leo-build dispatch submits to Apple notarization | Yes (private notary history only) | Acceptable |
| The `macos-26` image drops Xcode 26.3, breaking CI and release | Yes | Hard fail with a clear error, no silent fallback to a newer Xcode (the Zig/SDK link break). Re-check when GitHub announces image changes. |
| `LEO_BUMP_TOKEN` PAT expires, and the bump flow stops silently | Yes | Unchanged by this migration; add a rotation reminder |
| Host tier coverage lost (D1) | Yes | D1 |
| Hosted `hdiutil` flakes, Gatekeeper off, or the disk fills | Yes | Step 2a fixes and verification; D2 fallback |
| Release concurrency group is shared: a dry-run dispatch queues ahead of a real tag | Yes | Don't dry-run while cutting a release |
