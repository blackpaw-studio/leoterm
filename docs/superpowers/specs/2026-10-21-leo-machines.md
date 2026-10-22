# Leo Machines: spawn anywhere, see every machine

Status: draft, awaiting Evan's approval. Platforms: Mac and iOS (shared logic lives in LeoKit).

## Goal

The Leo app treats every configured leo host as a first-class **machine**. All machines are connected at once. Their agents appear in one sidebar, grouped by machine. Each machine shows live CPU, memory and disk usage, and spawning an agent starts by choosing where it runs.

"Machine" is the term users see. Code, the CLI and docs keep "host", and nothing internal is renamed. This feature is unrelated to the daemon's existing `environments`, which are named env-var sets.

## Non-goals

- Moving an agent between machines. That gets its own spec after this ships, and it will likely be limited to git repos.
- HTTP-paired machines on the Mac. Mac remotes stay SSH; iOS stays paired HTTP.
- Stats history, sparklines, per-agent resource usage, and a separate dashboard.
- Federation between daemons.

## Behavior

### Connections (Mac)
- A machine registry replaces the single `LeoHostSelection` tunnel. It holds one connection per configured machine: the local socket for This Mac, and an SSH tunnel for each remote.
- Each machine has its own state: `connecting`, `connected`, `failed(reason)` or `disabled`. A machine that fails or hangs never blocks or tears down any other machine.
- Failed machines retry with backoff, capped at 60s between attempts. They also retry when the app is activated, and on demand through Reconnect.
- A machine marked disabled in Settings is not connected at all.
- Agent identity is the pair (machine, name). Two machines can both have an agent with the same name.

### Sidebar (Mac)
- The host dropdown is removed. The sidebar shows one collapsible section per machine: This Mac first, then the remotes in Settings order.
- A section header shows:
  - the machine name, with a hostname subtitle for This Mac;
  - a status dot;
  - three compact meters: CPU %, memory used/total and disk used/total.
- Meter colours: normal below 80%, warning at 80% or more, critical at 90% or more.
- Each meter has a tooltip with the exact values and the time they were sampled.
- An unreachable machine stays listed. Its header is dimmed, its section collapses, and it shows the failure reason and a Reconnect button.
- A machine on a daemon too old for stats shows its section without meters.
- The header's context menu offers New Agent Here…, Reconnect, Edit Machine… and Disable.
- Anything that is inherently about one daemon binds to This Mac: Leo Chat, the menu-bar daemon controls, and the bundled-daemon and managed banners. The plan must list every current consumer of `hostSelection.selected` and give each one a home. Any consumer that doesn't fit is a question for Evan.

### Machines settings (Mac)
- A Machines pane in Settings replaces `LeoHostsSheet`. It supports add, edit, remove, enable/disable, and Test Connection, which runs SSH plus a daemon `hello` and reports the result inline.
- The fields are the same as today's `LeoHostConfiguration`. Existing `leo.hosts` entries carry over unchanged.
- `leo.selectedHost` is migrated once into the last-used spawn machine, then deleted.

### Spawn (Mac and iOS)
- Machine is the first field in the spawn sheet.
- It defaults to the context machine when one exists: "New Agent Here", a board, or a row. Otherwise it defaults to the last machine used to spawn (persisted), and failing that to This Mac.
- Changing the machine reloads templates, environment options and the feature gates from that machine.
- Unreachable machines are listed but can't be selected, and show their status.

### Stats (cross-repo, leo daemon)
- New routes:
  - socket `GET /machine`;
  - web `GET /api/v1/machine`, which uses the same auth as `/api/v1/state`.
- The routes are advertised by the `machine_stats` feature flag.
- The response looks like this:
  `{"sampled_at": RFC3339, "cpu": {"percent": 0-100 | null, "cores": int}, "memory": {"used_bytes", "total_bytes"}, "disk": {"path", "used_bytes", "total_bytes"}}`
- Field meanings:
  - `cpu.percent` is the whole-machine CPU percentage since the previous sample, and is `null` on the first sample.
  - `memory.used_bytes` uses the platform's "used" figure: on macOS that is app, wired and compressed memory; on Linux it is total minus available.
  - `disk` is the volume holding the daemon's state directory.
- The daemon samples on request and caches the result for 1s. It runs no background sampler.
- Amendments agreed with the leo agent on 2026-10-21; the route ships in leo v0.57.0:
  - Each section is independently nullable: `cpu`, `memory` and `disk` can each be `null` when its probe fails. The route still returns 200, and the app shows that one meter as "—".
  - `cpu.percent` is `null` and the baseline resets when the previous sample is more than 60s old.
  - Disk is measured with statfs on the state directory: `used = total − f_bavail·bsize`, and `path` is the state directory itself.
  - On Linux, if MemAvailable is missing, memory falls back to MemFree + Buffers + Cached.
- The app polls each connected machine every 5s while the sidebar is visible and the app is active, and stops polling otherwise. iOS polls only while its machine list is on screen.
- The leo agent owns the daemon half. The contract above goes to it as the spec section to implement.

### iOS
- The daemon list becomes the machine list, with the same meters and status per paired daemon.
- The spawn sheet gets the machine picker. If iOS has no spawn flow, the plan says so and this item drops.
- Fleet groups agents by machine when more than one machine is paired.

## Shared code (LeoKit)
- Stats model plus decoding.
- Meter threshold mapping.
- Spawn default-machine resolution.
- Machine status model.

UI and transports stay per platform. The Mac uses an SSH socket; iOS uses HTTPS with bearer and CF Access.

## Process gates
1. Evan approves this spec.
2. A planner writes `docs/plans/2026-10-21-leo-machines.md`.
3. **Mockups:** HTML mockups of the Mac sidebar sections (healthy, warning, offline and no-stats states), the spawn sheet with the picker, the Machines settings pane, and the iOS machine list. They are posted to Evan, and building starts only after he approves them.
4. Implement in dispatches, with fresh-context review at the P0/P1 bar.

## Testing
- Unit tests:
  - registry isolation: one machine failing or hanging doesn't affect the others;
  - teardown on remove/disable;
  - (machine, name) identity merge;
  - spawn default resolution;
  - threshold mapping;
  - stats decoding, including a null CPU and a missing feature flag;
  - the `selectedHost` migration.
- Live checks:
  - the Debug app with This Mac plus at least two remote machines (Dionysus and a Tart VM), one of them taken down mid-session;
  - screenshots of every sidebar state;
  - an iOS simulator run against two paired daemons.

## Acceptance
- You can spawn on any connected machine from one sheet without switching anything.
- Agents from every connected machine are visible at once, grouped by machine.
- Each connected machine shows CPU, memory and disk usage, refreshed about every 5s.
- Killing one remote machine leaves every other machine's section working.
- iOS shows the same meters and has the machine picker.
