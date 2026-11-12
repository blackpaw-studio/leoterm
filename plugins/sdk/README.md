# Leo plugin SDK (API version 1)

TypeScript types and a build template for Leo plugins. Not published to npm: copy `template/` (plus `leo.d.ts` and `actions.ts`) into your plugin repo.

## Files

- `leo.d.ts`: types for the component tree, actions, the global `leo` bridge object and event payloads. Mirrors LeoKit's `Plugins` module.
- `actions.ts`: pure constructors (`callback`, `pushView`, `openURL`, `copy`, `sendToAgent`, `spawnAgent`). They only build JSON.
- `template/`: pinned esbuild + TypeScript, a `build` script, and a sample `leo-plugin.json`.

## Build

```
cd template
npm ci
npm run typecheck
npm run build     # dist/main.js, a single IIFE bundle
```

`main` in `leo-plugin.json` must point at the bundle. Commit the built bundle: Leo installs from a git commit and runs no build step.

## Model

Your code runs in a sandboxed JavaScriptCore host with no network, files or processes. Everything goes through the global `leo`:

- `leo.render(slot, tree)`: draw a slot. Use the `slot` the app hands to `activate`, `viewOpened` or `command`.
- `leo.on(event, fn)`: `activate`, `agentsChanged`, `viewOpened(agent, slot)`, `usageChanged(agent)`, `command(id, slot)`, `callback(id, payload)`. One handler per event.
- `leo.fetch(url, init)`: resolves `{status, headers, body, bodyEncoding}`; `bodyEncoding` is `"base64"` when the bytes are not UTF-8. Hosts must be listed in `permissions.network`, checked on every redirect hop. 60 requests/min, 4 in flight, 5 MB cap. Init takes string bodies only.
- `leo.secrets.get/set/delete`: needs `permissions.secrets: true`.
- `leo.agents.list()`: needs `agents: ["read"]`. With `"usage"` too (`usage` requires `read`; a manifest with `usage` alone is refused), entries also carry `model` and `workspace` (home-relative, or absolute outside home).
- `leo.agents.usage({machine, name})`: needs `agents: ["read", "usage"]`. Resolves a `UsageSnapshot` (all keys optional, absent keys omitted), `null` for "no data yet", or `{}` when the agent's harness reports no usage.
- `leo.timer(sec >= 60, fn)`, `leo.after(sec >= 1, fn)`: both return `{cancel()}`.
- `leo.log(level, message)`.

Rejections carry the reason (permission denied, rate limit, …) as the error message.

## Agent pane

A plugin may declare one pane in `contributes.panes: [{id, title, sfSymbol?}]`. Leo draws a tab bar under the selected agent's terminal/chat view; the collapsed tab shows your **summary**, the expanded drawer your **body**. Panes are per agent: `viewOpened(agent, slot)` hands you a `{kind:"pane", id, part:"summary"|"body", agent}` slot for each part, and you `leo.render` into it.

- Summary accepts only `Text`, `Meter` and `Accessory` (laid out in one row); anything else shows "!" and an error tooltip. Body accepts every component.
- `Text`: `{type:"Text", runs:[{text, tone?, weight?: "regular"|"semibold", mono?}]}`. At most 20 runs, 200 characters per run.
- `Meter`: `{type:"Meter", segments:[{value, tone}], max, label?, help?}`. 1 to 8 segments, finite non-negative values, `max > 0`, `help` at most 80 characters.
- `Tone`: `secondary`, `accent1` to `accent6`, `success`, `warning`, `failure`. No raw colours; Leo maps tones to light and dark mode.
- Refresh on `usageChanged(agent)` (at most once per agent per second, only while a pane is visible), then call `leo.agents.usage(agent)`.

## Actions

`sendToAgent` and `spawnAgent` are data, not functions. Return them from a list item, form field, or a `callback` handler (one follow-up, within 30 s, only if the callback began with a user gesture). Leo shows an editable confirmation sheet and calls the daemon only after the user confirms. They need `agents: ["send"]` / `["spawn"]` in the manifest. The spawn sheet always has a Template picker; `spawnAgent`'s optional `template` only preselects it. Every action takes an optional `title` (≤ 40 characters) and `sfSymbol` for menus and the ⌘↩ panel; the constructors take them as a trailing `label`.

## Limits

Tree depth 8, 2000 nodes (Text and Meter count one each), unique list item ids, accessory text ≤ 8 characters, accessory help ≤ 80, picker fields need options. `openURL` is https only.
