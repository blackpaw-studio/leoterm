# Drawer Terminal — built-in Terminal tab per agent

Date: 2026-11-12 · Status: approved in brainstorm (Evan, 2026-11-12) · Platform call: **Mac only**. iOS has no local shell, and its terminal is a read-only tmux mirror; a read-only mirror of this tab would be an iOS backlog idea. · Extends: `2026-11-12-agent-bottom-pane.md`

## Goal

Every agent gets a built-in **Terminal** tab in the agent bottom pane: a plain login shell started in that agent's workspace.

## Behaviour

- **Tab:**
  - It is built in, not a plugin, with id `leo.terminal`, title "Terminal" and symbol `terminal`.
  - It comes before the plugin tabs.
  - Settings has a "Show Terminal tab" toggle, on by default, next to the existing per-plugin pane hiding.
- **Pane visibility:** the pane now shows whenever an agent is selected and at least one tab is available. With the Terminal tab on, that means always for a selected agent. With no agent selected, there is still no pane.
- **Summary (collapsed strip):** `Terminal · <dir>`. `<dir>` is the shell's current directory as reported by the surface (OSC 7) when known, otherwise the workspace. It is shortened like the Status plugin's paths (`~/.l/a/leoterm`).
- **Starting lazily:** nothing is spawned until the user first opens that agent's Terminal tab. Opening it starts the shell:
  - **Local agent:** the user's login shell, with the working directory set to the agent's workspace, falling back to `repo` and then home if the path is gone. This uses the existing Ghostty surface configuration (`GhosttyAttachContentHost.configuration`) with the inherited config.
  - **Remote agent:** `leo --host <machine> agent shell -- <name>` (see "Daemon request" below). If the agent's daemon doesn't advertise the `agent_shell` feature, the body shows "Terminals for agents on <machine> need a newer Leo on that machine." and nothing is spawned.
- **Keep alive:**
  - Each window keeps one shell per agent. A shell keeps running, with its scrollback, when you switch agents, collapse the pane or switch tabs.
  - It is closed when the agent's row is removed, when the agent moves to another machine (`movedTo`), or when the window closes.
  - Two windows that show the same agent each have their own shell.
- **Shell exits** (for example `exit`): the body shows "Shell exited" with the exit status and a **Restart** button. Restarting spawns a fresh shell the same way.
- **Focus:**
  - Clicking the drawer terminal makes it first responder, and Ghostty keybindings then apply to it.
  - Expanding the Terminal tab from the strip or the menu focuses the drawer terminal.
  - Collapsing the pane while it has focus returns focus to the agent's main view.
- **Rendering:** a hidden drawer surface must not keep redrawing. Verify that Ghostty pauses rendering for an occluded or unattached surface, and pause it explicitly if it doesn't.

## Daemon request (the `leo` agent owns this)

`leo [--host H] agent shell [--] <name>`:
- Opens an interactive login shell (`$SHELL -l`, or the passwd shell) on the agent's machine, with its working directory set to the agent's workspace. It runs in a PTY over the same transport `agent attach` uses.
- It exits with the shell's exit status.
- It refuses unknown or moved agents with a clear message.
- The daemon advertises it as the feature `agent_shell`.

No other daemon change is needed. Local agents don't need this command.

## Testing

- **Pure logic, unit-tested:**
  - building tabs with the built-in tab first and the toggle respected;
  - pane visibility with only the Terminal tab;
  - choosing the launch command (local workspace, fallback chain, remote with and without `agent_shell`);
  - summary path shortening;
  - the per-window shell pool (lazy create, keep, close on row removal, move or window close, restart after exit). The pool is tested with a fake surface factory.
- **App:** a launch check after the pane changes (exit 124 means alive).
- **E2E in an isolated debug app with a scratch daemon:**
  - open the Terminal tab for a local scratch agent and confirm `pwd` is the workspace;
  - switch agents and switch back, and confirm the scrollback is kept;
  - run `exit`, then Restart;
  - remove the agent and confirm the shell process is gone;
  - **memory check:** open 10 agents' terminals and record the app's resident memory before and after;
  - screenshots collapsed and expanded, in light and dark.

## Out of scope

- A cap on the number of live shells (revisit if the memory check shows a problem).
- Multiple terminals per agent.
- Splits inside the drawer.
- Sharing one shell across windows.
- Persisting shells across app restarts.
- iOS.
