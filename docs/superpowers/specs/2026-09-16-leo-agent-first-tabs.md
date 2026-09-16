# Leo: agent-first tabs, splits, and windows

Status: draft for approval · 2026-09-16 · follows the v2 agent-manager spec (M7 done).

## Goal

The main window is for Leo agents. Every "new tab / new split / new window"
gesture offers an agent picker instead of a plain shell. Plain terminals live
in Ghostty's existing Quick Terminal, used as a drawer.

## Decisions (Evan, 2026-09-16)

- Picker = command palette: a floating panel over the window, type to filter,
  Return attaches, Esc cancels. Same for tab, split, and window.
- Drawer = upstream Quick Terminal, unchanged. No per-window drawer, no tabs
  in the drawer. Position is user config (`quick-terminal-position = bottom`).
- A brand-new window (launch, Cmd+N) opens with a placeholder view and the
  palette already open. Esc leaves the placeholder. Cmd+T / split in an
  existing window create nothing on Esc.
- "New agent…" in the palette opens the existing Spawn Agent sheet; the
  spawned agent attaches into the pending slot (tab, split, or placeholder).

## Behaviour

Palette rows, in order:
1. Agents on the currently selected host (name, status dot, repo/branch),
   sorted like the sidebar. Filter is case-insensitive substring on name and
   repo.
2. `New agent…` → Spawn Agent sheet.
3. `Plain shell` → the default Ghostty surface, for the rare split-beside-agent
   case. (Cut this row if unwanted.)

Dispositions: `tab`, `split(direction)`, `window`, `placeholder`.
- `tab`: if a live attach tab for that agent exists in any window, focus it
  (today's coordinator rule). Otherwise open a new tab running the attach
  command via `SurfaceConfiguration.command` (local or SSH form, unchanged).
- `split`: always attaches again in a new split, even if a tab exists
  (tmux allows multiple clients).
- `window`: new window whose first surface is the attach.
- `placeholder`: replace the window's empty surface tree with the attach
  surface.

Host state: while the host is `connecting`, the list is disabled with a
"Connecting to <host>…" row; when `failed`, the palette shows the failure
message, hint, and a Retry button (existing `LeoHostSelection.retry`).
Attach failures (missing leo binary, ssh error) surface inline in the palette;
nothing is created.

Placeholder: an empty `SplitTree` (the Quick Terminal already supports this)
with a SwiftUI view: "Pick an agent · ⌘T", a button that reopens the palette,
and a link to toggle the Quick Terminal.

## Interception (zero Zig changes, hook budget stays at 4 files)

- `TerminalController.newTab` / `newSplit` overrides and the initial-surface
  path get `// MARK: Leo` guards that route to `LeoNewSurfaceRouter` instead
  of creating a surface. Core keybinding actions (`new_tab`, `new_split`,
  `new_window`) arrive through the same controller methods, so both menu and
  keybinding paths are covered.
- `AppDelegate.newWindow` and launch-window creation route through the same
  router with the `placeholder` disposition.
- Existing attach entry points (sidebar row click, `leo agent attach` from the
  CLI) are unchanged and keep using `LeoAttachCoordinator`.

## Components (all under `macos/Sources/Features/Leo/Picker/`)

- `LeoAgentPaletteModel` (@MainActor, ObservableObject): rows from the
  sidebar snapshot + host state, filter text, selection, `confirm()` →
  `LeoPickerChoice` (`.agent(identity)`, `.newAgent`, `.plainShell`,
  `.cancel`). Pure, testable.
- `LeoAgentPalettePanel` (NSPanel + SwiftUI content): key handling
  (↑ ↓ Return Esc), one instance per main window, sized like a Spotlight bar.
- `LeoNewSurfaceRouter`: receives (window, disposition), shows the palette,
  maps the choice to `LeoAttachCoordinator` (existing) or the default surface
  config, or to the Spawn sheet followed by attach.
- `LeoPlaceholderView` (SwiftUI): the empty-window view.

## Out of scope

Session restore of attached agents; per-window drawers; agents from a host
other than the selected one; changes to the sidebar.

## Testing

- `LeoAgentPaletteModelTests`: filtering, ordering, host-state rows, confirm
  mapping, Esc → `.cancel`.
- `LeoNewSurfaceRouterTests` with a fake coordinator: each disposition maps
  to the right coordinator call; `.cancel` creates nothing; `placeholder`
  replaces the tree exactly once; spawn → attach chains into the pending slot.
- Existing `LeoAttachCoordinator` tests extended for the `split` and
  `placeholder` dispositions.
- GUI acceptance on the laptop: Cmd+T / Cmd+D / Cmd+N / launch, Esc paths,
  New agent…, Quick Terminal toggle.
