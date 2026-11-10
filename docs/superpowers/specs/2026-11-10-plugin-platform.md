# Leo Plugin Platform — v1 Spec

Date: 2026-11-10 · Status: draft for approval · Platform call: **Mac only** (iOS deferred; see Non-goals)

## Goal

Let first- and third-party authors extend the Leo Mac app with **fully native UI** and sandboxed logic, without rebuilding Leo. GitHub (separate spec: `2026-11-10-github-plugin.md`) is the first plugin and is built only on the public API.

## Decisions (settled in brainstorm)

| Topic | Decision |
|---|---|
| Authors | First- and third-party from v1 |
| UI | Declarative: plugins return a tree of Leo components; Leo renders in AppKit. No web views. |
| Logic | TypeScript compiled to a single JS bundle, run in JavaScriptCore inside a per-plugin sandboxed XPC helper |
| Local exec | None. Plugins cannot run processes. |
| Network / secrets | Only via bridge calls the app performs, checked against the manifest |
| Agent actions | Send/spawn only from a user-clicked action, always through a native, editable confirmation sheet |
| Install | Git URL pinned to a commit SHA; local-folder dev mode with reload; first-party plugins bundled |
| Daemon | No changes. Uses existing routes (`/agents/list`, `/agents/spawn`, `/agents/{name}/message`, SSE events). |

## Architecture

- **LeoKit `Plugins` module (platform-neutral, unit-tested):** manifest model + validation, permission engine, component-tree model (Codable), action model, bridge message protocol. Kept in LeoKit so a future iOS host can reuse it.
- **`LeoPluginHost` helper (Mac):** a sandboxed helper executable in `Contents/Helpers/`. Leo spawns one per enabled plugin with `posix_spawn` and talks to it over a `socketpair` using length-prefixed JSON. It has App Sandbox with **no** network and no file access beyond its bundle, and runs interpreter-only JavaScriptCore with no `allow-jit`. It hosts a `JSContext`, exposes only the `leo` bridge object, and does pure compute. XPC was dropped because the M0 spike found `_MultipleInstances` gives one shared process; see `docs/plans/2026-11-10-plugin-platform-spike.md`. Evan approved this on 2026-11-10.
- **`LeoPluginManager` (Mac app):** discovers/installs plugins, launches hosts, routes bridge calls, enforces permissions, performs fetch/Keychain/agent calls on the plugin's behalf.
- **Native renderers (Mac app):** AppKit views for each component, used in all four slots.

## Manifest (`leo-plugin.json`)

```
id            reverse-DNS, unique (e.g. studio.blackpaw.github)
name, version (semver), apiVersion (integer; v1 = 1), main (path to JS bundle)
permissions:
  network: [host patterns]   exact host or "*.suffix"; applies to every redirect hop
  secrets: true|false        per-plugin Keychain namespace
  agents:  ["read", "send", "spawn"]   any subset
contributes:
  views:           [{id, title, sfSymbol}]          entries in the agent view picker
  rowAccessories:  [{id}]                            one slot per plugin per row
  commands:        [{id, title, sfSymbol?}]          palette commands
  sidebarSections: [{id, title}]                     collapsible sidebar sections
```

Unknown keys, unknown permissions, or `apiVersion` > supported → install refused with the reason.

## UI slots

1. **Agent view.** Plugin views are listed in the agent toolbar menu and the row context menu, next to Browser and Editor. They open in the row pane and receive that agent as context. The Terminal/Chat toolbar switch gets no new segments.
2. **Row accessory.** At most one small accessory per plugin per agent row: allowlisted SF Symbol + ≤8 chars of text + semantic colour (neutral/success/warning/failure/running). Overflow collapses into one "+N" glyph.
3. **Commands.** Listed in a single command palette that also contains Leo's built-in commands. It reuses the upstream Ghostty palette UI and binding (`toggle_command_palette`, ⌘⇧P). Leo does not take ⌘K, which Ghostty uses for clear-screen. A command may run a callback or push a view (List/Form) inside the palette.
4. **Sidebar section.** Collapsible, below the agent list, collapsed by default; the user can hide it per plugin.

## Component set (v1)

`List` (sections, items: title, subtitle, sfSymbol, accessories, actions) · `Detail` (restricted Markdown → native attributed text: headings, emphasis, code, links, lists) · `Form` (text field, text area, picker, checkbox, submit) · `Accessory` (as above) · `EmptyState` · `Loading` · `Error` (message + retry). Every list item's actions appear in its context menu and in an action panel opened with ⌘↩, and the first action runs on Return.

