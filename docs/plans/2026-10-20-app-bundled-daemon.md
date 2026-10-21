# Leo.app bundles the leo daemon: app-side plan (2026-10-20)

Spec (source of truth): leo repo `docs/specs/2026-10-20-leo-app-bundled-daemon.md` (@310e989c), "App-side requirements". The leo agent implements leo-side reqs 1–11 in parallel.

**Platform call: Mac only.** iOS has no local daemon, and the spec puts iOS out of scope. The only shared code is the version compare. It goes in LeoKit so a later iOS "remote daemon outdated" warning can reuse it. Nothing is deferred to the iOS backlog.

**Leo version floors (round 2).** Each step carries `min leo:`.
- none: no leo dependency.
- ≥0.56.0: marker, `self_path`, daemon lock, update refusal, tmux resolution, `darwin_universal` asset.
- ≥0.57.0: `handover`, `pair --json`, `web enable`, managed service routing.

**Contract status.** C1–C15 are answered (round 1 and round 2 sections at the end). The few leftovers are listed under "Contract questions".

## Decisions (★ = spec amendment; all approved by the orchestrator)
- **D1 ★ (approved) The binary goes in `Contents/Helpers/leo`, not `Contents/MacOS/leo`.** On case-insensitive APFS, `MacOS/leo` is the same file as the app executable `MacOS/Leo`. `~/.leo/app/bin/leo` points at `…/Leo.app/Contents/Helpers/leo`, and the LaunchAgent's `BundleProgram` is `Contents/Helpers/leo`. tmux goes at `Contents/Helpers/tmux`.
- **D2 tmux comes from official source tarballs.** Components:
  - tmux: spec example 3.6a; pin the latest stable from github.com/tmux/tmux/releases.
  - libevent 2.1.12-stable, static (`--disable-shared --disable-openssl`).
  - utf8proc, static (`--enable-utf8proc`, matching Homebrew, so emoji widths come out right).
  - ncurses: from the macOS SDK. It is a system dylib, which is allowed.

  Build each arch separately with `MACOSX_DEPLOYMENT_TARGET=13.0`, then `lipo` the results. Pins and source sha256s live in `macos/Bundled/TMUX_VERSION`. CI caches the output with `actions/cache`, keyed on the pin file plus the script hash. Don't publish tmux as a leoterm Release: it would become `releases/latest` and break the Sparkle appcast URL.
