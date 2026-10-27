# Agent Appearance: optional emoji and color per agent

Status: approved by Evan 2026-10-27. Platforms: Mac and iOS. The daemon owns the data and the resolution, LeoKit owns the wire model, and each app keeps only its rendering and editor UI.
Mockups: https://claude.ai/artifact/3dNyfmQFoCiw6rzJGuBiAM (Mac option C, the picker, rules, and iOS).

## Goal

Any agent can have an optional emoji, an optional color, or both. Each can be set by hand on one agent or come from ordered rules, for example "environments contains `homelab` → teal". An agent that has neither looks exactly as it does today.

## Non-goals

- Colors derived from the agent's name. The rules board shows this as an option, off by default; it is not built in v1.
- Arbitrary hex colors. Colors come from a fixed named palette.
- Custom images or SF Symbol icons. v1 is emoji only.
- Appearance for dispatch rows.

## Data model (daemon, `leo.yaml`)

- Palette: `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `indigo`, `purple`, `pink`, `gray`. Each app maps a name to its own light and dark shade.
- Manual settings go on the agent's record in the agent store (`state/agents.json`, `agentstore.Record.Appearance`), next to the environments override: `{ emoji?: "🏛️", color?: teal }`. A rename carries them along and a delete removes them. They are not stored in `leo.yaml` (Evan, 2026-10-27, plan option A).
- Rules go in a top-level list:
  ```yaml
  appearance_rules:
    - when: { field: environments, op: contains, value: prod }
      color: red
    - when: { field: name, op: glob, value: "alfred-*" }
      color: pink
      emoji: "🎩"
  ```
  - Fields: `name`, `environments`, `template`, `harness`.
  - Ops: `is`, `contains`, `starts_with`, `glob`. For `environments`, `contains` and `is` test list membership.
  - A rule sets a color, an emoji, or both. A rule that sets neither is rejected.
  - There is no `machine` field because rules are per-daemon. The `Machine is Hestia` row on the mockup's rules board is dropped.
- Validation: the emoji must be a single grapheme cluster, and the color must be a palette name. Invalid config is reported through the same error path as environments, and never crashes the daemon.

## Resolution (daemon)

- Color and emoji resolve independently. For each one, the manual value wins. Otherwise the first rule, top to bottom, that sets it wins. Otherwise it is unset.
- The observed agent wire gains `appearance: { emoji?, color?, emoji_source?, color_source? }`. A source is `manual` or `rule:<index>`. When nothing is set, the key is omitted, so old apps are unaffected.
- Resolution reruns whenever config changes or an agent's environments change.

## Routes (daemon)

- `GET /appearance/rules` returns the rule list.
- `PUT /appearance/rules` replaces the list atomically and validates it. A bad rule gets a 400 with the index and the reason.
- `PUT /agents/{name}/appearance` sets `{emoji?, color?}`, and `null` clears that field.
- Writes persist to `leo.yaml` the same way the daemon's existing config writes do. If no write path exists yet, the plan raises that before any work starts.

## Mac (option C)

- Row: the status symbol stays in the leading slot. A 3pt color bar sits on the leading edge when a color is set; otherwise that slot is a blank 3pt spacer so names stay aligned. The emoji, if set, goes before the name. Nothing else about the row changes, including the selection ink.
- Context menu: Appearance… opens the popover. It has emoji search and a grid, palette swatches plus None, and a line saying where each value comes from ("Teal from rule …"). Reset to rules clears the manual values, and Edit rules… opens Settings.
- Settings: an Agent Appearance pane, per machine. It shows an ordered list of rules with drag to reorder, add and delete, a field/op/value control, a color and emoji per rule, and a count of matching agents. A live preview column shows each agent's result and its source.

## iOS

- Row: an agent with an emoji gets a neutral tile showing the emoji, with the status dot on its corner. An agent without one keeps today's status symbol. A 4pt bar on the left edge appears when a color is set.
- Long-press offers Appearance, a sheet with the same picker and source line as the Mac.
- The rules editor on iOS is deferred to the autopilot backlog. iOS displays the results of rules but cannot edit them in v1.

## Verification

- Daemon: table tests for resolution, covering manual over rule, first match wins, independent fields, environments membership, glob, and invalid config. Also route tests for validation and persistence.
- LeoKit: decode the wire with the key present, absent, and partially set.
- Apps: screenshots of the real sidebar and list with all four combinations (both, emoji only, color only, neither), in light and dark, with one row selected.

## Delivery

1. A daemon PR in the leo repo. The `leo` agent reviews and merges it; I never merge it myself.
2. LeoKit plus Mac.
3. iOS.

## Amendment 2026-10-27

- In the picker, "None" clears this agent's own pick, and the agent falls back to the rules, which is the same as Reset to rules for that field. v1 has no way to turn a rule's color off for one agent. Adding an explicit `"none"` value to the daemon is a possible follow-up.
