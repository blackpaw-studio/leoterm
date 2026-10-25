# iOS Settings (phone essentials)

Status: draft, 2026-10-24. Owner: Evan. Parent spec: `2026-10-23-in-app-settings.md`, which shipped the Mac half in Leo 0.24.4.

## Goal

From the iOS app, edit and operate a paired machine's daemon for the things you need away from your desk: tasks, templates, environments and the service.

## Decisions

- **Panes:** Tasks, Templates, Environments and Service. Defaults, Delegation and Daemon settings stay on the Mac and the web UI.
- **Placement:** under each machine. Machines (`DaemonsViewController`) → tap a machine → a machine detail list with rows for Tasks, Templates, Environments and Service. The machine is implied by the navigation path. There is no picker.
- **Stack:** UIKit view controllers with TCA features in `ios/LeoFeatures` (no SwiftUI). The logic is reused from LeoKit `Config/`: the models, `LeoConfigClient` over the web transport, `LeoConfigDraft` with per-key, per-entry and list diffs, validation, and the fake client.
- **Transport:** the machine's existing `/api/v1` connection with its paired-device token. The daemon treats that token as operator-equivalent.

## Behavior

The rules are the same as on the Mac, so each one reuses the shared LeoKit logic:

- Explicit Save and Revert. A 409 shows a banner with Reload and Overwrite, and Overwrite resends only your edits. A 422 shows the error inline on its field. Secrets are write-only: shown as "Set", with Replace and Clear actions.
- Destructive actions (delete, restart, Restart All Agents) confirm first and name what they affect, including the agent count.
- A daemon without the `config_api` capability shows "Requires leo ≥ 0.59.0" in place of the rows.
- A field type the app doesn't know is shown read-only, with an "Edit on the web" link when the machine has a reachable web URL.
- Leaving a dirty editor asks to Save, Discard or Cancel. A disconnect keeps the editor and its draft, shows a banner, and reloads and rebases the draft on reconnect.
- When the app goes to the background, drafts are kept in memory. A draft is lost only if iOS kills the app. This is an accepted risk.

## Screens

1. **Machine detail:** the existing machine info, plus a Configuration section with the four rows.
2. **Tasks:** a list with an enabled switch and Run Now on each row (swipe or context menu). Task detail is a form with the schedule and a live cron preview, plus Prompt, History and Log screens. The prompt editor is a `UITextView` with its own Save and conflict handling, and it refuses to save when the task's prompt file has changed underneath it. The log is a bounded tail in a read-only text view.
3. **Templates and Environments:** a list with add, rename, delete and duplicate (duplicate is for templates only). The detail screen is a schema form built from the daemon's field schema. Env entries are key/value rows, and secret rows show "Set" with Replace and Clear.
4. **Service:** status, Restart Daemon, Restart All Agents and Reload Config, plus a log tail. The tail is polled every 2 s only while the screen is visible, and it pauses in the background. A restart is waited out through the drain, with "Waiting for busy agents to pause…" shown meanwhile, under the same wall-clock deadline as on the Mac.

The schema form is a UIKit list, with one cell type per field type (string, int, double, bool, enum, list, map/env, duration, secret, reference). Help text appears as the cell's secondary text.

## Out of scope

- The Defaults, Delegation and Daemon panes on iOS.
- Any iPad-specific layout: iPad uses the same navigation.
- Persisting drafts across app termination.

## Testing

- A TCA `TestStore` test per feature covering dirty state, save, 409 Reload and Overwrite, 422, a reconnect rebase, and the restart wait (with an injected clock).
- A cell test per field type for the schema form.
- iOS snapshot checks of each screen in light and dark, if the iOS target has a snapshot harness. Otherwise, simulator screenshots via xcode-remote.
- A real-device or simulator check against an isolated leo 0.59.0 daemon reached over `/api/v1` with a paired token.
