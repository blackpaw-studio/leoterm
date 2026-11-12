# Plan: Drawer Terminal (built-in Terminal tab per agent)

**Spec:** `docs/superpowers/specs/2026-11-12-drawer-terminal.md`. It wins where this plan disagrees. **Base:** `2026-11-12-agent-bottom-pane.md` and its plan. **Platform: Mac only.** iOS has no local shell; the read-only mirror is an iOS backlog idea. **No Zig changes.**

**Commands**
- LeoKit: `swift test --package-path Packages/LeoKit --filter <Suite>`
- App build, from `macos/`, as a background job: `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc`
- App tests: `xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>`. New tests go in `macos/Tests/Leo/AgentPane/`.

Each step is its own commit and starts from a failing Swift Testing test unless it says "TDD exception". Defaults-backed tests use an injected suite, never `.standard`, because concurrent runs share the debug defaults.

## Steps

**1. Daemon feature `agent_shell`.**
- Files: `Packages/LeoKit/Sources/LeoKit/Observe/LeoDaemonFeatures.swift` (`case agentShell = "agent_shell"`).
- Failing test: `LeoDaemonFeaturesTests` decodes `agent_shell`.
- Parallel: yes.

**2. Built-in tab kind.**
- Files: `AgentPane/LeoAgentPaneTabs.swift`.
  - `LeoAgentPaneTab` gains `kind: .plugin(paneID:) | .terminal`. `paneID` moves into the kind.
  - `make(from:showsTerminal:)` puts `{id:"leo.terminal", title:"Terminal", sfSymbol:"terminal"}` first, then the plugin tabs as today. It drops any plugin whose id is `leo.terminal`.
- Failing test: `LeoAgentPaneTabsTests` covers terminal first, the toggle off leaving plugins only, and the id collision.
- Parallel: yes.

**3. Mounts and visibility.**
- Files: `AgentPane/LeoAgentPaneMounts.swift` and `LeoAgentPaneModel.swift`.
  - Mounts become `summaries: [LeoAgentPaneMount]` and `body: LeoAgentPaneMount?`, where the mount is `.plugin(LeoPluginSlotKey) | .terminal(LeoAgentIdentity)`.
  - `openSlots` and the visibility reporter only see `.plugin`.
  - `isShown` stays `agent != nil && !tabs.isEmpty`. It now holds with only the Terminal tab.
- Failing test: `LeoAgentPaneMountsTests` covers a terminal-only pane (shown with an agent, hidden without one) and a terminal body while expanded on `leo.terminal`. Existing cases are updated to the new mount type.
- Depends on 2.

**4. Summary path.**
- Files: new `AgentPane/LeoDrawerPath.swift`.
  - `summary(pwd: URL-or-path?, workspace: String?, home: String?) -> String` takes the OSC 7 pwd if known, else the workspace.
  - It turns a `file://host/path` into a path, replaces `home` with `~`, then applies the `shortenPath` rule from `plugins/status/src/format.ts:38`.
- Failing test: `LeoDrawerPathTests` covers `~/.leo/agents/leoterm` → `~/.l/a/leoterm`, `/` and single components, the pwd beating the workspace, and a remote path with no home substitution.
- Parallel: yes.

**5. Launch choice.**
- Files: new `AgentPane/LeoDrawerShellLaunch.swift`. It is pure:
  ```
  choose(identity, features, isConnected, isDirectory, home, remoteCommand)
    -> .local(workingDirectory) | .remote(command) | .unavailable(message)
  ```
- Local:
  - It reuses `LeoAttachCommand.workingDirectory(identity:isDirectory:)` (`Attach/LeoAttachCommand.swift:94`), so it tries the workspace, then `repo`.
  - It falls back to `home`.
- Remote without `agent_shell`: "Terminals for agents on <machine> need a newer Leo on that machine."
- Remote with `agent_shell`: `LeoSSHCommand.shellCommand(agent:)` in `Hosts/LeoSSHCommand.swift`, built like `attachShellCommand(agent:)` at :176. The result is `env -u TMUX -u TMUX_PANE ssh -t [-i][-p] <target> '<remote leo> agent shell -- <name>'`. It refuses names containing NUL or newlines (see Q1).
- Failing tests:
  - `LeoDrawerShellLaunchTests` covers the workspace, the gone-workspace → repo → home chain, remote with and without the feature, and a disconnected host (Q2).
  - `LeoSSHCommandTests` covers the shell command quoting.
- Depends on 1.