- **D3 Pin files and plist keys.** `macos/Bundled/LEO_VERSION` holds `version=` and `sha256=` (the tarball's hash, the same value as the dispatch payload). `macos/Bundled/TMUX_VERSION` holds the tmux pins. `build-app.sh` stamps the Info.plist keys `LeoBundledLeoVersion`, `LeoBundledTmuxVersion` and `LeoDaemonLabel`.
- **D4 Separate labels per build.** The build setting `LEO_DAEMON_LABEL` is `studio.blackpaw.leo.daemon` (Release) or `studio.blackpaw.leo.daemon.debug` (Debug). A Run Script phase generates the LaunchAgent plist from it. Debug builds never register, never write `managed.json` and never hand over unless `LEO_MANAGED_DEBUG=1` is set. This protects Evan's production daemon.
- **D5 Daemon env (accepted).** The SMAppService plist is static and signed, so it can't hold `~`, per-user values or the env captured at handover. `managed.json` carries an optional `env` object (string→string), which the daemon applies at startup on top of its own environment. The app fills it from the handover's captured env. When there is none, it uses the login-shell PATH with `<home>/.local/bin` prepended, which is where the Claude installer puts `claude`. It also puts `TERMINFO_DIRS` there (A2b). The marker is written 0600: leo ignores a group- or world-writable marker.
- **D11 Layout (round 2, supersedes the spec paths).** There are no spaces anywhere under the app's state root: `~/.leo/app/bin/leo` → `Leo.app/Contents/Helpers/leo`, and tmux copies at `~/.leo/app/tmux/<ver>/tmux`. Nothing lives under `~/Library/Application Support/Leo/`. `managed.json` `self_path` and `tmux_path` use these paths, and `self_path` is persisted exactly as given (never symlink-resolved).
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
- Existing `LeoDaemonTransport`: `LeoDaemonProbe` wraps `hello` on `~/.leo/state/leo.sock`, which is authoritative, and returns `.live(version:)`, `.absent` or `.unresponsive`.
- `LeoInstallPaths(home:, bundleURL:)` is pure. Production uses `FileManager.homeDirectoryForCurrentUser`, which honours `CFFIXED_USER_HOME`.
- Clocks follow the `LeoDaemonClock` / `LeoProcessScheduler` patterns. No real sleeps.

## Commands
- `$LEOKIT`: `cd Packages/LeoKit && swiftlint lint --strict && swift test --filter <Suite>`
- `$CISH`: `.github/scripts/leo/run-tests.sh`
- `$MACTEST <Suite>`:
  1. Check that `pgrep -f "/Leo\.app/Contents/MacOS/Leo -XCTest"` prints nothing. The bare `"Leo -XCTest"` pattern also matches any unrelated process whose argv mentions it; this one needs the real `Leo.app/Contents/MacOS/Leo -XCTest` command line, and its `\.` keeps a wrapping shell's own command line from matching it.
  2. From `macos/`: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
  3. `timeout 600 xcodebuild test-without-building … -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<Suite>`

  Never fall back to the full suite. If the xcframework is missing, run `zig build -Demit-macos-app=false` first.
- `$LINT`: `cd macos && swiftlint lint --strict --quiet`
- `$ALIVE <app>`: `S=/private/tmp/claude-501/leoe2e; mkdir -p $S/home $S/tmux; cd $S && env -u LEO_CONFIG -u LEO_API_TOKEN HOME=$S/home CFFIXED_USER_HOME=$S/home TMUX_TMPDIR=$S/tmux timeout 15 <app>/Contents/MacOS/Leo; echo $?`. Exit 124 means it stayed alive; 6 means it died. Afterwards run `defaults delete studio.blackpaw.leo.macos.debug`.

Every step uses Swift Testing, starts from a failing test you watch fail, and ends in one commit on the current branch.

## Phase A — no leo dependency

**A1 · leo pin and fetch · min leo: none with `LEO_BINARY`; ≥0.56.0 for the real asset · implement**
- Files: `macos/Bundled/LEO_VERSION`, `.github/scripts/leo/fetch-leo.sh OUT_DIR`.
- Behaviour:
  - Read the pin.
  - If `LEO_BINARY` is set, copy that binary and emit `::warning::`. A build with `RELEASE_TAG` set refuses `LEO_BINARY`.
  - Otherwise download via a `CURL=` seam from `https://github.com/blackpaw-studio/leo/releases/download/v<ver>/leo_<ver>_darwin_universal.tar.gz` (public repo, `v` prefix in the tag and URL only, none in the pin), check the sha256 (the tarball's hash, as in `checksums.txt`), and extract into a new empty dir. The binary `leo` is at the archive root (confirm on the first real release).
  - `lipo -archs` must list arm64 and x86_64, and `leo version` (`leo <semver>`; strip the `leo ` prefix) must equal the pin.
- Test first, `tests/test_fetch-leo.sh` (fixture tarball built from a stub inside the test): missing pin; a `v`-prefixed pin; sha mismatch (message names expected and actual); override used; release with override refused; thin binary refused.
- Verify: `$CISH`.

**A2 · tmux build and pin · min leo: none · implement.hard**
- Files: `macos/Bundled/TMUX_VERSION`, `.github/scripts/leo/build-tmux.sh OUT_DIR` (honours `TMUX_BINARY=`), `.github/scripts/leo/check-helper.sh BIN EXPECTED`.
- `check-helper.sh` asserts:
  - `otool -L` lists only `/usr/lib/` and `/System/` libraries;
  - both arches are present;
  - `-V` prints exactly `tmux <pin>`. leo requires tmux ≥3.2 (3.6a matches today).
- Test first:
  - `tests/test_build-tmux.sh`: pin parse, override, rejection of a source sha mismatch.
  - `tests/test_check-helper.sh`: `/bin/ls` passes; a fake `otool` listing `/opt/homebrew` fails.
- Verify:
  - `$CISH`.
  - A real build plus `check-helper.sh`.
  - Smoke test: `TMUX_TMPDIR=$S/tmux tmux -L t new -d 'sleep 5'`, then `ls`, then `kill-server`.
  - `infocmp tmux-256color` resolves against the bundled terminfo (A2b), since stock macOS lacks that entry.

**A2b · tmux terminfo in the bundle · min leo: none · implement**
- leo doesn't set `default-terminal`, so the bundle must ship the `tmux-256color` terminfo entry. Reuse or extend the terminfo directory Ghostty already ships in the bundle (find it first; the plan assumes `Contents/Resources/terminfo`).
- `embed-helpers.sh` (A3) adds the entry (compile it with `tic -x -o` from the pinned ncurses terminfo source, or copy the SDK's if present) and `check-bundle.sh` (A5) asserts it exists.
- The app puts `TERMINFO_DIRS=<bundle>/Contents/Resources/terminfo` in the marker's `env` (A12/B2).
- Test first, `tests/test_embed-helpers.sh` (extended): the entry exists in the fake app's terminfo dir. The in-host `LeoBundledLaunchAgentTests` sibling asserts it in the real bundle.
- Verify: `$CISH`, then `TERMINFO_DIRS=<dir> infocmp tmux-256color`.

**A3 · Embed in Leo.app · min leo: none · implement**
- Add `.github/scripts/leo/embed-helpers.sh APP SRC_ROOT`, called by `build-app.sh` after xcodebuild. It copies both helpers to `Contents/Helpers/` with mode 0755, runs `check-helper.sh` and stamps the version keys.
- If the ref has no `macos/Bundled/LEO_VERSION`, skip with a notice. CI scripts come from the workflow's commit, so this keeps older refs buildable.
- `leo-build.yml` gets a tmux `actions/cache` step that feeds `TMUX_BINARY`.
- Test first, `tests/test_embed-helpers.sh` against a fake `.app`: paths, modes and plist keys are right, and pre-feature refs are skipped.
- Verify: `$CISH`, then a local `build-app.sh` with `LEO_BINARY` and `TMUX_BINARY`.

**A4 · LaunchAgent plist · min leo: none to build it; ≥0.57.0 to be routed as managed · implement**
- Add `macos/scripts/leo-launch-agent-plist.sh LABEL BUNDLE_ID OUT`.
- In the pbxproj:
  - add `LEO_DAEMON_LABEL` for each configuration;
  - set Info.plist `LeoDaemonLabel=$(LEO_DAEMON_LABEL)`;
  - add a Run Script phase that writes `$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents/$LEO_DAEMON_LABEL.plist`, with its inputs and outputs declared.
- Plist keys:
  - `Label`;
  - `BundleProgram=Contents/Helpers/leo`;
  - `ProgramArguments=[leo, "service", "--supervised"]` (no `--config`);
  - `AssociatedBundleIdentifiers`;
  - `RunAtLoad=true`;
  - `KeepAlive=true`;
  - `EnvironmentVariables.PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.

  Deliberately absent: `ProcessType`, `ThrottleInterval` (the default applies), `StandardOutPath` and `StandardErrorPath` (the daemon logs to `~/.leo/state/service.log` itself), and `WorkingDirectory` (unset, or `/`). No `~` anywhere.
- Test first:
  - `tests/test_launch-agent-plist.sh`: `plutil -lint`, exact values via `plutil -extract`, no `~`, and the absent keys stay absent.
  - In-host `LeoBundledLaunchAgentTests` (same pattern as `LeoBundledGhosttyCLITests`): the bundle has the plist, and its `BundleProgram` is right.
- Verify: `$CISH`, `$MACTEST LeoBundledLaunchAgentTests`.

**A5 · Sign inside-out and check the bundle · min leo: none · implement**
- `sign-package.sh` signs `Helpers/tmux` and `Helpers/leo` (`--options runtime --timestamp`) before Sparkle, the DockTile plugin and the app.
- New `check-bundle.sh APP`, called by `sign-package.sh`, runs `codesign --verify --deep --strict --verbose=2` and checks that each helper has TeamIdentifier `52M9C6892K` and the runtime flag.
- New Xcode Run Script phase "Leo dev helpers": it does nothing unless `LEO_BINARY`/`TMUX_BINARY` build settings are set. When they are, it copies the helpers and signs them with `$EXPANDED_CODE_SIGN_IDENTITY` (or `-`).
- Test first, `tests/test_check-bundle.sh` with an ad-hoc-signed fake app:
  - an unsigned helper fails;
  - a signed tree passes (the TeamID check is skipped for ad-hoc);
  - `nested_code_paths` puts the helpers before the app.
- Verify: `$CISH`; a local ad-hoc bundle, then `check-bundle.sh`, then `$ALIVE`. Then one `gh workflow run leo-build.yml -R blackpaw-studio/leoterm -f ref=<branch>` and, on the artifact, `check-bundle.sh`, `spctl -a -vv` and the two helper version checks.

**A6 · Paths, file-system seam and `managed.json` · min leo: ≥0.56.0 (marker format) · implement**
- Files: `Managed/LeoInstallPaths.swift`, `LeoFileSystem.swift`, `LeoManagedMarker.swift` (plus `LeoMarkerStore`).
- Writes absolute, space-free paths under `~/.leo/app/` (D11); `self_path` is stored exactly as given. Reads come back as `.absent`, `.ours`, `.foreign(bundleID)` or `.invalid(reason)`; an unknown version, malformed JSON or a relative path is `.invalid`.
- Test first, `LeoManagedMarkerTests`:
  - exact keys `version, manager, bundle_id, launchd_label, self_path, tmux_path` (plus optional `env`);
  - the marker is written with mode 0600 (leo ignores a group- or world-writable one);
  - each decode case;
  - op log: `createDirectory(~/.leo/state,0700)` only when it's absent → `write(.managed.json.<uuid>.tmp,0600)` → `rename`;
  - remove unlinks only `managed.json`.
- Verify: `$MACTEST LeoManagedMarkerTests`.

**A7 · `LeoCLI` lookup order · min leo: ≥0.56.0 (reads the marker) · implement**
- Inject a marker reader and the bundled path, and order candidates per D6. A foreign marker's `self_path` still counts.
- Test first, `LeoCLICandidateOrderTests`: the exact list for each marker state and for a missing helper, and an error message that lists every candidate. `LeoCLITests` stay green.
- Verify: `$MACTEST LeoCLICandidateOrderTests`, `$MACTEST LeoCLITests`.

**A8 · `LeoDaemonVersion` (LeoKit) · min leo: none · implement**
- Used for display and a later iOS warning only. The restart decision (B6) is plain string inequality, not this compare. `hello.version` is bare semver and `leo version` prints `leo <semver>`, so the parse tolerates both.
- A tolerant parse that `LeoAPIFlavor.select` is refactored onto, plus `isSameRelease`, which ignores a `v` prefix and `+build` but keeps the prerelease.
- Test first, table: `v0.33.0`≡`0.33.0`; `0.33.0+abc`≡`0.33.0`; `0.33.0-dev.1`≢`0.33.0`; `garbage`→nil.
- Verify: `$LEOKIT LeoDaemonVersionTests`, `$LEOKIT LeoAPIFlavor`.

**A9 · /Applications check and mover · min leo: none · implement**
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

**A10 · Server-only mode · min leo: none · implement**
- Pure `activationPolicy(macosHidden:, serverOnly:)` and `quitsAfterLastWindowClosed(config:, serverOnly:)`.
- Wire them into `AppDelegate.ghosttyConfigDidChange` (~L944) and `applicationShouldTerminateAfterLastWindowClosed` (~L484), so a config reload can't undo server mode.
- Persist the choice as `leo.serverOnly` in `UserDefaults.ghostty`. Leaving server mode opens a window if none is open.
- Test first, `LeoServerModeTests`: the table, and a round trip through `LeoInMemoryDefaults`.
- Verify: `$MACTEST LeoServerModeTests`, `$ALIVE`.

**A11 · Menu bar extra (Phase A items) · min leo: none for the CLI daemon; ≥0.57.0 for managed restart routing · implement**
- A pure `LeoMenuBarModel` turns (snapshot, version, managed, serverOnly) into `[LeoMenuBarItem]`. `LeoMenuBarController` renders it as an `NSStatusItem` and rebuilds the menu in `menuNeedsUpdate`.
- Items:
  - status;
  - agents submenu (uses the existing `attachRequested`; opens a window first if none is open);
  - Restart Daemon;
  - Open Logs (opens `~/.leo/state/service.log`);
  - Run as Server Only;
  - Open Leo;
  - Quit.

  Pair arrives in B7 and Release to CLI in B4.
- Visible by default, with a toggle in Settings (`leo.menuBarExtra`). Server-only mode forces it on.
- Test first, `LeoMenuBarModelTests`: items for each state, and exact argv (restart is always `[leo,"service","restart","--graceful"]`, never bare `restart`, which may prompt; in managed mode it targets the app's label). Rendering is a TDD exception: verify with a Peekaboo screenshot or have Evan look.
- Verify: `$MACTEST LeoMenuBarModelTests`, `$LINT`, `$ALIVE`.

**A12 · Login-shell PATH and env merge · min leo: ≥0.56.0 (the marker `env` field; wired in B2) · implement**
- Take the shell from `getpwuid` and require it to be listed in `/etc/shells`. Run exactly `[shell,"-l","-c","/usr/bin/printenv PATH"]` with a 10 s timeout.
- The output must be one line of absolute directories separated by colons. If it isn't, fall back to the static PATH.
- `merge(captured:, loginPath:, home:)`:
  - PATH = de-duplicated `<home>/.local/bin` + captured or login PATH + static PATH;
  - captured keys win;
  - add `TERMINFO_DIRS` pointing at the bundled terminfo dir (A2b) unless the captured env already sets it;
  - the result is what B2 writes to `managed.json` `env` (marker mode 0600);
  - drop `SSH_AUTH_SOCK`, `TMUX*`, `TERM_SESSION_ID`, `__CF*`, `XPC_*` and `LEO_CONFIG`.
- Test first, `LeoDaemonEnvironmentTests`: argv, validation, fallback, and the merge table.

**A13 · Claude onboarding · min leo: none · implement**
- Look for `claude` in order: `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, then the login PATH.
- Install with `curl -fsSL https://claude.ai/install.sh | bash && "$HOME/.local/bin/claude"`. Check that URL against Anthropic's docs at implementation time.
- The command runs through `LeoCommandLauncher.openWindow`. Leo has no tabs (D-098), so it opens a window.
- Show it once, after the first run reaches a live local daemon, if `claude` is missing. Leo ▸ "Set Up Claude…" stays available afterwards.
- Test first, `LeoClaudeOnboardingTests`: the lookup order, the exact command, and the one-time flag.

**A14 · `bin/leo` refresh and "Install leo command" · min leo: none (≥0.56.0 once `self_path` is the marker target) · implement**
- `LeoSelfLink`: on each launch, when the app is in /Applications and the helper exists, `replaceSymlinkAtomically(~/.leo/app/bin/leo → <bundle>/Contents/Helpers/leo)` (the marker's `self_path` is this link path, never the resolved target). It does nothing if the link is already correct.
- `LeoCommandInstaller.plan` returns `.create`, `.alreadyInstalled`, `.confirmReplace(backup: leo.pre-leoapp)` or `.refuse(.directory)`. It never deletes, creates `~/.local/bin` (0755) if needed, and shows a PATH hint when `~/.local/bin` isn't on PATH. The menu item is Leo ▸ "Install ‘leo’ Command…".
- Test first, `LeoSelfLinkTests` and `LeoCommandInstallerTests`: plan tables (absent, our symlink, foreign symlink, file, dir) and exact op logs.

**Phase A done:** the signed bundle contains the helpers (via the dev override), every unit is green, and `$ALIVE` passes. Nothing registers yet and nothing writes `managed.json`.

## Phase B — needs the new leo surfaces

**B1 · First-run decision table · min leo: ≥0.56.0 · implement.hard**
- Pure `decide(LeoFirstRunInputs) -> LeoFirstRunAction`.
- Inputs:
  - location;
  - probe: live(version) / absent / unresponsive;
  - marker: absent / ours / foreign / invalid;
  - existing install, detected in this order (the first match wins):
    1. live: `hello` on `~/.leo/state/leo.sock` is authoritative, so offer takeover;
    2. installed but not running: `~/Library/LaunchAgents/com.blackpaw.leo.plist` exists, so offer takeover (handover supports a stopped CLI daemon, skipping drain and bootout and moving the plist aside);
    3. binary only (`~/.local/bin/leo`, `/opt/homebrew/bin/leo`, `/usr/local/bin/leo`): no takeover, just start the managed daemon;
    4. none;
  - agent status: notRegistered / enabled / requiresApproval / notFound;
  - takeover answer;
  - build kind.
- Actions:
  - `.blockMove`;
  - `.useLive(offerTakeover:)` (live daemon, or installed-but-stopped via the plist);
  - `.install`;
  - `.ensureManaged(refreshLink:, register:)`;
  - `.awaitApproval`;
  - `.repair(reason)`;
  - `.recoverOrphanRegistration`: marker absent but SMAppService reports the agent registered. Call `unregister()` (crash-between-steps recovery after Release to CLI), then re-decide;
  - `.observeOnly`: a foreign marker, or Debug without `LEO_MANAGED_DEBUG`.
- Test first, `LeoFirstRunTests`: a parameterized table with one row per transition, all written before the code. Required rows include:
  - live hello → `.useLive(offerTakeover: true)`;
  - plist present, daemon stopped → `.useLive(offerTakeover: true)`;
  - binary only → `.install` with no takeover offer;
  - marker absent + agent registered (`enabled` or `requiresApproval`) → `.recoverOrphanRegistration`;
  - a `no_launchd_job` takeover result → `.useLive(offerTakeover: false)` plus the "how to stop it" note.

**B2 · Setup executor · min leo: ≥0.56.0 · implement.hard**
- Steps, in order:
  1. Copy tmux to `~/.leo/app/tmux/<ver>/tmux`, where `<ver>` is exactly the bundled `tmux -V` output minus the `tmux ` prefix, only if that path is absent (temp file + rename, 0755, sha check). Never overwrite or delete a version dir while a `-L leo` server could use it. The marker's `tmux_path` names the version new servers start on.
  2. Refresh `~/.leo/app/bin/leo` (A14).
  3. Write the marker (mode 0600), with `self_path`, `tmux_path` and `env` from A12 (including `TERMINFO_DIRS`).
  4. `register()`.
  5. Wait up to 20 s for `hello` on `leo.sock` (injected clock).
- If the status is `.requiresApproval`, show "Allow Leo in Login Items" with `openLoginItemsSettings()` and check again on `didBecomeActive`.
- If step 4 or 5 fails, run `unregister()` and remove the marker (keep the tmux copy), then show the error panel.
- Test first, `LeoManagedSetupTests`: the happy-path op log, the exact rollback log for each failing step, version dirs never overwritten, and the approval-pending path.

**B3 · Takeover · min leo: ≥0.57.0 · implement.hard**
- Offer once, and remember the answer.
- Run `[<bundled>,"service","handover","--to-app","--label",<LeoDaemonLabel>,"--json"]` always by the bundled `Contents/Helpers/leo` path. The drain default is 10 minutes, tunable with `--drain-timeout` and `--force`; run it with no app-side deadline shorter than that.
- Decode `{ok, step, error, message, previous_label, env, plist_backup, rolled_back, managed_stopped, warnings[]}`; the exit code is 0 iff `ok`. Malformed output or a non-zero exit counts as failure: keep the CLI daemon and write nothing.
- An installed-but-stopped CLI daemon (plist present, job not loaded) is supported: leo skips drain and bootout and moves the plist aside.
- Preflight error `no_launchd_job` (the daemon wasn't started via launchd) means automatic takeover isn't possible: keep using the live daemon, write nothing, and show a note on how to stop it.
- On `ok`, run B2 with the captured env. If B2 then fails, run `--to-cli` (confirm with leo that `--to-cli` is valid after a failed `--to-app`; see "Contract questions").
- Test first, `LeoHandoverTests`: argv, decode fixtures, and the rollback sequence.

**B4 · Release to CLI · min leo: ≥0.57.0 · implement.hard**
- Ask for confirmation first.
- If `~/.local/bin/leo` is our symlink and `leo.pre-leoapp` exists, restore the backup first. Otherwise the restored CLI plist could run the app's binary.
- Then run `[<bundled>,"service","handover","--to-cli","--json"]` FIRST. leo drains, boots out the app's label and restores the CLI daemon.
- Only on `ok:true`, call `SMAppService.unregister()` and clear the takeover answer.
- `ok:false` + `managed_stopped:true`: leo rolled back, so the app re-registers its agent. `ok:false` + `managed_stopped:false`: nothing changed.
- On launch, if the marker is absent but the agent is still registered with SMAppService, `unregister()` (recovery from a crash between the two steps; add this row to B1/B9).
- Test first, `LeoReleaseToCLITests`: argv and op order, the restore branch, and failure leaving state intact.

**B5 · Startup integration · min leo: ≥0.56.0 · implement.hard**
- In `LeoRuntime.start()`: location → probe → decide → execute, all before `hostSelection.start`.
- The "Start daemon" buttons in `LeoSidebarView` (L277 and L292) become the action-specific button: Set Up / Allow in Login Items / Move to Applications / Start CLI Daemon.
- Test first, `LeoRuntimeManagedStartTests`:
  - a fresh install runs `.install` once;
  - a live CLI daemon shows the offer and writes nothing;
  - a Debug build makes no `LeoLaunchAgentService` calls.

  `LeoRuntimeConnectionTests` stay green, and `$ALIVE` (isolated) passes.

**B6 · Restart after a Sparkle update · min leo: ≥0.57.0 (managed restart routing) · implement**
- On the first hello after launch, check `shouldRestart(managedByUs:, bundled:, running:, alreadyTriedPair:)`. `bundled` is the output of the bundled `Helpers/leo version` with the `leo ` prefix stripped; `running` is `hello.version` (bare semver). The check is plain string inequality, not an ordering: any difference means restart. If it says restart:
  1. Copy the new tmux version alongside the old one (`~/.leo/app/tmux/<ver>/tmux`; never overwrite or delete a version dir a `-L leo` server could be using), and update the marker's `tmux_path`.
  2. Run the bundled `["service","restart","--graceful"]` (non-interactive drain; never bare `restart`, which may prompt). In managed mode it targets the app's label.
- Restart at most once per launch for each version pair. If the versions still differ afterwards, show a banner pointing at `leo doctor`.
- Test first, `LeoPostUpdateRestartTests`: the policy table, argv, and no restart loop.

**B7 · Pair a Device · min leo: ≥0.57.0 · implement**
- Run `["pair","--json"]` and decode the flat fields `daemon_id`, `name`, `urls`, `pairing_code`, `warnings[]`, `expires_at` (RFC3339) and `qr_payload`.
- Generate the QR with `CIQRCodeGenerator` (correction level M) from `qr_payload`, encoded verbatim. Refresh at `expires_at`. Show the code, the warnings and a Copy button.
- With web off, pair exits non-zero with `{"error":"web_disabled"}`. Offer to enable it: run `["web","enable","--json"]` (optionally `--bind addr`, `--allow-host h`), which returns `{ok,changed,restarted,web:{enabled,bind,port}}`. When `restarted` is true, wait for the daemon to come back, then retry pairing.
- Test first, `LeoPairDeviceTests`: decode fixtures, the exact argv sequence on the `web_disabled` path, and a QR string that round-trips through `parse`. The sheet layout is a TDD exception.

**B8 · Bump PR and release workflows · min leo: ≥0.56.0 (release asset and dispatch) · implement**
- `leo-bump.yml` runs on `repository_dispatch` `[leo-release]`:
  - the payload is passed through `env:`, never `${{ }}` in `run:`;
  - the dispatch comes from stable `vX.Y.Z` tags only (prereleases contain `-` and send nothing); the payload `version` has no `v`;
  - `bump-leo.sh` validates the semver and the 64-hex sha256, downloads and verifies the asset, and rewrites the pin;
  - it opens a PR from `leo-bump/<version>` with the App token, and does nothing if that PR already exists.
- `leo-bump-release.yml` runs on a bump commit to main that touches `LEO_VERSION`. It computes the next patch `leo-v` tag and pushes it with the App token (Q2).
- Test first, `tests/test_bump-leo.sh`: rejects `1.0.0;rm -rf`, a short sha and a sha mismatch, and writes the exact pin. Run `actionlint` if it's available.

**B9 · Repair and blocking states · min leo: ≥0.56.0 · implement**
- Repair an invalid marker by rewriting it from the current bundle and registering again.
- Launch-time recovery: marker absent but SMAppService registered → `unregister()` (the `.recoverOrphanRegistration` row in B1), covering a crash between Release to CLI's handover and its `unregister()`.
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
   - (d) A Sparkle update vN→vN+1 from a local appcast: a graceful restart, `hello.version` equals the bundled version, and the old `~/.leo/app/tmux/<ver>` dir is kept.
   - (e) Moving the app out of /Applications triggers the block.

   Never run this on Evan's account without his go.

## Contract questions (leo agent) — C1–C15 answered
- **C1 Paths with spaces: resolved.** Space-free root `~/.leo/app/{bin,tmux}` (D11).
- **C2 Release asset: resolved.** URL, tag form and sha256 are in A1; the only leftover is confirming the archive root layout on the first real release.
- **C3 Managed plist: resolved.** A4.
- **C4 Logs: resolved.** `~/.leo/state/service.log` (A11).
- **C5 Env: resolved.** Marker `env`, mode 0600 (D5, A12).
- **C6 Handover output: resolved.** B3.
- **C7 `--to-cli` order: resolved.** B4 (handover first, `unregister()` only on `ok:true`). Leftover: is `--to-cli` valid after a failed `--to-app`? (B3 treats `rolled_back` as already restored and calls `--to-cli` only if B2 fails after an `ok` handover.)
- **C8 tmux: resolved.** ≥3.2, `tmux -V` minus the prefix names the version dir; ship the `tmux-256color` terminfo (A2b). Leftover: parsing of `next-3.x` builds (we never ship one, so low priority).
- **C9 Paths in the marker: resolved.** Absolute, `self_path` unresolved (A6).
- **C10 Restart: resolved.** Always `--graceful` (A11, B6). Leftover: exit codes when the daemon is down.
- **C11 Pairing: resolved.** B7.
- **C12 Update guard: resolved.** `leo update` refuses inside `*.app/Contents/`.
- **C13 Detecting a CLI install: resolved.** B1 detection order.
- **C14 Version output: resolved.** `leo version` → `leo <semver>`.
- **C15 Hello version: resolved.** Bare semver; B6 compares as plain strings.
- **New leftover:** the handover `--label <LeoDaemonLabel>` flag in B3 is ours; the round 2 answers don't name it, so confirm the flag spelling with leo before B3 starts.

## Open questions (Evan / orchestrator)
- **Q1** A GitHub App or PAT secret for bump PRs and tags.
- **Q2** Should a merged bump auto-tag a release?
- **Q3** A macOS VM for the live Phase B checks.
- **Q4** Sign-off on D1 (approved, see below), and on C1 if paths change.

## Contract answers from leo agent (2026-10-20)
- tmux: the app builds and pins it; version ≥3.2 (3.6a matches today). Install at `~/.leo/app/tmux/<ver>/tmux` (round 2 moved the root from `~/Library/Application Support/Leo/`), where `<ver>` is exactly the `tmux -V` output minus the "tmux " prefix. Never overwrite or delete a version dir while a `-L leo` server could use it. `managed.json` `tmux_path` is the version new servers should start on.
- Release to CLI: the app calls `leo service handover --to-cli --json` FIRST. leo drains, boots out the app's label and restores the CLI daemon. Only on `ok:true` does the app call `SMAppService.unregister()`. `ok:false` + `managed_stopped:true` means leo rolled back, so the app re-registers its agent. `ok:false` + `managed_stopped:false` means no change. On launch, if the marker is absent but SMAppService is registered, unregister (crash-between-steps recovery).
- `leo pair --json`: flat fields `daemon_id`, `name`, `urls`, `pairing_code`, plus `warnings[]`, `expires_at` (RFC3339) and `qr_payload` (encode verbatim in the QR; refresh at `expires_at`). Web off → `{"error":"web_disabled"}` with a non-zero exit.
- `leo web enable [--bind addr] [--allow-host h]... --json` → `{ok, changed, restarted, web:{enabled,bind,port}}`.
- `leo service handover --to-app` preflight error `no_launchd_job` (daemon not started via launchd): the app treats it as "can't take over automatically", keeps using the live daemon and shows a note on how to stop it.
- Requested of leo (adopted in round 2): all `--json` commands print only JSON on stdout (logs to stderr); failures are JSON with a stable `error` code (+ optional `message`) and a non-zero exit.
- Orchestrator decision: D1 (`Contents/Helpers/leo` instead of `Contents/MacOS/leo`) is approved.

## Contract answers from leo agent, round 2 (2026-10-20)

Ship targets: marker, self_path, daemon lock, update refusal, tmux resolution, darwin_universal asset → leo v0.56.0. handover, pair --json, web enable, managed service routing → leo v0.57.0. Phase A steps that read the marker need ≥0.56.0; B3/B4/B7 need ≥0.57.0.

- **Layout change (supersedes spec paths and the earlier tmux bullet's root):** no spaces. `~/.leo/app/bin/leo` → `Leo.app/Contents/Helpers/leo`; tmux copies at `~/.leo/app/tmux/<ver>/tmux`. Nothing under ~/Library/Application Support/Leo/. managed.json self_path/tmux_path use these.
- **A1 accepted:** Contents/Helpers/leo, Contents/Helpers/tmux.
- **A2 accepted:** managed.json optional `"env": {string:string}`, applied by the daemon at startup on top of its environment. The marker file must NOT be group/world-writable (write 0600) or leo ignores it.
- **Release asset:** tags `vX.Y.Z` (stable only; prereleases contain '-' and send no dispatch). Public. URL `https://github.com/blackpaw-studio/leo/releases/download/v<ver>/leo_<ver>_darwin_universal.tar.gz`. Dispatch payload `version` has no `v`. `sha256` = tarball hash (as in checksums.txt). Binary `leo` at archive root (confirm on first real release).
- **Managed LaunchAgent plist:** `BundleProgram` = `Contents/Helpers/leo`, `ProgramArguments` = [leo, "service", "--supervised"], no --config; WorkingDirectory unset or `/`. `KeepAlive` true, `RunAtLoad` true. No ProcessType; default ThrottleInterval. StandardOut/ErrorPath unset or /dev/null.
- **Logs:** daemon writes `~/.leo/state/service.log` (rotated in-process). Menu bar "Logs" opens that.
- **Handover JSON** (both directions): {ok, step, error, message, previous_label, env, plist_backup, rolled_back, managed_stopped, warnings[]}; exit 0 iff ok. Drain default 10m (`--drain-timeout`, `--force`). ALWAYS invoke with the bundled `Contents/Helpers/leo` by explicit path. Installed-but-stopped CLI daemon (plist present, job not loaded) is supported (skips drain/bootout, moves plist aside). Live daemon with no launchd job → error `no_launchd_job`.
- **self_path** persisted exactly as given, never symlink-resolved.
- **Restart:** always `leo service restart --graceful` (non-interactive drain) or `--no-graceful`; never bare `restart` (may prompt). In managed mode it targets the app's label.
- **tmux terminfo:** leo doesn't set default-terminal. Ship tmux-256color terminfo in the bundle (Ghostty already ships a terminfo dir — reuse/extend it) and put `TERMINFO_DIRS` in managed.json `env`.
- **leo update** refuses whenever its executable resolves inside `*.app/Contents/`, even without a marker.
- **Detecting an existing install:** (1) live: `hello` on `~/.leo/state/leo.sock` is authoritative → takeover offer; (2) installed not running: `~/Library/LaunchAgents/com.blackpaw.leo.plist` exists → takeover offer; (3) binary only (`~/.local/bin/leo`, `/opt/homebrew/bin/leo`, `/usr/local/bin/leo`) → no takeover, just start the managed daemon.
- **Versions:** `leo version` prints `leo <semver>` (dev builds differ); `hello.version` is bare semver. Compare bundled `Helpers/leo version` (strip `leo `) to hello.version as plain strings; any difference → `restart --graceful`. (Plain string inequality, not ordering — LeoDaemonVersion compare is only needed for display/iOS.)
- **JSON rule adopted** for every `--json` command: stdout only JSON, logs on stderr, failures `{error:<stable code>, message?}` + non-zero exit.

## Contract answers from leo agent, round 3 (2026-10-20)
- `handover --to-app` label flag: `--label <l>` (e.g. `leo service handover --to-app --label studio.blackpaw.leo.daemon --json`).
- Failed `--to-app`: leo rolls back itself (plist restored, com.blackpaw.leo re-bootstrapped) → `ok:false, step, rolled_back:true`. Rollback failure → `ok:false, rolled_back:false`: show error + step and point the user to `leo service start --daemon`. Never call `--to-cli` to recover a failed `--to-app` (no marker yet; its preflight fails). B3's single `--to-cli` use (own registration fails after `ok:true`) is correct.
- `leo service restart --json` (v0.57.0): daemon down, job loaded → exit 0 `{ok:true, drained:false, restarted:true}`; job not loaded/registered → exit 1 `{ok:false, error:"not_registered", message}`; drain timeout without `--force` → exit 1 `{ok:false, error:"drain_timeout"}`.

## Phase A outcome notes (2026-10-20)
- Bundled tmux is pinned to **3.6b** (3.7c+ enables macOS grid assertions that need jemalloc; tmux#5385). Existing CLI installs run Homebrew tmux (3.6a today). **B3 takeover must handle the version gap:** before handover, if a `-L leo` server is running with version V and `~/.leo/app/tmux/V/tmux` is absent, copy the running server's binary (resolved from `tmux -L leo display -p '#{version}'` + the CLI's tmux path) into `~/.leo/app/tmux/V/tmux` so leo's version guard keeps attach working until the next server start. Test this in B3.
- `LEO_VERSION` sha256 stays empty until leo v0.56.0 ships; `feat/bundled-daemon-pipeline` must not reach main before the pin is bumped (CI `fetch-leo.sh` fails otherwise).
- Local ad-hoc builds with hardened runtime fail library validation against ad-hoc Sparkle; local checks sign the outer app without runtime (docs/leo/ci.md). CI Developer ID signing unaffected.
- `$ALIVE` does not isolate cfprefsd (CFFIXED_USER_HOME doesn't redirect it): export/import the debug/release defaults domains around runs instead of deleting.

## Security note from leo agent (2026-10-20)
- `handover --to-app --json` `env` is the old CLI plist's full EnvironmentVariables and may contain secrets (API tokens). managed.json must be 0600 from creation (temp file created 0600, not chmod after rename). Never log handover stdout (incl. `--dry-run`) or the marker `env` to os_log, files, crash breadcrumbs, or error alerts. Review B2/B3 for this explicitly.

## Contract answers from leo agent, round 4 (2026-10-20; leo PRs #282 A, #284 B, #283 release, #285 C — unmerged)
- Successful `--to-cli` → `ok:true, managed_stopped:true` (app job booted out → app unregisters). `ok:false, managed_stopped:true` → re-register.
- Every `--json` failure (incl. cobra arg/flag errors) prints `{"error": code, "message"?}`. Codes so far: `invalid_args`, `not_permitted`, `no_launchd_job`, `not_registered`, `drain_timeout`, `web_disabled` (bare, no message), plus handover step failures carrying `step`.
- `pair --json` `warnings` is always an array, never null.
- Daemon `/health` over the socket includes the bound web address; use it to show the current bind before/after `web enable` (B7 confirmation copy).
- Full command table + JSON shapes: leo repo `docs/configuration/managed-install.md` (on the leo PR branch).

## leo status (2026-10-20 20:30 EDT)
- All leo-side PRs merged to leo main (#282–#285). Everything (marker, lock, self_path, update refusal, tmux resolution, service routing, handover, pair/web/restart --json, universal asset + `leo-release` dispatch) ships together in **v0.56.0** — the earlier ≥0.57.0 annotations now mean ≥0.56.0. Not yet tagged (awaiting Evan).
- Dev builds: `make build` in /Users/evan/.leo/agents/leo → `bin/leo` for `LEO_BINARY`.
- leo's `LEOTERM_DISPATCH_TOKEN` is set; the first stable leo release fires `leo-release` at leoterm even before B8's receiving workflow exists (harmless no-op until then).

## leo v0.56.0 tagged (2026-10-20 21:27 EDT) + round 5 answers
- v0.56.0 contains every surface. Pin bump pending the release build's darwin_universal asset + checksums.txt.
- `/health data.version` == hello.version == `leo version` minus "leo " — same build-time string; release builds bare semver (no v).
- leo runs exactly `launchctl bootout gui/<uid>/<label>` and NEVER bootstraps/registers the app's job, even on rollback. `managed_stopped:true` → app must restore it: `unregister()` then `register()`, then verify hello.
- `restart` → `not_registered` + live hello = daemon running outside the app's job. `/health` includes `pid`. Recovery (follow-up step B10): "A leo daemon (pid N) is running outside Leo.app" + [Stop it] → confirm → SIGTERM pid (clean shutdown; agent tmux sessions survive) → wait for lock/socket release (bounded) → register/kickstart app job. No `doctor --json` yet (leo will add on request).
