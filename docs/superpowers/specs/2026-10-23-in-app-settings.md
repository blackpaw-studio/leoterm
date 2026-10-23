# In-app settings (web UI parity)

Status: draft, 2026-10-23. Owner: Evan.

## Goal

Everything a user can do in the leo daemon's web UI (`:8370`) can be done from Leo's Settings window on the Mac, for any connected machine.

## Decisions (from the brainstorm)

- **Platform:** Mac first. Models, validation and the daemon client live in LeoKit, so the iOS half is mostly UI. iOS is deferred and goes on the autopilot backlog.
- **Scope:** every web UI area ships in v1. The work is built and merged in slices, in the order listed under Panes.
- **UI:** hand-built native SwiftUI panes, one typed model per section. No schema-driven forms.
- **Target:** a machine picker in the Settings toolbar chooses which daemon is edited. It defaults to the selected agent's machine and can edit any connected machine over its existing connection.

## Daemon contract (leo repo; PR reviewed and merged by the `leo` agent)

The daemon has no JSON config API today: the web UI saves config through HTML form posts (`internal/web`). Add one, operator-only, on the socket API and on `/api/v1`:

- `GET /config/<section>[/<name>]` returns typed JSON plus a `revision` (a hash of leo.yaml).
- `PUT /config/<section>/<name>`, `POST` (add), `DELETE`, and `POST .../rename` / `.../duplicate` where the web UI has them. Each write carries `If-Match: <revision>`. A stale revision returns `409` with the current revision, and the app offers Reload or Overwrite.
- Every write goes through the web UI's existing validation and `config_lock`, then reloads config. Field errors come back as `422 {errors: [{field, message}]}`.
- A response marks any change that needs a daemon restart rather than a reload (for example `web.allowed_hosts`). The app then shows a Restart Daemon action.
- Task prompt files get `GET`/`PUT /config/tasks/<name>/prompt`. Cron preview, delegation preview, service restart and log tail reuse or wrap the existing handlers.
- Secrets (tokens, client credentials) are never returned. Their fields are write-only: shown as "Set" or "Not set", with Replace and Clear actions.
- **Parity test:** a daemon test lists every field in `internal/web/schema` and fails when a field is not covered by the JSON API. The app keeps a matching fixture test, so a new field fails CI until both sides handle it.
- A `capabilities` flag on `/version` lets the app hide Settings panes on daemons that are too old, with a "Requires leo ≥ X" note.

## Panes (Mac)

These are tabs in the existing Leo Settings window (`LeoSettingsWindowController`), beside Machines. They are listed in build order.

1. **Templates:** list plus a detail editor. Add, rename, duplicate, delete.
2. **Tasks:** list with enabled toggles and Run Now. The detail editor covers schedule (with a live cron preview), template, and an editor for the prompt file. Add, delete. Run history and the last run's log, read-only.
3. **Environments:** list plus a detail editor. Add, rename, delete.
4. **Delegation:** a role × profile matrix with cell editing, the active profile, the enabled and hide-agents toggles, and role/profile add, rename, duplicate, delete. Includes the routing preview.
5. **Defaults:** a single form.
6. **Daemon:** web and client settings, and remote hosts (CRUD).
7. **Service:** daemon status, Restart (confirmation required), Restart All Agents (confirmation required), and a live log tail with pause and copy.

Agent actions are already in the sidebar and menus, so this spec adds none. Any web UI agent action the app still lacks is listed in the plan and added to the sidebar's agent menu, not to Settings.

## Behavior

- Editors use explicit Save and Revert. Save is disabled while the form is unchanged or invalid. Closing a pane or switching machines with unsaved edits asks first.
- Client-side validation mirrors the daemon's, but the daemon is authoritative: `422` errors are shown inline on their fields.
- Destructive actions (delete, restart) confirm first and name what will be affected.
- Switching machines reloads every pane. A disconnected machine shows its Machines-style status and a Reconnect button in place of the pane.
- A daemon that is too old shows a notice. It never shows a half-working form.

## Out of scope

- iOS (deferred; add to the backlog).
- A Ghostty config editor (⌘, stays upstream).
- Editing raw leo.yaml.
- Login, pairing-code and SSO web flows (pairing already exists in the menu bar).

## Testing

- Daemon: handler tests per route (success, 409, 422, restart-required, secret redaction), plus the parity test.
- LeoKit: decoding/encoding fixtures captured from the real daemon; the client's handling of revision and 409; validation rules.
- Mac: a model test per pane (dirty state, save, conflict, errors). Screenshot checks of each pane in light and dark. A real-app check that edits a template on a remote scratch machine, then confirms the change in that daemon's leo.yaml and in its web UI.

## Open questions

- None blocking. Exact field lists per section come from the daemon PR.