**6. Per-window shell pool.**
- Files: new `AgentPane/LeoDrawerShellPool.swift`, a `@MainActor final class LeoDrawerShellPool<Surface: AnyObject>`.
  - It takes an injected `make: (LeoDrawerShellLaunch) throws -> Surface` and `close: (Surface) -> Void`.
  - API:
    - `state(for: LeoAgentIdentity) -> .notStarted | .running(Surface) | .exited(status: Int?) | .unavailable(String) | .failed(String)`
    - `open(_:launch:)`: lazy, idempotent while running.
    - `markExited(_:status:)`, which closes the surface.
    - `restart(_:launch:)`.
    - `close(_:)`, `closeAll()`.
    - `retain(on host:, keeping: (name, movedTo) -> Bool)`.
  - It publishes changes through a Combine subject.
- Failing test: `LeoDrawerShellPoolTests` with a fake factory:
  - nothing is made before `open`;
  - a second `open` reuses the shell;
  - switching keys keeps both shells;
  - `close`, a moved or unlisted agent under `retain`, and `closeAll` each call `close` exactly once;
  - an exit followed by `restart` makes a new surface;
  - `.unavailable` makes nothing;
  - a factory throw gives `.failed`.
- Parallel: yes.

**7. "Show Terminal tab" setting.**
- Files: new `AgentPane/LeoBuiltInPaneSettings.swift`. It is an `ObservableObject` backed by an injected `UserDefaults` that publishes on its own writes. There is no defaults observer, and no `queue: .main` observer.
  - It is app-wide, owned by the runtime and injected into every `LeoAgentPaneModel` and into `Settings/Plugins/LeoPluginsSettingsModel.swift` and `LeoPluginsSettingsView.swift`.
  - The view gets a "Built-in" row with a "Show Terminal tab" toggle (default on) above the plugin rows, next to their "Show agent pane" toggles.
- Failing test: `LeoPluginsSettingsModelTests` checks the toggle defaults to on, persists, and fires a change.
- Parallel: yes.

**8. Pane model without plugins, with the agent's context.**
- Files:
  - `LeoAgentPaneModel.swift`: `surfaces` becomes optional. Tabs come from the plugins plus `settings`. The `agent` becomes `LeoAgentPaneAgent {ref: LeoPluginAgentRef, identity: LeoAgentIdentity}`.
  - `Sidebar/LeoWindowSession.swift:129`: the model is always built, not only when there is a plugin system. The session also owns `drawerShells`.
  - `Sidebar/LeoSidebarSplit.swift:243`: the hand-off carries host, workspace and repo, and still sends nil for moved rows.
  - `Sidebar/LeoSplitViewRepresentable.swift:158`, where `scheduleAgent` changes type.
- Failing test: a new `LeoAgentPaneModelTests` covers no plugin system with an agent (shown, one tab) and the toggle off with no plugins (hidden).
- Depends on 2, 3 and 7.

**9. Ghostty adapters (glue).**
- Files: new `AgentPane/LeoDrawerSurfaces.swift`.
- Production factory:
  - It builds `Ghostty.SurfaceView(app, baseConfig:)` with a fresh `Ghostty.SurfaceConfiguration()`, the same base `GhosttyAttachContentHost.configuration` (:927) uses for a plain shell. That gives the user's config and their login shell.
  - Local: it sets `workingDirectory`.
  - Remote: it sets `command` and clears `environmentVariables`, as `attachConfiguration` does.
  - The app comes from the injected `ghostty.app`. The factory throws `surfaceUnavailable` like `makeSurface` at :629.
- Exit observer:
  - It listens for the first of: `childExitedMessage` (the windowed exit code), `.leoWindowlessChildExited` (unmounted), or `Ghostty.Notification.ghosttyCloseSurface` with `process_alive == false`.
  - All three are filtered to the pool's own surfaces, and the observer calls `pool.markExited`.
  - `BaseTerminalController.ghosttyDidCloseSurface` (:663) already ignores surfaces outside its tree.
- Occlusion:
  - Extract `LeoLiveSurfaces.stopDrawing` (`Attach/LeoLiveSurfaces.swift:~330`) into a shared `LeoSurfaceDrawing.set(_:visible:)`.
  - The drawer calls it on mount and unmount and on the window's occlusion changes, using `LeoWindowSession` `windowIsOccluded`. Drawer surfaces are not in `surfaceTree`, so the occlusion sync at `BaseTerminalController.swift:1304` never reaches them.
