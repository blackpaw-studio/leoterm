# Leo.app bundles the leo daemon: app-side plan (2026-10-20)

Spec (source of truth): leo repo `docs/specs/2026-10-20-leo-app-bundled-daemon.md` (@310e989c), "App-side requirements". The leo agent implements leo-side reqs 1–11 in parallel.

**Platform call: Mac only.** iOS has no local daemon, and the spec puts iOS out of scope. The only shared code is the version compare. It goes in LeoKit so a later iOS "remote daemon outdated" warning can reuse it. Nothing is deferred to the iOS backlog.

## Decisions (★ = spec amendment, needs orchestrator sign-off)
- **D1 ★ The binary goes in `Contents/Helpers/leo`, not `Contents/MacOS/leo`.** On case-insensitive APFS, `MacOS/leo` is the same file as the app executable `MacOS/Leo`. `bin/leo` points at `…/Leo.app/Contents/Helpers/leo`, and the LaunchAgent's `BundleProgram` is `Contents/Helpers/leo`. tmux goes at `Contents/Helpers/tmux`.
- **D2 tmux comes from official source tarballs.** Components:
  - tmux: spec example 3.6a; pin the latest stable from github.com/tmux/tmux/releases.
  - libevent 2.1.12-stable, static (`--disable-shared --disable-openssl`).
  - utf8proc, static (`--enable-utf8proc`, matching Homebrew, so emoji widths come out right).
  - ncurses: from the macOS SDK. It is a system dylib, which is allowed.

  Build each arch separately with `MACOSX_DEPLOYMENT_TARGET=13.0`, then `lipo` the results. Pins and source sha256s live in `macos/Bundled/TMUX_VERSION`. CI caches the output with `actions/cache`, keyed on the pin file plus the script hash. Don't publish tmux as a leoterm Release: it would become `releases/latest` and break the Sparkle appcast URL.
