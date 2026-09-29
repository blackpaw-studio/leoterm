# Leo Term — Vision

## North star
Leo Term is the one place you work with your Leo agents: see what every agent
is doing, jump into any of them, and open, read, and edit the files they
surface to you — identically whether the daemon is local or over SSH. Built on
Ghostty, native to the Mac.

Reference point: Orca (onorca.dev) — an agent workspace, but Leo-native.

## Taste principles
1. **Keyboard-first, Mac-native.** Every action has a shortcut and a menu
   item. AppKit/SwiftUI per Apple HIG; no web views for core UI. When two
   options differ, pick the one that feels like a first-party Mac app.
2. **Calm, attention-driven.** Quiet by default. Only "this agent needs you"
   earns a badge, notification, or motion; everything else is ambient status.
   Never invent a state the daemon didn't report.
3. **Local = remote.** Every feature works the same against a local daemon
   and over the app-owned SSH tunnel. Agent control goes through the daemon
   API; file access goes through one abstraction with a local-FS backend and
   an SFTP backend riding the existing SSH ControlMaster. A feature that only
   works on localhost isn't done.
4. **Everything through Leo.** If Evan has to leave the app to work with an
   agent (read a file it wrote, see its state, find its tab), that's a gap
   worth closing.
5. **Manual recovery, never timers.** On disconnect, show it plainly and offer
   Retry. No auto-reconnect loops.
6. **The sidebar is the navigation.** No tab bar. A window has one content
   area showing the selected row (agent or plain shell, with its splits and
   editor pane). Switching rows must feel instant: recently viewed surfaces
   stay attached, and only ones outside that pool detach and reattach (D-098).

## Non-goals
- A tab bar or per-tab sidebars. Rows replace tabs (D-098).
- Live grid wall / tmux control-mode renderer (`legacy/grid`).
- Daemon-owned remote hub; user-run forwards. SSH tunnel is owned by the app.
- Auto-reconnect timers for the tunnel.
- A full IDE: the file pane is a capable viewer/editor (syntax highlight,
  save, diff), not LSP/refactors/build tooling. Agents do the heavy editing.
- Non-Mac platforms (no GTK/Windows port of Leo features).
- Not now, but wanted later: mobile companion app, embedded browser, GitHub
  integration. Don't build them this milestone; don't design them out.

## Done — current milestone ("Sidebar navigation", from 2026-09-28)
1. The window has no tab bar. Clicking a sidebar row, or its keyboard
   equivalents, shows that agent in the window's single content area, and
   there is one sidebar per window.
2. Switching between recently viewed agents is instant and keeps Ghostty
   scrollback, scroll position and view state. Agents outside the live pool
   reattach on selection, with no duplicate tmux clients left behind.
3. Plain shells are rows in a "Terminals" sidebar section; ⌘T makes one and
   selects it.
4. Splits still work in the content area (⌘D, the editor/file pane, a second
   agent or shell), and every row that's on screen is highlighted.
5. Every row-switch action has a shortcut and a menu item; tab-only
   affordances are removed or remapped, with each call logged.
6. Each flow has tests plus a screenshot from the isolated debug build.

## Done — previous milestone ("Attention + Files", complete bar B-014 deferred)
1. Sidebar shows working / needs-input / finished / errored per agent (per
   the approved attention spec), with a Dock count and ⌃⌥⌘J jump-to-next.
   Legacy daemons show Working only.
2. ⌘-click a path or OSC 8 link in an agent terminal opens it in a Leo editor
   pane; a per-agent workspace browser lists its files. View, edit, save —
   same UX local and over SSH (SFTP).
3. The focused attach tab highlights its sidebar row; clicking a highlighted
   row focuses the tab.
4. Each flow has tests plus a screenshot from the isolated debug build.
