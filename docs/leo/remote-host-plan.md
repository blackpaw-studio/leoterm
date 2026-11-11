# leoterm remote-host support — implementation plan (B/C/D)

Branch: `feat/remote-host`. Phase A (foundation) already merged on this branch
(`LeoHost`, `Board.host`, `LeoSocketClient(host:)`, `LeoForwardManager`).

## Design (settled)

- leo's remote model is **SSH, not a network API**. The daemon socket stays
  local-only on every machine. Remote control plane = a persistent
  `leo host forward <name> --json` that StreamLocalForwards the remote daemon
  socket to a local path; remote cells = `leo --host <name> agent attach --cc`
  over the same SSH ControlMaster.
- **Per-board host.** Each `Board` binds to one host (`Board.host`, default
  `localhost`). The sidebar **follows the active tab/board** — one panel that
  retargets to the frontmost board's host.

## leo CLI contract (from the `leo` agent, branch `feat/remote-host-forward`)

- `leo host list --json` → `[{name, ssh?, default:bool, local:bool}]`
  (synthesized `localhost` first). Decoded by `LeoHost` (Phase A).
- `leo host forward <name> --json` → blocks; first stdout line
  `{"socket":"…","host":"…","pid":…}` once healthy; exits before printing =
  setup failed. Owned by `LeoForwardManager` (Phase A). `--stop` tears down.
- `leo --host <name> agent attach --cc <agent>` → remote cell (PTY already
  satisfied: Ghostty surfaces are PTY-backed; leo adds `-tt`/`-e none`).
- `leo --host <name> agent list|spawn|stop|prune --json` → control plane.

## Tasks

### Task 1 — LeoHostCatalog + LeoHostRegistry  (non-UI core)
- `LeoHostCatalog`: runs `leo host list --json`, decodes `[LeoHost]`. DI a
  process runner (mirror `LeoSocketClient.runCLI`). Unit-test arg + decode.
- `LeoHostRegistry` (`@MainActor`): host name → cached connection
  (`LeoAgentStore` + optional `LeoForwardManager`). `store(for:)` acquires
  (ref-counts); localhost → `LeoSocketClient()` no forward; remote → start
  forward, build `LeoSocketClient(socketPath: forwarded, host: name)`.
  `release(_:)` decrements; at zero, stop the forward. DI the forward launcher.
  Unit-test: remote acquire starts forward + store uses returned socket path;
  release at zero stops; localhost needs no forward; ref-count reuse.

### Task 2 — Sidebar follows active host
- `LeoSidebarModel`: make `store` swappable (`@Published`); add
  `setActiveHost(_:)` that pulls the store from the registry, releases the
  previous host, and restarts polling against the new store. Hold a registry ref.
- `LeoSidebarView`: observe the model; bind to `model.store` (handle store
  identity change).
- Wire board activation → `setActiveHost(board.host)` in the controller
  (on restore + window become-key).

### Task 3 — Remote cell attach
- `CellSource.surfaceConfiguration(host:)`: for a remote host, command becomes
  `/usr/bin/env -u TMUX -u TMUX_PANE leo --host <name> agent attach --cc <agent>`;
  localhost unchanged. Update the caller in `BaseTerminalController` to pass the
  board's host. Unit-test command construction (local + remote).

### Task 4 — Per-board host picker UI
- A SwiftUI picker populated from `LeoHostCatalog.listHosts()` to set a board's
  host (at board creation and a "change host" affordance). Persist on the board.
- Spawn sheet spawns against the active board's host (already via the sidebar's
  active store).
- GUI not visually verifiable from the agent session — build + unit-test only;
  Evan verifies live.

## Verification (gated on Evan)
End-to-end needs leo's `feat/remote-host-forward` installed as the `leo` binary
+ a real remote in `leo.yaml`. Do NOT install until Evan says so.

## Build/test (run from `macos/`)
`DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`
- build: `xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- test: `xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -only-testing:GhosttyTests`
- lint: `swiftlint lint --strict --quiet Sources/Features/Leo Tests/Leo`
Tests use Swift Testing. New files auto-picked-up (synchronized groups).