- **D3 Pin files and plist keys.** `macos/Bundled/LEO_VERSION` holds `version=` and `sha256=` (the tarball's hash, the same value as the dispatch payload). `macos/Bundled/TMUX_VERSION` holds the tmux pins. `build-app.sh` stamps the Info.plist keys `LeoBundledLeoVersion`, `LeoBundledTmuxVersion` and `LeoDaemonLabel`.
- **D4 Separate labels per build.** The build setting `LEO_DAEMON_LABEL` is `studio.blackpaw.leo.daemon` (Release) or `studio.blackpaw.leo.daemon.debug` (Debug). A Run Script phase generates the LaunchAgent plist from it. Debug builds never register, never write `managed.json` and never hand over unless `LEO_MANAGED_DEBUG=1` is set. This protects Evan's production daemon.
- **D5 Daemon env.** The SMAppService plist is static and signed, so it can't hold `~`, per-user values or the env captured at handover. Proposal: an optional `env` object (string→string) in `managed.json`, applied by the daemon at startup (C5). The app fills it from the handover's captured env. When there is none, it uses the login-shell PATH with `<home>/.local/bin` prepended, which is where the Claude installer puts `claude`.
- **D6 `LeoCLI` lookup order.** override → managed `self_path` → `~/.local/bin/leo` → `PATH` → bundled `Contents/Helpers/leo`. App-owned commands (handover, pair, web enable, managed restart) always run the bundled binary by explicit path.
- **D7 Our own /Applications mover, not LetsMove.** LetsMove relies on the deprecated `AuthorizationExecuteWithPrivileges`, and the mover has to cooperate with `LeoSingleInstance` (B-092). It copies the app, relaunches it and trashes the original. If /Applications isn't writable, it shows instructions and reveals the app in Finder. Debug builds are exempt.
- **D8 Where code lives.** Version compare goes in LeoKit. Everything else goes in the Mac target under `macos/Sources/Features/Leo/Managed/`, with tests in `macos/Tests/Leo/Managed/`. Both are synchronized groups, so pbxproj edits are needed only for build settings and phases.
- **D9 Token for bump PRs and tags.** PRs and tags created with `GITHUB_TOKEN` trigger no workflows: `leo-ci` wouldn't run on the bump PR and `leo-release` wouldn't fire. Use a GitHub App token (`actions/create-github-app-token`) (Q1).
- **D10 Isolation.** Every live check uses scratch `HOME`, `CFFIXED_USER_HOME` and `TMUX_TMPDIR`. SMAppService and /Applications can't be isolated that way, and /Applications is shared by every user on the Mac. Live Phase B checks run in a macOS VM (Q3).

## Seams (built in A6, shared by all steps)
- `LeoFileSystem`:
  - Methods: `kind(at:)` (absent / file / dir / symlink(target)), `read`, `writeAtomically(data,to:,mode:)` (temp file in the same dir, fsync, `rename(2)`), `createDirectory(mode:)`, `symlink`, `replaceSymlinkAtomically`, `copyFile`, `move`, `trash`, `isWritable`, `sha256`.
  - Its in-memory fake records an ordered op log, and tests assert it exactly.
- `LeoLaunchAgentService` wraps `SMAppService.agent(plistName:)`: `status`, `register()`, `unregister()`, `openLoginItemsSettings()`. The fake scripts status values and records calls.
- Existing `LeoProcessRunning`: recording fakes assert the exact executable and argv (the pattern used by `LeoRecordingTemplateRunner`).
- Existing `LeoDaemonTransport`: `LeoDaemonProbe` wraps `GET /health` and returns `.live(version:)`, `.absent` or `.unresponsive`.
- `LeoInstallPaths(home:, bundleURL:)` is pure. Production uses `FileManager.homeDirectoryForCurrentUser`, which honours `CFFIXED_USER_HOME`.
- Clocks follow the `LeoDaemonClock` / `LeoProcessScheduler` patterns. No real sleeps.

## Commands
- `$LEOKIT`: `cd Packages/LeoKit && swiftlint lint --strict && swift test --filter <Suite>`
- `$CISH`: `.github/scripts/leo/run-tests.sh`
- `$MACTEST <Suite>`:
  1. Check that `pgrep -fl "Leo -XCTest"` is empty.
  2. From `macos/`: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
  3. `timeout 600 xcodebuild test-without-building … -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<Suite>`

  Never fall back to the full suite. If the xcframework is missing, run `zig build -Demit-macos-app=false` first.
- `$LINT`: `cd macos && swiftlint lint --strict --quiet`
- `$ALIVE <app>`: `S=/private/tmp/claude-501/leoe2e; mkdir -p $S/home $S/tmux; cd $S && env -u LEO_CONFIG -u LEO_API_TOKEN HOME=$S/home CFFIXED_USER_HOME=$S/home TMUX_TMPDIR=$S/tmux timeout 15 <app>/Contents/MacOS/Leo; echo $?`. Exit 124 means it stayed alive; 6 means it died. Afterwards run `defaults delete studio.blackpaw.leo.macos.debug`.

Every step uses Swift Testing, starts from a failing test you watch fail, and ends in one commit on the current branch.

## Phase A — no leo dependency

**A1 · leo pin and fetch · leo dep: none (`LEO_BINARY` until req 10) · implement**
- Files: `macos/Bundled/LEO_VERSION`, `.github/scripts/leo/fetch-leo.sh OUT_DIR`.
- Behaviour:
  - Read the pin.
  - If `LEO_BINARY` is set, copy that binary and emit `::warning::`. A build with `RELEASE_TAG` set refuses `LEO_BINARY`.
  - Otherwise download via a `CURL=` seam from the URL in C2, check the sha256, and extract into a new empty dir.
  - `lipo -archs` must list arm64 and x86_64, and the version output (C14) must equal the pin.
- Test first, `tests/test_fetch-leo.sh` (fixture tarball built from a stub inside the test): missing pin; sha mismatch (message names expected and actual); override used; release with override refused; thin binary refused.
- Verify: `$CISH`.

**A2 · tmux build and pin · leo dep: none · implement.hard**
- Files: `macos/Bundled/TMUX_VERSION`, `.github/scripts/leo/build-tmux.sh OUT_DIR` (honours `TMUX_BINARY=`), `.github/scripts/leo/check-helper.sh BIN EXPECTED`.
- `check-helper.sh` asserts:
  - `otool -L` lists only `/usr/lib/` and `/System/` libraries;
  - both arches are present;
  - `-V` prints exactly `tmux <pin>`.
- Test first:
  - `tests/test_build-tmux.sh`: pin parse, override, rejection of a source sha mismatch.
  - `tests/test_check-helper.sh`: `/bin/ls` passes; a fake `otool` listing `/opt/homebrew` fails.
- Verify:
  - `$CISH`.
  - A real build plus `check-helper.sh`.
  - Smoke test: `TMUX_TMPDIR=$S/tmux tmux -L t new -d 'sleep 5'`, then `ls`, then `kill-server`.
  - `infocmp` for leo's `default-terminal` (C8).

**A3 · Embed in Leo.app · leo dep: none · implement**
- Add `.github/scripts/leo/embed-helpers.sh APP SRC_ROOT`, called by `build-app.sh` after xcodebuild. It copies both helpers to `Contents/Helpers/` with mode 0755, runs `check-helper.sh` and stamps the version keys.
- If the ref has no `macos/Bundled/LEO_VERSION`, skip with a notice. CI scripts come from the workflow's commit, so this keeps older refs buildable.
- `leo-build.yml` gets a tmux `actions/cache` step that feeds `TMUX_BINARY`.
- Test first, `tests/test_embed-helpers.sh` against a fake `.app`: paths, modes and plist keys are right, and pre-feature refs are skipped.
- Verify: `$CISH`, then a local `build-app.sh` with `LEO_BINARY` and `TMUX_BINARY`.

**A4 · LaunchAgent plist · leo dep: C3 (placeholder until answered) · implement**
- Add `macos/scripts/leo-launch-agent-plist.sh LABEL BUNDLE_ID OUT`.
- In the pbxproj:
  - add `LEO_DAEMON_LABEL` for each configuration;
  - set Info.plist `LeoDaemonLabel=$(LEO_DAEMON_LABEL)`;
  - add a Run Script phase that writes `$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents/$LEO_DAEMON_LABEL.plist`, with its inputs and outputs declared.
- Plist keys:
  - `Label`;
  - `BundleProgram=Contents/Helpers/leo`;
  - `ProgramArguments` (C3);
  - `AssociatedBundleIdentifiers`;
  - `RunAtLoad`;
  - `KeepAlive`;
  - `ProcessType` (C3);
  - `EnvironmentVariables.PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.

  No `~` anywhere.
- Test first:
  - `tests/test_launch-agent-plist.sh`: `plutil -lint`, exact values via `plutil -extract`, no `~`.
  - In-host `LeoBundledLaunchAgentTests` (same pattern as `LeoBundledGhosttyCLITests`): the bundle has the plist, and its `BundleProgram` is right.
- Verify: `$CISH`, `$MACTEST LeoBundledLaunchAgentTests`.

**A5 · Sign inside-out and check the bundle · leo dep: none · implement**
- `sign-package.sh` signs `Helpers/tmux` and `Helpers/leo` (`--options runtime --timestamp`) before Sparkle, the DockTile plugin and the app.
- New `check-bundle.sh APP`, called by `sign-package.sh`, runs `codesign --verify --deep --strict --verbose=2` and checks that each helper has TeamIdentifier `52M9C6892K` and the runtime flag.
- New Xcode Run Script phase "Leo dev helpers": it does nothing unless `LEO_BINARY`/`TMUX_BINARY` build settings are set. When they are, it copies the helpers and signs them with `$EXPANDED_CODE_SIGN_IDENTITY` (or `-`).
- Test first, `tests/test_check-bundle.sh` with an ad-hoc-signed fake app:
  - an unsigned helper fails;
  - a signed tree passes (the TeamID check is skipped for ad-hoc);
  - `nested_code_paths` puts the helpers before the app.
- Verify: `$CISH`; a local ad-hoc bundle, then `check-bundle.sh`, then `$ALIVE`. Then one `gh workflow run leo-build.yml -R blackpaw-studio/leoterm -f ref=<branch>` and, on the artifact, `check-bundle.sh`, `spctl -a -vv` and the two helper version checks.

**A6 · Paths, file-system seam and `managed.json` · leo dep: none · implement**
- Files: `Managed/LeoInstallPaths.swift`, `LeoFileSystem.swift`, `LeoManagedMarker.swift` (plus `LeoMarkerStore`).
- Writes absolute paths (C9). Reads come back as `.absent`, `.ours`, `.foreign(bundleID)` or `.invalid(reason)`; an unknown version, malformed JSON or a relative path is `.invalid`.
- Test first, `LeoManagedMarkerTests`:
  - exact keys `version, manager, bundle_id, launchd_label, self_path, tmux_path` (plus optional `env`, C5);
  - each decode case;
  - op log: `createDirectory(state,0700)` only when it's absent → `write(.managed.json.<uuid>.tmp,0600)` → `rename`;
  - remove unlinks only `managed.json`.
- Verify: `$MACTEST LeoManagedMarkerTests`.

**A7 · `LeoCLI` lookup order · leo dep: none · implement**
- Inject a marker reader and the bundled path, and order candidates per D6. A foreign marker's `self_path` still counts.
- Test first, `LeoCLICandidateOrderTests`: the exact list for each marker state and for a missing helper, and an error message that lists every candidate. `LeoCLITests` stay green.
- Verify: `$MACTEST LeoCLICandidateOrderTests`, `$MACTEST LeoCLITests`.

**A8 · `LeoDaemonVersion` (LeoKit) · leo dep: C15 · implement**
- A tolerant parse that `LeoAPIFlavor.select` is refactored onto, plus `isSameRelease`, which ignores a `v` prefix and `+build` but keeps the prerelease.
- Test first, table: `v0.33.0`≡`0.33.0`; `0.33.0+abc`≡`0.33.0`; `0.33.0-dev.1`≢`0.33.0`; `garbage`→nil.
- Verify: `$LEOKIT LeoDaemonVersionTests`, `$LEOKIT LeoAPIFlavor`.

**A9 · /Applications check and mover · leo dep: none · implement**
- `decide(bundleURL:, buildKind:)` returns:
  - `.inApplications`: the parent dir is exactly `/Applications`;
  - `.needsMove(.translocated | .elsewhere | .readOnlyVolume)`;
  - `.exempt`: a Debug build.
- `LeoAppMover`:
  1. Copy to `/Applications/<name>.app`. If a copy already exists, ask first; refuse if it's running.
  2. Mark the instance claim as exiting.
  3. `openApplication(createsNewApplicationInstance: true)`.
  4. Terminate.
  5. Trash the original, except from a DMG or a read-only volume.

  If /Applications isn't writable, show instructions and reveal the app in Finder.
- The "Not Now" path keeps managed features off and shows a sidebar banner. The alert styling is a TDD exception.
- Test first, `LeoAppLocationTests`: the decision table (including an `AppTranslocation` path) and the exact op and opener log for each branch.
- Verify: `$MACTEST LeoAppLocationTests`, plus a manual check in the VM.

**A10 · Server-only mode · leo dep: none · implement**
- Pure `activationPolicy(macosHidden:, serverOnly:)` and `quitsAfterLastWindowClosed(config:, serverOnly:)`.
- Wire them into `AppDelegate.ghosttyConfigDidChange` (~L944) and `applicationShouldTerminateAfterLastWindowClosed` (~L484), so a config reload can't undo server mode.
- Persist the choice as `leo.serverOnly` in `UserDefaults.ghostty`. Leaving server mode opens a window if none is open.
- Test first, `LeoServerModeTests`: the table, and a round trip through `LeoInMemoryDefaults`.
- Verify: `$MACTEST LeoServerModeTests`, `$ALIVE`.

**A11 · Menu bar extra (Phase A items) · leo dep: C10, C4 · implement**
- A pure `LeoMenuBarModel` turns (snapshot, version, managed, serverOnly) into `[LeoMenuBarItem]`. `LeoMenuBarController` renders it as an `NSStatusItem` and rebuilds the menu in `menuNeedsUpdate`.
- Items:
  - status;
  - agents submenu (uses the existing `attachRequested`; opens a window first if none is open);
  - Restart Daemon;
  - Open Logs;
  - Run as Server Only;
  - Open Leo;
  - Quit.

  Pair arrives in B7 and Release to CLI in B4.
- Visible by default, with a toggle in Settings (`leo.menuBarExtra`). Server-only mode forces it on.
- Test first, `LeoMenuBarModelTests`: items for each state, and exact argv (restart is `[leo,"service","restart"]` until C10 says otherwise). Rendering is a TDD exception: verify with a Peekaboo screenshot or have Evan look.
- Verify: `$MACTEST LeoMenuBarModelTests`, `$LINT`, `$ALIVE`.

**A12 · Login-shell PATH and env merge · leo dep: C5 (wired in B2) · implement**
- Take the shell from `getpwuid` and require it to be listed in `/etc/shells`. Run exactly `[shell,"-l","-c","/usr/bin/printenv PATH"]` with a 10 s timeout.
- The output must be one line of absolute directories separated by colons. If it isn't, fall back to the static PATH.
- `merge(captured:, loginPath:, home:)`:
  - PATH = de-duplicated `<home>/.local/bin` + captured or login PATH + static PATH;
  - captured keys win;
  - drop `SSH_AUTH_SOCK`, `TMUX*`, `TERM_SESSION_ID`, `__CF*`, `XPC_*` and `LEO_CONFIG`.
- Test first, `LeoDaemonEnvironmentTests`: argv, validation, fallback, and the merge table.

**A13 · Claude onboarding · leo dep: none · implement**
- Look for `claude` in order: `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, then the login PATH.
- Install with `curl -fsSL https://claude.ai/install.sh | bash && "$HOME/.local/bin/claude"`. Check that URL against Anthropic's docs at implementation time.
- The command runs through `LeoCommandLauncher.openWindow`. Leo has no tabs (D-098), so it opens a window.
- Show it once, after the first run reaches a live local daemon, if `claude` is missing. Leo ▸ "Set Up Claude…" stays available afterwards.
- Test first, `LeoClaudeOnboardingTests`: the lookup order, the exact command, and the one-time flag.

**A14 · `bin/leo` refresh and "Install leo command" · leo dep: none · implement**
- `LeoSelfLink`: on each launch, when the app is in /Applications and the helper exists, `replaceSymlinkAtomically(<AppSupport>/Leo/bin/leo → <bundle>/Contents/Helpers/leo)`. It does nothing if the link is already correct.
- `LeoCommandInstaller.plan` returns `.create`, `.alreadyInstalled`, `.confirmReplace(backup: leo.pre-leoapp)` or `.refuse(.directory)`. It never deletes, creates `~/.local/bin` (0755) if needed, and shows a PATH hint when `~/.local/bin` isn't on PATH. The menu item is Leo ▸ "Install ‘leo’ Command…".
- Test first, `LeoSelfLinkTests` and `LeoCommandInstallerTests`: plan tables (absent, our symlink, foreign symlink, file, dir) and exact op logs.

**Phase A done:** the signed bundle contains the helpers (via the dev override), every unit is green, and `$ALIVE` passes. Nothing registers yet and nothing writes `managed.json`.

## Phase B — needs the new leo surfaces

**B1 · First-run decision table · leo dep: req 7 · implement.hard**
- Pure `decide(LeoFirstRunInputs) -> LeoFirstRunAction`.
- Inputs:
  - location;
  - probe: live(version) / absent / unresponsive;
  - marker: absent / ours / foreign / invalid;
  - CLI install (C13): installed / handed-over / none;
  - agent status: notRegistered / enabled / requiresApproval / notFound;
  - takeover answer;
  - build kind.
- Actions:
  - `.blockMove`;
  - `.useLive(offerTakeover:)`;
  - `.install`;
  - `.ensureManaged(refreshLink:, register:)`;
  - `.awaitApproval`;
  - `.repair(reason)`;
  - `.offerStartCLI`: the CLI is installed but stopped; never take over automatically;
  - `.observeOnly`: a foreign marker, or Debug without `LEO_MANAGED_DEBUG`.
- Test first, `LeoFirstRunTests`: a parameterized table with one row per transition, all written before the code.

**B2 · Setup executor · leo dep: reqs 1–4 and 7, C3, C5 · implement.hard**
- Steps, in order:
  1. Copy tmux to `~/Library/Application Support/Leo/tmux/<ver>/tmux`, where `<ver>` is exactly the bundled `tmux -V` output minus the `tmux ` prefix, only if that path is absent (temp file + rename, 0755, sha check). Never overwrite or delete a version dir while a `-L leo` server could use it. The marker's `tmux_path` names the version new servers start on.
  2. Refresh `bin/leo`.
  3. Write the marker, with `env` from A12.
  4. `register()`.
  5. Wait up to 20 s for hello or `/health` (injected clock).
- If the status is `.requiresApproval`, show "Allow Leo in Login Items" with `openLoginItemsSettings()` and check again on `didBecomeActive`.
- If step 4 or 5 fails, run `unregister()` and remove the marker (keep the tmux copy), then show the error panel.
- Test first, `LeoManagedSetupTests`: the happy-path op log, the exact rollback log for each failing step, version dirs never overwritten, and the approval-pending path.

**B3 · Takeover · leo dep: req 8, C6 · implement.hard**
- Offer once, and remember the answer.
- Run `[<bundled>,"service","handover","--to-app","--label",<LeoDaemonLabel>,"--json"]` with the drain timeout from C6.
- Decode `{ok,previous_label,env}` or `{ok:false,step,error}`. Malformed output or a non-zero exit counts as failure: keep the CLI daemon and write nothing.
- Preflight error `no_launchd_job` (the daemon wasn't started via launchd) means automatic takeover isn't possible: keep using the live daemon, write nothing, and show a note on how to stop it.
- On `ok`, run B2 with the captured env. If B2 then fails, run `--to-cli` (C7).
- Test first, `LeoHandoverTests`: argv, decode fixtures, and the rollback sequence.

**B4 · Release to CLI · leo dep: req 8, C7, C12 · implement.hard**
- Ask for confirmation first.
- If `~/.local/bin/leo` is our symlink and `leo.pre-leoapp` exists, restore the backup first. Otherwise the restored CLI plist could run the app's binary.
- Then run `[<bundled>,"service","handover","--to-cli","--json"]` FIRST. leo drains, boots out the app's label and restores the CLI daemon.
- Only on `ok:true`, call `SMAppService.unregister()` and clear the takeover answer.
- `ok:false` + `managed_stopped:true`: leo rolled back, so the app re-registers its agent. `ok:false` + `managed_stopped:false`: nothing changed.
- On launch, if the marker is absent but the agent is still registered with SMAppService, `unregister()` (recovery from a crash between the two steps; add this row to B1/B9).
- Test first, `LeoReleaseToCLITests`: argv and op order, the restore branch, and failure leaving state intact.

**B5 · Startup integration · leo dep: reqs 1 and 6 · implement.hard**
- In `LeoRuntime.start()`: location → probe → decide → execute, all before `hostSelection.start`.
- The "Start daemon" buttons in `LeoSidebarView` (L277 and L292) become the action-specific button: Set Up / Allow in Login Items / Move to Applications / Start CLI Daemon.
- Test first, `LeoRuntimeManagedStartTests`:
  - a fresh install runs `.install` once;
  - a live CLI daemon shows the offer and writes nothing;
  - a Debug build makes no `LeoLaunchAgentService` calls.

  `LeoRuntimeConnectionTests` stay green, and `$ALIVE` (isolated) passes.

**B6 · Restart after a Sparkle update · leo dep: req 6, C10, C15 · implement**
- On the first hello after launch, check `shouldRestart(managedByUs:, bundled:, running:, alreadyTriedPair:)`. If it says restart:
  1. Copy the new tmux version alongside the old one.
  2. Run the bundled `["service","restart"]`.
- Restart at most once per launch for each version pair. If the versions still differ afterwards, show a banner pointing at `leo doctor`.
- Test first, `LeoPostUpdateRestartTests`: the policy table, argv, and no restart loop.

**B7 · Pair a Device · leo dep: req 9, C11 · implement**
- Run `["pair","--json"]` and decode the flat fields `daemon_id`, `name`, `urls`, `pairing_code`, `warnings[]`, `expires_at` (RFC3339) and `qr_payload`.
- Generate the QR with `CIQRCodeGenerator` (correction level M) from `qr_payload`, encoded verbatim. Refresh at `expires_at`. Show the code, the warnings and a Copy button.
- With web off, pair exits non-zero with `{"error":"web_disabled"}`. Offer to enable it: run `["web","enable","--json"]` (optionally `--bind addr`, `--allow-host h`), which returns `{ok,changed,restarted,web:{enabled,bind,port}}`. When `restarted` is true, wait for the daemon to come back, then retry pairing.
- Test first, `LeoPairDeviceTests`: decode fixtures, the exact argv sequence on the `web_disabled` path, and a QR string that round-trips through `parse`. The sheet layout is a TDD exception.

**B8 · Bump PR and release workflows · leo dep: req 10, C2 · implement**
- `leo-bump.yml` runs on `repository_dispatch` `[leo-release]`:
  - the payload is passed through `env:`, never `${{ }}` in `run:`;
  - `bump-leo.sh` validates the semver and the 64-hex sha256, downloads and verifies the asset, and rewrites the pin;
  - it opens a PR from `leo-bump/<version>` with the App token, and does nothing if that PR already exists.
- `leo-bump-release.yml` runs on a bump commit to main that touches `LEO_VERSION`. It computes the next patch `leo-v` tag and pushes it with the App token (Q2).
- Test first, `tests/test_bump-leo.sh`: rejects `1.0.0;rm -rf`, a short sha and a sha mismatch, and writes the exact pin. Run `actionlint` if it's available.

**B9 · Repair and blocking states · leo dep: req 1 · implement**
- Repair an invalid marker by rewriting it from the current bundle and registering again.
- If the app is managed but no longer in /Applications, show a blocking "Move Leo back to Applications" message. The daemon keeps running.
- Test first: the `LeoFirstRunTests` rows plus `LeoManagedSetupTests` op logs.

## End-to-end verification
1. **Unit tests:** every `$MACTEST` suite, LeoKit `swift test`, `$CISH`, `$LINT`.
2. **Bundle:**
   - Locally: dev overrides, ad-hoc signing, `check-bundle.sh`, then `$ALIVE` must exit 124.
   - In CI: run `leo-build`. On the notarized artifact, check `check-bundle.sh`, `spctl -a -vv` and the pinned helper versions.
3. **Live, in a VM (Q3), with a signed build installed in /Applications:**
   - (a) Fresh install: the agent registers, hello arrives, `leo doctor` reports managed, and Claude onboarding appears.
   - (b) An existing curl install with a running agent: takeover works and the tmux session survives.
   - (c) Release to CLI: the CLI daemon comes up and the marker is gone.
   - (d) A Sparkle update vN→vN+1 from a local appcast: a graceful restart, `hello.version` equals the bundled version, and the old tmux dir is kept.
   - (e) Moving the app out of /Applications triggers the block.

   Never run this on Evan's account without his go.

## Contract questions (leo agent)
- **C1 Paths with spaces.** `self_path` contains a space. Every persist site that embeds it in a shell or tmux string (hooks, the tmux prefix+L binding, `LEO_BRIDGE_BIN`) must quote it. If leo can't guarantee that, use a space-free root such as `~/.leo/app/{bin,tmux}` (★). Also confirm nothing assumes `.app/Contents/MacOS/leo` (D1).
- **C2 Release asset.** Exact URL and tag form; is the repo public; tarball layout; is the payload version `v`-prefixed; is sha256 the tarball's hash?
- **C3 Managed plist.** `ProgramArguments` (`leo service --daemon`?), plus the `KeepAlive`, `ProcessType`, throttle and stdout/stderr keys leo's own plist uses. The plist is static: no `~`.
- **C4 Logs.** Where the daemon logs without `StandardOutPath`, and the path or command for "Open Logs".
- **C5 Env.** Optional `env` in `managed.json`, staying at version 1? Which variables are needed beyond PATH?
- **C6 Handover output.** JSON fields and types, exit codes, stdout-only JSON, the drain bound, and whether `--to-app` works when the CLI daemon is stopped or unloaded.
- **C7 `--to-cli` order.** Who boots out the managed label, and in what order relative to bootstrapping the CLI daemon? Is `--to-cli` valid after a failed `--to-app`?
- **C8 tmux.** Version parsing of `3.6a` and `next-3.x`; leo's `default-terminal`; is `TERMINFO_DIRS` needed?
- **C9 Paths in the marker.** Are absolute paths accepted? Is the `self_path` symlink persisted unresolved?
- **C10 Restart.** Is `service restart` graceful by default? Exit codes when the daemon is down.
- **C11 Pairing.** `pair --json` shape and error shape, the code's TTL, `web enable`'s default bind and when it returns.
- **C12 Update guard.** Unmanaged `leo update` must refuse when its executable resolves inside a `.app`.
- **C13 Detecting a CLI install.** Plist path, or `leo service status --json`?
- **C14 Version output.** `leo version` output format.
- **C15 Hello version.** `hello.version` format.

## Open questions (Evan / orchestrator)
- **Q1** A GitHub App or PAT secret for bump PRs and tags.
- **Q2** Should a merged bump auto-tag a release?
- **Q3** A macOS VM for the live Phase B checks.
- **Q4** Sign-off on D1 (approved, see below), and on C1 if paths change.

## Contract answers from leo agent (2026-10-20)
- tmux: the app builds and pins it; version ≥3.2 (3.6a matches today). Install at `~/Library/Application Support/Leo/tmux/<ver>/tmux`, where `<ver>` is exactly the `tmux -V` output minus the "tmux " prefix. Never overwrite or delete a version dir while a `-L leo` server could use it. `managed.json` `tmux_path` is the version new servers should start on.
- Release to CLI: the app calls `leo service handover --to-cli --json` FIRST. leo drains, boots out the app's label and restores the CLI daemon. Only on `ok:true` does the app call `SMAppService.unregister()`. `ok:false` + `managed_stopped:true` means leo rolled back, so the app re-registers its agent. `ok:false` + `managed_stopped:false` means no change. On launch, if the marker is absent but SMAppService is registered, unregister (crash-between-steps recovery).
- `leo pair --json`: flat fields `daemon_id`, `name`, `urls`, `pairing_code`, plus `warnings[]`, `expires_at` (RFC3339) and `qr_payload` (encode verbatim in the QR; refresh at `expires_at`). Web off → `{"error":"web_disabled"}` with a non-zero exit.
- `leo web enable [--bind addr] [--allow-host h]... --json` → `{ok, changed, restarted, web:{enabled,bind,port}}`.
- `leo service handover --to-app` preflight error `no_launchd_job` (daemon not started via launchd): the app treats it as "can't take over automatically", keeps using the live daemon and shows a note on how to stop it.
- Requested of leo (pending confirmation): all `--json` commands print only JSON on stdout (logs to stderr); failures are JSON with a stable `error` code (+ optional `message`) and a non-zero exit.
- Orchestrator decision: D1 (`Contents/Helpers/leo` instead of `Contents/MacOS/leo`) is approved.
