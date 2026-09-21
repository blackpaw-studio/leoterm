# Leo roadmap

Status legend: `[ ]` planned · `[~]` in progress · `[x]` shipped · `[?]` needs decision

Prerequisite for everything below: Evan's GUI acceptance of the 2026-09-16
work (palette keyboard, placeholders, Hosts sheet, remote attach/logs). The
picker logged `outcome=cancel` 0.4 s after present when launched headless via
`open`; confirm it is a focus artefact and not a real bug.

## Tier 1 — highest leverage

- [x] **Push-driven list, poll as fallback.** Merged `d74bb7f2d`. Refresh `/agents/list` on SSE
  state events; poll only while SSE is disconnected (~30 s). Today the list
  polls every 2 s even with SSE live (`LeoPollScheduler`).
- [x] **Template fetch cache.** Merged. One templates request per host per refresh,
  invalidated on refresh, instead of one per row context menu and one per
  Agents-menu update (`LeoAgentRow`, `LeoAgentMenuActions`).
- [?] **Attention model.** Spec: docs/superpowers/specs/2026-09-21-leo-attention-model.md. Derive working / needs-input / finished from the
  SSE activity stream. Row badge, Dock badge, macOS notification when a
  non-focused agent goes idle, "jump to next agent needing attention"
  shortcut. Spec required before build.

## Tier 2 — UX

- [ ] **Tab ↔ row linkage.** Highlight the row whose attach tab is focused;
  tab-count glyph on rows with live tabs; click on a highlighted row focuses.
- [ ] **Sort and pin.** Default sort by last activity; pin favourites to the
  top; remember collapsed sections.
- [ ] **Row metadata.** Relative "last active" time and current task line;
  tokens or cost when the daemon exposes them.
- [ ] **Search polish.** ⌘F focuses the sidebar filter, fuzzy match, Escape
  clears.
- [ ] **Disconnected state.** On tunnel drop or wake, grey the list and show a
  Retry banner instead of stale rows. Manual retry stays the rule.
- [?] **All hosts at once** as sidebar sections. One-at-a-time was the v1
  decision; revisit once several remotes are in daily use.

## Tier 3 — performance

- [x] **Coalesce activity events** (merged) (~100 ms) before rebuilding rows; skip
  emission when the snapshot is unchanged (`LeoSidebarFeed`).
- [ ] **Non-blocking socket I/O.** Replace blocking poll/recv slices in
  `LeoUnixSocketTransport` with NWConnection (unix endpoint) or DispatchIO.
- [ ] **Cold start.** Measure launch with the sidebar visible; if the first
  fetch blocks first paint, render the cached last snapshot and refresh in
  place.

## Decided against (do not propose)

- Live grid wall / tmux control-mode renderer (`legacy/grid`).
- Daemon-owned remote hub; user-run forwards. SSH tunnel owned by the app.
- Auto-reconnect timers for the tunnel.
