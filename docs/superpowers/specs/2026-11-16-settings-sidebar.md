# Settings window: one sidebar

Status: draft, 2026-11-16. Owner: Evan. Mockups (option A, chosen): `docs/mockups/2026-11-16-settings-redesign/` (`a1-this-mac`, `a1-this-mac-dark`, `a2-remote`, `a3-this-mac-defaults`).

## Problem

The Mac Settings window has two machine selectors that reach different things. The Machines tab list can't select This Mac. The toolbar machine picker silently retargets seven of the ten tabs and is ignored by the rest. Nothing on the page says which machine you are editing. Ten tabs at 820 pt, mixed control styles and mixed label casing read as un-Mac-like.

## Goal

A System Settings–style window where the sidebar selection is the only selector: whatever row you click is what you edit. This Mac is a first-class, selectable machine. App-wide and per-machine settings are separated by structure, not by explanatory notes.

## Decisions

- **Platform: Mac only.** iOS Settings already pushes a separate per-machine page (`ios/Leo/Settings/`), which is the same model. No iOS work and no backlog item.
- **Shell:** a split view (sidebar + detail) replaces the `TabView` and the toolbar machine picker. Both are deleted, not hidden.
- **Sidebar, top to bottom:**
  - **App** group: General, Plugins.
  - **Machines** group with a `+` in the header (opens the existing add-machine flow). Rows are This Mac first, then the remotes in registry order. Each row shows an icon, the name and a status (connected dot, or "Off" when disabled).
  - The selected machine's row expands to show its panes: Templates, Tasks, Environments, Delegation, Appearance, Defaults, Daemon. Selecting another machine collapses the previous one. A disclosure chevron on a collapsed row expands it without changing the selection.
- **General** (app-wide, UserDefaults): stats style, agent browser on/off, show Terminal tab. These move here from wherever they live today.
- **Appearance is per-machine.** It edits `appearance_rules` in that machine's leo.yaml.
- **Service folds into Daemon.** The Daemon pane gains the Service pane's content, and the Service tab goes away.
- **Machine row selected → machine overview page:**
  - **This Mac:** header (icon, name, model, agent count, connection badge). A Daemon section shows the `LeoManagedStatus` state in words, with that state's existing action (Set Up Daemon, Start CLI Daemon, Allow in Login Items, Let Leo Manage It), the config file path with Show in Finder, and the Reload/Restart actions where the app already has them. A Connection section shows the local socket path, read-only, and states that This Mac can't be removed.
  - **Remote:** header with the Enabled toggle. A Connection form with the fields the Machines tab edits today (name, SSH target, identity file, remote leo path, remote socket path) plus Test Connection. A Daemon line shows the remote's version. Remove Machine… (with confirmation) sits at the bottom.
- **Disabled or unreachable machine:** the overview page still opens. Child panes are listed but disabled, and the overview explains why ("Off" or the connection error).
- **Only real data.** Overview fields show only values the app can already source. A field without a source is dropped, not stubbed. Versions, PIDs and agent counts in the mockups are placeholders, not requirements.
- **Not in v1:** sidebar search, back/forward buttons. Both are in the mockup but cut (YAGNI).
- **Save behavior is unchanged.** Each pane keeps today's save/revert and conflict (409) handling.
- **Entry points:** every existing path that opens Settings at a specific tab or machine (menu items, the "Edit Machines…" path, the managed-daemon sidebar button, anything else) lands on the matching sidebar item. Selection is remembered across window opens; if the remembered machine is gone, fall back to This Mac.

## Visual consistency rules (all panes)

- One container style: grouped `Form` sections. No `GroupBox`.
- Pickers: segmented for 2–4 mutually exclusive options that are always visible; a popup otherwise.
- Labels: sentence case for setting labels and section headers; title case only for buttons and menu items, per HIG.
- Status colors are semantic system colors, not hardcoded `.green`/`.red`.
- Spacing comes from shared constants or system defaults. No ad hoc paddings.
- List add/remove uses the standard bottom-bar `+`/`−` control attached to the list.

## Constraints

- AppKit window and split view; SwiftUI content is fine. Read `nssplitviewcontroller-launch-crash` and `nssplitview-holding-priority` in memory before touching the split view. A green suite has missed a launch crash here before, so a launch smoke test is required.
- Dark mode and light mode both match the mockups.
- Full keyboard navigation of the sidebar. VoiceOver reads each machine row's name and status.

## Verification

- Unit tests for the selection model: sidebar item → (machine target, pane). Cover This Mac, a remote, a removed machine falling back to This Mac, and app items that carry no machine.
- A launch smoke test of the real app, plus native-pixel screenshots in light and dark of: This Mac overview, a remote overview, a This Mac pane, a remote pane, General and a disabled machine. Compare each with the mockups.
- Every entry point from the Entry points decision opens the right item.