- Failing test: `LeoDrawerOcclusionTests` on a pure `isVisible(isMounted:, windowVisible:, expanded:, selectedIsTerminal:)`. The rest is a TDD exception (AppKit and libghostty glue) and is verified in E2E.
- Depends on 6.

**10. Views and focus.**
- Files:
  - new `AgentPane/LeoDrawerTerminalViewController.swift`. Its body is the bare `SurfaceView`, or the exit state ("Shell exited (status N)" plus a **Restart** button), or the unavailable or failed message.
  - `LeoAgentPaneTabView.swift`, whose summary becomes an `NSView` so it can show a native `Terminal · <dir>` label fed by the surface's `pwd` publisher.
  - `LeoAgentPaneViewController.swift`, which mounts `.terminal`. Mounting it calls `pool.open`; this is the lazy start.
  - A pure `AgentPane/LeoAgentPaneFocus.swift`, `transition(from:to:drawerHasFocus:) -> .focusDrawer | .focusMain | .none`. The app side calls `makeFirstResponder` on the drawer surface, or on the controller's `focusedSurface` for the main view.
- Failing test: `LeoAgentPaneFocusTests` checks that expanding onto Terminal focuses the drawer, collapsing with drawer focus goes to the main view, and collapsing without it does nothing.
- Verify: launch check (exit 124 means alive) and Peekaboo screenshots with `--capture-engine cg`.
- Depends on 3, 8 and 9.

**11. Teardown wiring.**
- Files: `LeoRuntime.swift`.
  - `prunePanes(for:)` at :572 also calls `session.drawerShells.retain(on: host) { listed && movedTo == nil }`. Unlike panes, the row on screen is not spared.
  - `teardownWindow` at :762 needs no change.
- Files: `Sidebar/LeoWindowSession.swift`, `windowWillClose` at :461, which calls `drawerShells.closeAll()`.
- Files: `machinesChanged`, where a removed machine closes its hosts' shells.
- Failing test: a pure `LeoDrawerShellRetention.keep(row:)` in `LeoDrawerShellPoolTests` covering moved, unlisted and listed agents. The wiring itself is glue.
- Depends on 6.

**12. Settings and app launch check.**
- Full `GhosttyTests/Leo*` plus a LeoKit run at the gate (load-aware).
- `NSSplitView` holding priorities are unchanged and stay in 250–260. `LeoAgentPaneSplitTests` stays green.

## E2E (isolated debug app + scratch daemon)

Follow the `isolated-leo-daemon-recipe` memory: `-c`, a scratch cwd, `TMUX_TMPDIR` and a short socket path. Use a second debug bundle id and `stub-claude` scratch agents. Filter to a scratch agent and screenshot focus before any keystroke (debug-app keystroke safety).
1. Open the Terminal tab of local scratch agent A, type `pwd` and confirm it prints A's workspace. Also test a workspace that has been deleted: it should fall back to `repo`, then home.
2. Run `seq 1 500` in A, switch to B and back, and confirm the scrollback is intact. Do the same for a collapse and expand, and for switching to the Status tab and back.
3. Run `exit 3`: the body shows "Shell exited (status 3)". Click Restart and confirm `pwd` is the workspace again.
4. `leo agent remove A`, then `pgrep -f` the shell's PID (recorded via `echo $$`) and confirm it is gone. Do the same with `leo agent move A` to another host, and with closing the window.
5. Open two windows on agent A and confirm each has its own `$$`.
6. Rendering:
   - Run `while :; do date; sleep 0.05; done` in the drawer.
   - Sample the app's `%CPU` expanded, then collapsed or switched.
   - It must drop to idle. If it doesn't, the step-9 occlusion isn't taking effect: fix before shipping.
7. Remote:
   - A host whose daemon lacks `agent_shell` shows the "newer Leo" message, and `ps` confirms no ssh was spawned.
   - Once the daemon ships, a real host gives `pwd` equal to the remote workspace.
8. Memory: note the app's RSS (`ps -o rss= -p <pid>`), open 10 agents' terminals, and note it again. Report both numbers.
9. Screenshots, collapsed and expanded, light and dark. Inspect each before posting.

## Risks

- **R1, focus and menu routing.**
  - With the drawer surface as first responder, check ⌘W, ⌘D, ⌘T, the window title and `isTerminalFocused` (`LeoWindowSession`), because each may treat a `SurfaceView` that is not in `surfaceTree` as the focused surface.
  - Splits are already ignored outside the tree (`ghosttyDidNewSplit` guard). The title and close paths need a check in step 10.