**Slot root:** one component, or an ordered array of components drawn stacked. **Accessory** also takes an optional `help` tooltip of at most 80 characters.

**Actions:** `callback(id, payload)` · `pushView(view)` · `openURL(https only)` · `copy(text)` · `sendToAgent(agent, text)` · `spawnAgent({repo, branch, base?, prompt, machine?})`.

## Bridge API (`leo` object in JS)

- `leo.render(slotId, tree)`: replace the slot's content. Called from handlers; the host diffs and re-renders natively.
- `leo.on(event, fn)`: `activate`, `agentsChanged`, `viewOpened(agent)`, `command(id)`, `callback(id, payload)`.
- `leo.fetch(url, init) → Promise<{status, headers, body}>`: performed by the app, which checks the manifest hosts on every hop. Per-plugin rate limit of 60 req/min and 4 in flight. Bodies are capped at 5 MB.
- `leo.secrets.get/set/delete(key)`: Keychain item `leo.plugin.<id>.<key>`.
- `leo.agents.list()`: snapshot of `{name, machine, status, repo, branch, hasWorktree}`. Requires `agents:read`. Worktree paths are not exposed.
- `leo.timer(intervalSec ≥ 60, fn)`: periodic refresh, active only while the app is running.
- `leo.after(sec ≥ 1, fn)`: one-shot timer that runs only while one of the plugin's slots is visible, for short polls such as device-flow sign-in.
- A `callback` handler that came from a user gesture may resolve to **one** follow-up action, including `sendToAgent` or `spawnAgent`. It must do so within 30 s wall time and still goes through the confirmation sheet. A follow-up from a callback that didn't start with a gesture is dropped.
- `sendToAgent` / `spawnAgent` exist **only** as actions, never as functions plugin code can call directly. The app opens the confirmation sheet (target, editable text or spawn fields, plugin name) and calls the daemon only after the user confirms.

## Install, update, dev mode

- **Settings → Plugins pane:** list plugins with enable/disable, permissions, version and SHA, and uninstall. "Install from URL…" resolves a tag or branch to a SHA, shallow-clones into `~/Library/Application Support/Leo/Plugins/<id>/<sha>/`, then shows a permission sheet. Nothing runs until the user approves.
- **Updates:** the user clicks "Check for updates" (there is no auto-update in v1). Any permission increase shows a diff and requires re-approval.
- **Dev mode:** "Load local folder…" registers a folder in place, watches `main`, and reloads the host on change. Dev plugins are badged "DEV".
- **First-party:** shipped inside the app bundle and enabled by default. They follow the same manifest and permission rules, so they get no hidden powers.

## Failure handling

- A crashed host restarts with backoff (1 s, 5 s, 30 s). Three crashes within 5 minutes disable the plugin and show a notice in Settings and in each slot.
- A bridge handler that runs longer than 2 s of CPU gets its host killed, and that counts as a crash. Each host is capped at 256 MB.
- Every slot shows `Loading` until the first render, and shows `Error` with Retry on a failure.
- Fetch errors and permission denials go back to the plugin as rejected promises with a reason, and are also logged under the `leo.plugins` OSLog category.

## Testing

- LeoKit unit tests cover: manifest validation (good, bad, future `apiVersion`), the permission engine (including redirect hops and wildcard hosts), component-tree decoding, and action gating (send and spawn are unreachable as direct calls).
- Host integration tests run a fixture plugin in the JSC host to check the bridge round-trip, timeouts, and that crashes are recovered.
- UI check: screenshots of each slot rendered by a fixture plugin, in both light and dark mode.

## Non-goals (v1)

- Marketplace or index (planned later as a git-URL index).
- iOS plugins: the Mac/iOS split is recorded and an idea is added to the backlog.
- Background automations or running while the app is closed.
- Local exec.
- Web views in plugins.
- Themes or syntax plugins.
- Plugin-to-plugin APIs.
- Daemon changes.
- Signed archives.

## Open items

- Each plugin's helper is a separate XPC process. If memory adds up badly with many plugins, revisit sharing a host, but only after measuring.
- The SDK's TypeScript types and esbuild template live in-repo under `plugins/sdk/`. Publishing them to npm is deferred.