- **R2, exit code gaps.**
  - `showChildExited` only sets the message when `timetime_ms > 0`.
  - A user config with `wait-after-command` suppresses the close.
  - The observer takes whichever signal comes first and shows "Shell exited" with no status when the code is unknown.
- **R3, lingering references.** A Combine `pwd` sink or notification token holding the `SurfaceView` would keep the pty, and the shell, alive. E2E step 4 is the guard, and sinks hold the surface weakly.
- **R4, `.leoWindowlessChildExited`.** It is posted for every windowless surface. Check that `GhosttyAttachContentHost` and `LeoLiveSurfaces` ignore surfaces they don't own.
- **R5, mount type change.** Changing the type ripples through the existing pane tests and the `LeoPluginVisibilityReporter` call sites.

## Open questions and decisions the spec left open

- **Q1, remote command form.** The spec writes `leo --host <machine> agent shell -- <name>`, but the app reaches remote agents over `ssh -t <target> '<remote leo> agent attach -- <name>'` (`LeoRuntime.swift:266`, `LeoSSHCommand.swift:176`). **Recommend** the ssh form with the remote leo's `agent shell`. It matches attach, and the feature check uses that remote daemon's hello. The daemon command needs no change either way.
- **Q2, disconnected remote host.** Its features read as `.none`, so it would wrongly show "needs a newer Leo". **Recommend** showing "<machine> isn't connected." with no spawn.
- **Q3, what "opens" a terminal.** Showing the Terminal body starts the shell. A window that was left expanded on the Terminal tab therefore spawns a shell for each agent the user selects. **Recommend** accepting this, since it is what the user sees. The alternative is to start only on an explicit tab click.
- **Q4, dispatch rows.** No shell; the pane gets no agent, as today. Confirm.
- **Q5, ⌘W while the drawer has focus.** **Recommend** that it collapses the pane, not closes the window's main surface, once R1 is checked.
- **Q6, removal while on screen.** The shell closes even when the removed row is the one on screen, which differs from editor panes (`pruneAgents` spares the active key). **Recommend** closing it, because the spec says it closes on removal.

## Orchestrator decisions (2026-11-12)

- **Q1:** use the ssh form, `ssh -t <target> '<remote leo> agent shell -- <name>'`. It is the same transport `agent attach` uses, so it satisfies the spec's "`leo --host` … same transport".
- **Q2:** a disconnected remote host shows "<machine> isn't connected." and nothing is spawned.
- **Q3:** accept. The shell starts whenever the Terminal body is shown, including when the user selects an agent while the drawer is left expanded on Terminal.
- **Q4:** confirmed. Dispatch rows get no agent and no shell.
- **Q5:** ⌘W while the drawer terminal has focus collapses the pane. It never closes the main surface or the window.
- **Q6:** close the shell even when the removed row is the one on screen.

## Build outcome (2026-11-12)

- Built in 20 commits, `61d0137eb` through `f577deff0`.
- Review round 1 found two P2s, both fixed: the toggle-off now closes shells (`823522b0e`), and window close confirms a busy drawer shell (`f5acfb125`). ⌘Q already counted drawer surfaces through libghostty.
- The E2E found four bugs, all fixed: a 1×1 surface (`fa4e3eb1e`), Restart focus (`c545b874e`), a closed-window pool re-spawning a shell (`b861d0896`), and summary width (`2d879feb7`).
- Exit label: the local `login` wrapper always reports 0, so a status is shown only when it is non-zero (`1d9d2e6e6`).
- E2E numbers: RSS was 233 MB with 1 shell and 282 MB with 10. CPU running a busy loop was 6.6% expanded and 1.4% collapsed.
- Merge gate: GhosttyTests 4549/4549 and LeoKit 1712/1712 on the branch, with no failures that main doesn't have.

## Accepted risks

- **Focus after a restart on an offline host:** the shell exits, the host goes offline, the user presses Restart, and the state becomes "unavailable" with `focusesNextSurface` left set. When the host returns and the pane remounts, the shell takes focus unprompted. This is a contrived multi-event sequence.
- **Not tested end to end:** agent move to another host (there is no second isolated host) and the remote `agent shell` path (the daemon hasn't shipped). The remote path will be checked live once leo ships `agent_shell`.
- **Pre-existing, not from this branch:** `LeoAgentPaneStateTests.realPreferencesAreUnchanged` leaves stray plists on main as well. It is a follow-up.
