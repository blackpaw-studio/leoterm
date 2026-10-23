# Plan: In-app settings (web UI parity)

Spec: `docs/superpowers/specs/2026-10-23-in-app-settings.md`. If this plan and the spec disagree, the spec wins.
Branch: `feat/in-app-settings` (off `main`). Daemon work lands in the leo repo (`~/.leo/agents/leo`), PR opened, reviewed and merged by the `leo` agent.
Platform: **Mac only.** Every model, the config client, validation, draft and revision logic live in LeoKit, so iOS (UIKit + TCA, web transport) only adds UI. iOS goes on the autopilot backlog at the integration gate.

---

# Part A — Daemon contract (brief for the `leo` agent)

Self-contained. Repo: `~/.leo/agents/leo`. Today the web UI saves config only through HTML form posts (`internal/web`, routes in `web.go:550-660`). Add an operator-only JSON API with identical behavior, served on the unix socket and under `/api/v1`. Security-sensitive (config writes, prompt-file paths, operator auth): review with `review.security`.

## A1. Reuse mechanism: one service, two muxes
- **Extract `web.ConfigService`** (new `internal/web/config_service.go`). It owns what every config write needs today:
  - `configPath`, the shared `*config.Writer`, and the reloader;
  - the two restart flags, moved off `web.Server` (`serviceRestartNeeded`, `agentsRestartNeeded`, `web.go:116-125`);
  - the agent restarter (`RestartAll`), the leo executable for `leo run` / `leo service restart`, the service log path, the history store factory, and the agent-list source used by `schema.OptionSources`.
- **Construct it once in `daemon.Server`.** The daemon already owns `configWriter`, the scheduler, `ReloadConfig`, the agent manager, `leoMCP.Executable()` and `logPath`. Pass it to `web.New` through a new `web.Options.Config` field.
  - The socket routes then work even with `web.enabled: false` (`StartWeb` returns early at `daemon/server.go:436`).
  - The web banners and the socket share one set of restart flags.
- **Every existing HTML handler becomes a thin adapter over a core** on `ConfigService` that returns `(WriteResult, error)`. The JSON handlers are the second adapter. The cores:
  - `ApplySection`: today's `applySection` (`handlers_config.go:175`). It takes `url.Values`, so `schema.Apply`, `schema.ApplyHarnessOptions` and the nested `permissions` / `push` Apply passes stay the only parse path.
  - `Mutate(ifMatch, apply)`: today's `mutateConfig` (`config_lock.go:16`). It serves add, rename, delete, duplicate, hosts, tasks and every delegation write.
  - Prompt get/save, cron describe, delegation preview, task run, history, run log, service restart, log tail, restart-all.
- **One route table, registered twice:** `RegisterConfigRoutes(mux, prefix, wrap)`.
  - Socket: `(mux, "", identity)` in `daemon.New`. The socket is 0600, so its caller is the operator.
  - Web: `(apiMux, "/api/v1", s.requireOperatorToken)`. This accepts the API token or a paired-device token and refuses the agent token. Client tokens never reach `apiMux` (`serveClient`, `web.go:753`).
  - No path clash: the HTML pages use `GET /config/...` on the browser mux, and the socket has only `POST /config/reload` under `/config`.

## A2. Envelope and status codes
- The envelope is the existing `{ok, data, error, code}`.

| Status | `code` | When |
|---|---|---|
| 200 / 201 | — | Read or write OK. 201 for add and duplicate. |
| 202 | — | Service restart, Run Now. |
| 400 | `bad_request` | Malformed JSON, or an unknown key in a body. |
| 404 | `not_found` | Unknown resource or name. `delegation_not_configured` when leo.yaml has no `delegation:` block. |
| 409 | `revision_mismatch` | `If-Match` is stale. `data: {revision: <current>}`. Nothing is written. |
| 422 | `invalid` | Top-level `errors: [{field, message}]`. `field` is the schema key: `name` / `new_name` for names, `harness_options.<key>` for harness options, `permissions.<key>` / `push.<key>` for subsections. `""` is a form-level error. |
| 428 | `revision_required` | A write arrived without `If-Match`. |
| 503 | `config_unavailable` | leo.yaml does not load (existing `CodeConfigUnavailable`). |

- A taken name on add, rename or duplicate is a **422** on `name` / `new_name`, not a 409, so 409 always means a stale revision.

## A3. Revision
- `revision = "sha256:" + hex(sha256(leo.yaml bytes))`.
- Add `config.LoadWithRevision(path) (*Config, string, error)`, which hashes the same bytes it parses, so there is no TOCTOU.
- Every GET except the schema returns `revision` in `data` and as `ETag: "<revision>"`.
- Every JSON write requires `If-Match: <revision>`. Under the config write lock the core does load + hash → compare → mutate → `Validate` → save → reload, and responds with the new revision.
- CLI writes bypass the in-process lock but change the hash, so they surface as 409s.
- The HTML form posts keep their current behavior: they pass `ifMatch == ""`, which means unchecked.

## A4. `GET /config/schema`
Serves the `internal/web/schema` registry, grouped into the resources the web UI edits.

```json
{"schema_version": 1, "name_pattern": "^[A-Za-z0-9._-]+$",
 "resources": [{"key": "templates", "label": "Templates", "kind": "collection", "section": "template",
   "actions": ["add", "rename", "duplicate", "delete"], "harness_options": true, "restart": "agents",
   "fields": [{"key": "workspace", "label": "Workspace", "help": "", "warning": "", "group": "General",
               "advanced": false, "type": "string", "default": null, "constraints": {}, "restart": "agents"}],
   "subsections": [{"key": "permissions", "section": "permissions", "fields": []},
                   {"key": "push", "section": "push_template", "fields": []}]}],
 "harnesses": {"claude": {"fields": []}, "codex": {"fields": []}}}
```

**Resources.** Every schema section maps to a resource.

| Resource (path) | Schema sections | Kind | Actions | Harness options | `restart` |
|---|---|---|---|---|---|
| `defaults` | `defaults` + `push_defaults` (key `push`) | singleton | — | yes | agents |
| `templates` | `template` + `permissions` + `push_template` (key `push`) | collection | add, rename, duplicate (D1), delete | yes | agents |
| `tasks` | `task` | collection | add, delete | yes | none |
| `environments` | `environment` | collection | add, rename, delete | no | agents |
| `web` | `web` | singleton | — | no | service |
| `client` | `client` | singleton | — | no | none |
| `hosts` | `client_host` | collection | add, delete | no | none |
| `delegation` | none (bespoke, A7) | — | — | — | none |

`restart` follows the flag each section sets in `applySection` today: `&s.serviceRestartNeeded` for web, `&s.agentsRestartNeeded` for defaults, templates and environments, and nil for the rest. Each field also carries `restart`, so a future per-field refinement needs no schema change.

**Type mapping.** `jsonType` must have no default branch.

| Registry kind | `type` | Extras |
|---|---|---|
| `KindText` | `string` | |
| `KindTextarea` | `string` | `multiline: true` |
| `KindDatalist` (model) | `string` | `hints_by_harness: {claude: {suggestions: […]}, codex: {placeholder: "e.g. gpt-5.3-codex"}}`, from `ModelSuggestions` / `ModelPlaceholder` |
| `KindCron` | `string` | `format: "cron"` |
| `KindDuration` | `duration` | Go duration syntax |
| `KindNumber` | `int` | `constraints.min` / `max` where Validate enforces them |
| `KindBool` on `bool` | `bool` | |
| `KindBool` on `*bool` (unset = on) | `bool` | `default: true` (push defaults) |
| `KindTriBool` | `bool` | `nullable: true` (null = inherit) |
| `KindSelect`, static source (`harnesses`, `runtimes`, `isolations`) | `enum` | `options: [{value, label}]`, `""` = inherit / none |
| `KindSelect`, config-collection source (`templates`) | `reference` | `references: "templates"`, `empty_label: "none"` |
| `KindCSV` | `list` | JSON array of strings |
| `KindEnvMap` | `map` | JSON object, string → string |
| (new) `Field.Secret` | `secret` | never carries a value (A5) |

Harness `OptionsSchema()` types map the same way:
- `OptionString` → `string`.
- `OptionText` → `string` with `multiline: true`.
- `OptionBool` → `bool` with `nullable: true`.
- `OptionEnum` → `enum`.
- `OptionStringList` → `list`.
- `OptionYAMLMap` → `yaml`. Its value is the YAML text `renderOptionValue` shows the web form, and the daemon parses it exactly as `ApplyHarnessOptions` does.
- A `Source` hint resolves to `enum` options at schema time (`OptionSources.TryFor`). An unresolvable hint becomes a plain `string`.

**New registry attributes**, all optional and filled only where config defines them:
- `Default`: e.g. `web.port` 8370, `web.bind` 127.0.0.1, `task.runtime` oneshot, `task.queue_max` 5.
- `Constraints{Required, Min, Max, Pattern}`: only rules `Validate` or the add handlers already enforce, e.g. `task.schedule` is required.
- `Secret`.

The daemon stays authoritative.

## A5. `GET /config/<resource>[/<name>]`
- **Singleton** (`defaults`, `web`, `client`): `{revision, values, inherited, effective_harness}`.
- **Collection** (`templates`, `tasks`, `environments`, `hosts`): `{revision, items: [{name, values, inherited, effective_harness}]}`, sorted by name, so a list pane needs one call.
- **Item:** `GET /config/<collection>/<name>` → `{revision, name, values, inherited, effective_harness}`.
- **`values`** are keyed by schema field key and use the A4 JSON types:
  - Subsections nest under their yaml key (`permissions`, `push`).
  - `harness_options` holds only the keys set on this scope.
  - An unset int is `null`, matching `renderNumber`. A tribool is `null | true | false`.
  - A secret is `{"set": bool}`. Its value never appears in any response.
- **`inherited`** carries the defaults-cascade placeholders `schema.Values` and `harnessView` compute today (e.g. `model`, `harness`, `harness_options`). It follows the same rule as `buildForm`: present only for the sections that cascade from defaults.

## A6. Writes
- **`PUT /config/<singleton>`, `PUT /config/<collection>/<name>`** with body `{"values": {...}}`:
  - A key that is present replaces the value, and `null` clears it.
  - **A key that is absent keeps its current value** (D2). This lets an older app work with a newer daemon's extra fields, and makes the task enabled toggle a one-key PUT.
  - Implementation: render the current values, overlay the body, convert to `url.Values`, then run the `ApplySection` core. Validation and side effects match the web form exactly, including a harness change with its options in one write.
  - A harness option the effective harness doesn't define → 422 on `harness_options.<key>`.
  - Secrets take `{"<key>": {"replace": "…"}}` or `{"<key>": {"clear": true}}`.
- **`POST /config/<collection>`** adds an item and returns 201 with the item document:
  - templates and environments: `{name}`.
  - tasks: `{name, schedule}`. Schedule is required; `prompt_file` defaults to `prompts/<name>.md` and `enabled` to false, as `handleTaskAdd` does.
  - hosts: `{name}`.
- **`POST /config/<collection>/<name>/rename`** with `{new_name}`, for templates (`config.RenameTemplate`, which also rewrites references and persisted agent records) and environments (`config.RenameEnvironment`).
- **`POST /config/templates/<name>/duplicate`** with `{new_name}` (D1). It is a deep copy under the lock, so `harness_options`, `permissions`, `push` and the excluded legacy keys survive.
- **`DELETE /config/<collection>/<name>`** for templates, tasks, environments and hosts, with the same reference checks as the HTML handlers.
- **Write response:** `{revision, restart_required: {service, agents}, warning?, item?}`.
  - `restart_required` reads the shared flags after the write.
  - `warning` is the `reloadConfigOrWarn` text: saved, but the reload failed.

## A7. Delegation (bespoke; no schema section)
**`GET /config/delegation`** returns:
- `revision`, `configured`, `enabled`, `active_profile`;
- `hide_native_agents: [..]` and `hide_native_agents_is_default`;
- `templates: [{name, model}]`;
- `roles: [{name, use_for, declared}]`;
- `profiles: [{name, description, active, roles: {<role>: {template, model, effort, inherited_model}}}]`;
- `warnings` (`cfg.DelegationWarnings()`);
- `recent_consults` (the last 20 role-routed consult records the page shows).

Effort is free text, because it is validated per harness through `EffortValidator`, so an invalid value comes back as a 422 on `effort`.

Every write below needs `If-Match`:

| Web UI route (form inputs) | JSON route |
|---|---|
| `POST /web/delegation/cell` (profile, role, template, model, effort) | `PUT /config/delegation/profiles/{p}/roles/{r}` `{template, model, effort}`. `template: ""` deletes the cell. |
| `POST /web/delegation/use-for` | `PUT /config/delegation/roles/{r}` `{use_for}` |
| `POST /web/delegation/active` | `PUT /config/delegation/active` `{profile}` |
| `POST /web/delegation/enabled` | `PUT /config/delegation/enabled` `{enabled}` |
| `POST /web/delegation/hide-agents` | `PUT /config/delegation/hide-agents` `{names: [..]}` |
| `GET /web/delegation/preview?profile=` | `GET /config/delegation/preview?profile=` → `{profile, changes: [{role, kind, before, after}], missing: [..]}` |
| `POST /web/delegation/role/add` (name, template) | `POST /config/delegation/roles` `{name, template}` |
| `POST /web/delegation/role/rename` | `POST /config/delegation/roles/{r}/rename` `{new_name}` |
| `POST /web/delegation/role/delete` | `DELETE /config/delegation/roles/{r}` |
| `POST /web/delegation/profile/add` | `POST /config/delegation/profiles` `{name}` |
| `POST /web/delegation/profile/rename` | `POST /config/delegation/profiles/{p}/rename` `{new_name}` |
| `POST /web/delegation/profile/duplicate` | `POST /config/delegation/profiles/{p}/duplicate` `{new_name}` |
| `POST /web/delegation/profile/delete` | `DELETE /config/delegation/profiles/{p}` |

There is no bootstrap route. The web UI can't create a `delegation:` block either (D10). There is no role duplicate either, because the web UI has only profile duplicate (D12).

## A8. Tasks, prompt, cron, service

| Web UI route | JSON route |
|---|---|
| `POST /web/task/{n}/toggle` | `PUT /config/tasks/{n}` `{values: {enabled}}` (partial PUT, A6) |
| `POST /web/task/{n}/run` | `POST /tasks/{n}/run` → 202 `{name, status: "started"}`. The `handleAPITaskRun` core; the socket uses the daemon's own executable. |
| `GET /partials/task/{n}/history` | `GET /tasks/{n}/history?limit=20` → `[history.Entry]`, newest first |
| `GET /partials/task/{n}/log?file=` | `GET /tasks/{n}/log?file=` → `{file, text}`, with the same task/file match check |
| `GET /web/task/{n}/prompt[?prompt_file=]` | `GET /config/tasks/{n}/prompt[?file=]` → `{revision, file, files: [..], content}` |
| `POST /web/task/{n}/prompt` | `PUT /config/tasks/{n}/prompt` `{content}` (D8) |
| `GET /web/cron/preview?expr=` | `GET /cron/preview?expr=` → `{valid, description, error?}` |
| `POST /web/service/restart` | `POST /service/restart` → 202. Spawns `leo service restart --graceful --force` and clears the service flag. |
| `POST /web/agents/restart` (status banner) | `POST /service/restart-agents` → `{restarted: [..], failed: {name: msg}}`. Clears the agents flag on zero failures. The socket's existing `POST /agents/restart` must clear the shared flag too. |
| `GET /web/service/logtail?n=` | `GET /service/log?lines=200` → `{text}`, capped at 1000 lines (D9) |
| `POST /web/config/reload` | `POST /config/reload` (exists on the socket; add it to `/api/v1`, returning `{revision, warning?}`) |
| `GET /service` page + status partial | `GET /service/status` → `{version, pid, started_at, config_path, log_path, restart_required: {service, agents}, processes: [{name, status, started_at, restarts, ephemeral}]}` |

- **Prompt revision.** The prompt has its own revision, `sha256` of the prompt file's bytes (the hash of empty for a missing file). `PUT` sends it as `If-Match`.
- **Prompt writes.** PUT writes only the task's current `prompt_file`, creating it if missing, with `handleTaskPromptSave`'s path rules: relative, inside the workspace, no traversal.
- **Choosing or creating another file** is a task `PUT` of `prompt_file` (D8).

## A9. Capability
- One list, `daemon.Capabilities()`, gains `"config_api"`.
- It is served as:
  - `capabilities` on socket `GET /version` (`handlers_observe.go:74`);
  - the new `GET /api/v1/version` (operator);
  - the hello `features` array, which the app's `LeoDaemonFeatures` already decodes.
- Advertise it only once every route in A4–A8 is live.

## A10. Field errors
- **`schema.Apply` / `ApplyHarnessOptions`:** return `*schema.FieldError{Key, Err}`. `Error()` is unchanged, so the web flashes don't change.
- **`config.Validate`:** a message naming a field of the edited resource maps to that key. The forms are `defaults.<k>`, `templates.<n>.<k>`, `tasks.<n>.<k>`, `environments.<n>`, `web.<k>` and `client.hosts.<n>.<k>`. Anything else (another resource already invalid on disk) becomes form-level `""`.
  - Preferred: `Validate` returns a structured `config.ValidationErrors` with the same `Error()` text.
  - Parsing the path prefixes is acceptable if each mapping has a test.

## A11. Tests (daemon)
- **Per route:** success; 409 (stale `If-Match`, file bytes unchanged); 428; 422 (one invalid value per resource, plus a taken name on add / rename / duplicate); `restart_required` (web → service, template → agents, task → neither); 404.
- **Secret redaction:** use a test-only secret field registered through a registry hook. GET shows `{set}`, replace / clear works, and the value appears in no response body.
- **Parity test `TestConfigAPIRoundTrip`:** cover every resource, every registered field (subsections included) and every harness's `OptionsSchema`. For each, PUT a non-zero sample value for its type, GET it back equal, and see it in `config.Load`.
  - Iterate every `Kind` and `OptionType` constant through `jsonType`. One the schema JSON can't describe fails the test.
- **Route twins:** a table maps every config-mutating web route (`/web/config/*`, `/web/task*`, `/web/template*`, `/web/environment*`, `/web/host*`, `/web/delegation/*`, `/web/service/*`, `/web/agents/restart`) to its JSON route. The test fails when a web route has no row.
- **Socket ≡ web:** the same request on both muxes gives the same body.
- **Golden fixtures for the app:** `go test ./internal/web -run TestConfigAPIGolden -update` writes `internal/web/testdata/configapi/*.json` from a fixture leo.yaml. It covers the schema, every resource GET, delegation and its preview, prompt, history, service status, version, and the 409 / 422 bodies.

## A12. Schema registry vs web UI: gaps and coverage
- **`harness_options`:** excluded from the flat registry, rendered by `harnessform.go`. Covered by `schema.harnesses` + `values.harness_options`.
- **`permissions` and `push` (template), `push` (defaults):** sections of their own, rendered inside their parent form. Covered as `subsections`.
- **`client.hosts`:** excluded, with its own CRUD UI. Covered as the `hosts` collection.
- **Delegation:** no schema section at all. Covered by bespoke A7, including the page's warnings and recent consults.
- **Task prompt files, cron preview, run history and logs, service restart / log / status, restart all agents, config reload, restart banners:** handlers, not schema. Covered by A8.
- **`web.allowed_hosts`, `trusted_proxies`, `public_urls`, `port`, `bind`:** these *are* registered (`SectionWeb`). They need `restart: service`, which the web resource carries.
- **Not in the web UI, so outside parity and given no route:**
  - `chat.*` and `api_clients`. These top-level structs sit outside `AllSections`, so the drift test doesn't see them.
  - `defaults.dispatch.*` (excluded).
  - The legacy `provider` / `permission_mode` / `allowed_tools` … keys (excluded; `Validate` rejects them).
- **Secrets:** no registered field is a secret today. Tokens live in state files, not leo.yaml. The `secret` type ships for future fields, and env maps stay plain, as in the web UI (D3).

---

# Part B — App (Mac; logic in LeoKit)

## B0. Conventions
- **Commands:**
  - **LK(S):** `cd Packages/LeoKit && swift test --filter <S>`.
  - **LKL:** `cd Packages/LeoKit && swiftlint lint --strict`.
  - **MB:** from `macos/`: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`.
  - **MT(S…):** from `macos/`: `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer /opt/homebrew/bin/timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<S> …`. When the console is locked, use the injected-bundle runner in `LEO.md`.
  - **ML:** `cd macos && swiftlint lint --strict --quiet`.
  - **SNAP:** `LEO_SETTINGS_SNAPSHOTS=<scratch dir>` + MT(LeoSettingsSnapshots). It is an env-gated suite that writes light and dark PNGs, modeled on `LeoChatQuestionsCardSnapshots`. Inspect the PNGs at native pixels.
- **Worktree prereq:** `ln -s ~/.leo/agents/leoterm/macos/GhosttyKit.xcframework macos/GhosttyKit.xcframework && ln -s ~/.leo/agents/leoterm/zig-out zig-out`. No `src/` changes.
- **Test discipline:** each step is test-first (write it, watch it fail, implement). View layout and styling are TDD-exempt and verified by SNAP. Every slice gets a fresh-context `review` before merge, with the bar set at P0/P1 and anything a realistic edit can hit.
- **Building ahead of the daemon PR.** Every slice can be built and tested before Part A merges:
  1. **Fixtures:** `Packages/LeoKit/Tests/LeoKitTests/Fixtures/config/*.json`, hand-written from Part A's shapes, with a `README.md` recording provenance. When the leo PR has its A11 golden files, copy them over and keep the same names. Decoding tests then prove the real shapes.
  2. **`LeoFakeConfigClient`** (LeoKit, public): an in-memory actor with real revision semantics. Every write bumps the revision, a stale `If-Match` gets a 409, and 422 / `restart_required` / failures can be scripted. It drives every Mac model test.
  3. **DEBUG fixture launch:** `LEO_SETTINGS_FIXTURE=1` binds the fake client for This Mac, modeled on `LeoMachinesFixture`, so SNAP and screenshots need no daemon.
  4. **Waits for a daemon build:** only the real-daemon check. Use the isolated leo daemon recipe: `-c`, a scratch cwd, `TMUX_TMPDIR` and a short socket path.

## Slice 0 — Foundation
**0.1 Request headers**
- Files: `LeoKit/Daemon/LeoHTTP.swift` (`LeoHTTPRequest.headers: [String: String] = [:]`, written by `serialized()`, rejecting CR/LF in names and values), `LeoKit/Remote/LeoHTTPSTransport.swift` (`urlRequest` applies them).
- Failing tests: `LeoHTTPRequestHeaderTests.serializesIfMatch`, `.rejectsHeaderInjection`, `.httpsRequestCarriesHeaders`.
- Verify: LK(LeoHTTPRequestHeaderTests), LKL.

**0.2 Schema and value models**
- New files in `LeoKit/Config/`:
  - `LeoConfigSchema.swift`: resources, fields, subsections, harnesses, constraints, options, hints.
  - `LeoConfigFieldType`: `string`, `int`, `bool`, `enum`, `list`, `map`, `duration`, `secret`, `reference`, `yaml`, and `.unknown(String)`, plus `multiline`, `format` and `nullable`.
  - `LeoConfigValue.swift`: null / bool / int / string / list / map / object / secret(isSet).
  - `LeoConfigDocument.swift`: name, values, inherited, effective harness, revision.
- Fixtures:
  - `schema.json`, `defaults.json`, `templates.json`, `template_coder.json`, `tasks.json`, `environments.json`;
  - `web.json`, `client.json`, `hosts.json`, `delegation.json`, `delegation_preview.json`;
  - `prompt.json`, `history.json`, `service_status.json`, `version.json`, `error_409.json`, `error_422.json`.
- Failing tests:
  - `LeoConfigSchemaDecodingTests`: every fixture decodes; an unknown type decodes as `.unknown` and does not fail; unknown keys are ignored.
  - `LeoConfigValueCodingTests`: a null int vs 0, list and map round-trips, a secret never encodes a value.
- Verify: LK(LeoConfigSchemaDecodingTests, LeoConfigValueCodingTests).

**0.3 Config client, both transports**
- Files:
  - `LeoKit/Config/LeoConfigClient.swift` (protocol).
  - `LeoConfigHTTPClient.swift`: one implementation over `prefix` + a send closure. It builds routes with `LeoSocketDaemonClient.pathSegment`.
  - `LeoConfigError.swift`: `.conflict(currentRevision)`, `.invalid([LeoConfigFieldError])`, `.revisionRequired`, `.unsupported`, and the rest via `LeoDaemonError`.
  - `LeoSocketDaemonClient.configClient()` (prefix `""`) and `LeoWebDaemonClient.configClient()` (prefix `/api/v1`).
  - `LeoDaemonClient` gains `func configClient() -> (any LeoConfigClient)?`, defaulting to nil, so fakes compile.
  - `versionInfo()` → `{version, capabilities}`.
  - `LeoConfigAPI.capability = "config_api"` and `minimumVersion`, set at the integration gate.
- Failing test: `LeoConfigClientTests`, parameterized over both prefixes with a recording transport.
  - Every call's method, path and `If-Match`.
  - A partial-PUT body carries only the changed keys; secret replace / clear.
  - Error mapping: 409 → conflict with revision, 422 → field errors, 428, 404 on `/config/schema` → `.unsupported`.
- Verify: LK(LeoConfigClientTests), LKL.

**0.4 Draft, validator, revision tracker** (the logic iOS reuses)
- `LeoConfigDraft.swift`: value type.
  - `set(key, value)`, `isDirty` (per field), `revert`, `canSave` (dirty and no errors), `applying(serverErrors)`, `rebased(onto:)` (for Reload).
  - `patch` holds the changed keys only, so Overwrite after a 409 resends just the user's edits.
- `LeoConfigValidator.swift`: required, min / max, pattern, enum membership, reference existence, Go duration syntax, map keys non-empty with no `=`, and the name pattern.
- `LeoConfigRevision.swift`: per machine. After a write sent with revision R that comes back as R′, every pane holding R adopts R′, because the change was the app's own. Any other mismatch stays a conflict.
- Failing tests: `LeoConfigDraftTests`, `LeoConfigValidatorTests`, `LeoConfigRevisionTests`.
- Verify: LK(LeoConfigDraftTests, LeoConfigValidatorTests, LeoConfigRevisionTests).

**0.5 Fake client:** `LeoKit/Config/LeoFakeConfigClient.swift`.
- Failing test: `LeoFakeConfigClientTests` (a stale write gets a 409; a write bumps the revision; add / rename / duplicate / delete; scripted 422).
- Verify: LK(LeoFakeConfigClientTests).

**0.6 Schema-form renderer**
- **LeoKit `LeoConfigFormLayout.swift`:** a pure function of (resource, harness schemas, document, draft) that returns ordered sections:
  - the non-advanced groups in registry order;
  - "Harness options" for the draft's *current* harness value (it switches without a round trip);
  - the subsections;
  - "Advanced", last.
- **Each row gets a `LeoConfigControl`:**
  - `text` (placeholder `inherit: x` or the default), `multiline`, `number`, `toggle`, `triState` (inherit / on / off), `picker`, `referencePicker` (names from the referenced collection plus "None");
  - `list` (rows with + / −), `keyValue` (two columns with + / −), `duration`, `cron` (with a live preview), `yaml` (monospaced), `secret` (Set / Not set, Replace…, Clear), `suggestions` (text field + menu);
  - `readOnlyUnknown(webLink)`.
- **`LeoConfigWebLink`** builds the "Edit in the web UI" URL (D4).
- **Mac files** in `macos/Sources/Features/Leo/Settings/Config/`: `LeoSchemaForm.swift` (`Form` with `.formStyle(.grouped)`, help as secondary text, warning with ⚠ symbol, inline errors), `LeoSchemaFieldRow.swift`, `LeoListEditor.swift`, `LeoKeyValueEditor.swift`, `LeoSecretField.swift`, `LeoCronField.swift`.
- **Failing tests:**
  - `LeoConfigFormLayoutTests`: one test per field type → control; unknown type → read-only with link; a harness change swaps the options section; advanced comes last; subsections render.
  - `LeoConfigWebLinkTests`.
- **Verify:** LK(LeoConfigFormLayoutTests, LeoConfigWebLinkTests); MB; SNAP `allFieldTypes` (light and dark).

**0.7 Settings toolbar machine picker**
- **`Settings/LeoSettingsTargetModel.swift`** (@MainActor, injected):
  - It takes the registry, `LeoMachineClientResolving` and a selected-host provider, `{ sidebar.selectedRow?.host ?? .local }`.
  - `selectedHost` defaults to the selected agent's machine when the window opens.
  - `availability` is `.loading`, `.ready(client)`, `.disconnected(status)` or `.tooOld(version)`. `.tooOld` means the daemon lacks `config_api`.
  - `requestSwitch(to:)` asks first when any registered pane is dirty. A switch bumps a generation, which reloads every pane and drops stale replies.
  - Switching tabs away from a dirty pane asks first too (the spec's "closing a pane").
  - `reconnect()` calls `registry.reconnect`.
- **`Settings/LeoSettingsPaneState.swift`:** the disconnected view (Machines-style status + Reconnect) and the too-old notice ("Requires leo ≥ X"). A half form is never shown.
- **`LeoSettingsWindowController.swift`:**
  - An `NSToolbar` with one item hosting the SwiftUI picker. The Mac deployment target is 13.0, and `sceneBridgingOptions` needs macOS 14.
  - `windowShouldClose` checks the Machines model and every config pane.
  - The init takes the clients and the selection provider.
  - `LeoRuntime.settingsWindow` (`LeoRuntime.swift:35`) passes them in.
- **Failing test:** `LeoSettingsTargetModelTests`:
  - defaults to the selected agent's machine, else This Mac;
  - a disconnected machine shows status and Reconnect calls the registry;
  - an old daemon gives `.tooOld`;
  - a dirty pane makes a machine switch or a tab switch ask;
  - a switch reloads and drops the old machine's late reply.
- **Verify:** MB, MT(LeoSettingsTargetModelTests, LeoMachinesSettingsModelTests), ML.

## Slice 1 — Templates
**1.1 Generic collection pane**
- **`Settings/Config/LeoConfigCollectionModel.swift`:** list, selection, draft, and Save / Revert.
  - add / rename / duplicate / delete, offered only for the actions the schema lists;
  - a 409 sets `.conflict` with Reload (rebase) or Overwrite (resend the patch with the current revision);
  - a 422 shows inline;
  - `restart_required` raises a prompt;
  - leaving an item with unsaved edits asks first.
- **Views:**
  - `LeoConfigCollectionView.swift`: list with + / − and an action menu; the detail is `LeoSchemaForm` with a Save / Revert bar.
  - `LeoRestartPrompt.swift`: Restart Daemon / Restart All Agents, each confirming and naming the machine.
- **Failing test:** `LeoConfigCollectionModelTests`, against the fake:
  - dirty after an edit; Save sends only the changed keys with the revision; Save is disabled when invalid;
  - a 409 offers Reload and Overwrite; a 422 lands on its field;
  - delete confirms and names the item; rename keeps the selection;
  - the actions come from the schema; agents restart → prompt.

**1.2 Templates tab:** `LeoTemplatesSettingsView.swift` (thin) plus a tab in the `LeoSettingsView` `TabView`.
- **Verify:** MB, MT(LeoConfigCollectionModelTests), SNAP `templates`.
- **Once a daemon build exists, the spec's real-app check:** edit a template on a remote scratch machine, then confirm the change in its leo.yaml and in its web UI.

## Slice 2 — Tasks
- **LeoKit `LeoCronPreviewer.swift`:** debounced at 400 ms with an injected clock, fetching only the latest expression and returning valid or error. `LeoTaskHistory` decoding.
- **Mac:** `LeoTasksSettingsModel` builds on the collection model and adds:
  - the list's enabled toggle (partial PUT `{enabled}`, rolled back on failure) and Run Now (202 → "Started");
  - history newest first, and the selected run's log, both read-only;
  - the prompt editor (own revision, dirty state and Save; another or a new file = task PUT `prompt_file`, then prompt GET);
  - the Add sheet (name + required schedule).
- **Files:** `LeoTasksSettingsView.swift`, `LeoTaskPromptEditor.swift`, `LeoTaskHistoryView.swift`.
- **Failing tests:**
  - `LeoCronPreviewerTests` (fake clock, no sleeps).
  - `LeoTasksSettingsModelTests`: toggle, run, history, a prompt 409, switching the prompt file.
- **Verify:** LK(LeoCronPreviewerTests), MB, MT(LeoTasksSettingsModelTests), SNAP `tasks`.

## Slice 3 — Environments
- The collection model on `environments` (add, rename, delete), with the key/value editor for `env`.
- **Failing test:** `LeoEnvironmentsSettingsTests`:
  - a removed key is absent from the PUT `env` map (map replace);
  - rename re-selects;
  - a save raises the agents-restart prompt.
- **Verify:** MB, MT(LeoEnvironmentsSettingsTests), SNAP `environments`.

## Slice 4 — Delegation
- **LeoKit `LeoDelegationModels.swift`:** decoding plus delegation routes on `LeoConfigHTTPClient`.
- **LeoKit `LeoDelegationMatrix.swift`:** pure. Roles × profiles, cell lookup, undeclared roles, inherited model.
- **Mac `LeoDelegationSettingsModel` + `LeoDelegationSettingsView`:**
  - a `Grid` matrix whose cell popover edits template / model / effort with Save and Cancel;
  - the active profile picker, where Make Active shows the preview (changes and missing roles) and then confirms;
  - the enabled toggle and the hide-agents token field;
  - role / profile add, rename, duplicate and delete menus; deleting names the profiles affected;
  - warnings and recent consults, read-only;
  - "Delegation isn't configured on <machine>" when `configured: false`.
- **Failing tests:**
  - `LeoDelegationMatrixTests`.
  - `LeoConfigClientTests`: the delegation route table.
  - `LeoDelegationSettingsModelTests`: a cell save sends PUT + revision; an empty template deletes the cell; activate goes preview → PUT; a 409 offers Reload.
- **Verify:** LK(LeoDelegationMatrixTests, LeoConfigClientTests), MB, MT(LeoDelegationSettingsModelTests), SNAP `delegation`.

## Slice 5 — Defaults
- `LeoConfigSingletonModel` (load, draft, Save / Revert, conflict, errors, restart prompt) and the Defaults pane (harness options + `push` subsection).
- **Failing test:** `LeoConfigSingletonModelTests`.
- **Verify:** MB, MT(LeoConfigSingletonModelTests), SNAP `defaults`.

## Slice 6 — Daemon
- One pane with:
  - the Web UI form (`web` singleton), showing its lockout warnings;
  - the Remote client form (`client` singleton), whose `default_host` picker lists the hosts;
  - the Remote hosts list and detail (`hosts` collection: add, delete).
- A web save raises Restart Daemon. The app itself reaches the daemon over the socket, so a port or bind change can't lock it out.
- **Failing test:** `LeoDaemonSettingsModelTests`:
  - a web save sets service restart and shows the action;
  - host add / delete;
  - the `default_host` choices track the hosts.
- **Verify:** MB, MT(LeoDaemonSettingsModelTests), SNAP `daemon`.

## Slice 7 — Service
- **`LeoServiceSettingsModel`:**
  - status (`/service/status`);
  - Restart, confirmed: "Restart leo on <machine>? Running agents keep their tmux sessions." It shows Restarting… until the status reports a new pid or start time, while the machine reconnects through its registry backoff;
  - Restart All Agents, confirmed, with a restarted / failed summary;
  - Reload Config (D6);
  - a log tail that polls `/service/log` every 2 s only while visible and not paused (injected clock), with Pause and Copy (injected pasteboard writer).
- **LeoKit:** `LeoServiceStatus` decoding.
- **Failing test:** `LeoServiceSettingsModelTests`:
  - polls while visible and stops when hidden or paused;
  - restarts confirm first;
  - Copy writes the shown text;
  - the restart-all summary.
- **Verify:** LK(LeoConfigSchemaDecodingTests), MB, MT(LeoServiceSettingsModelTests), SNAP `service`.

## Integration gate
1. Replace the hand-written fixtures with the leo PR's golden files. Set `LeoConfigAPI.minimumVersion` to its release.
2. Check the host load first. Then run the full LeoKit `swift test`, MT(GhosttyTests), LKL and ML.
3. SNAP every pane in light and dark, inspected at native pixels.
4. Real app against an isolated daemon on a remote scratch machine:
   - edit a template, then check that host's leo.yaml and its web UI;
   - force a stale save (edit leo.yaml by CLI) → Reload / Overwrite;
   - an old daemon → notice;
   - a disconnected machine → Reconnect;
   - Restart → reconnects.
5. Queue the iOS half with the `feature` skill. It reuses LeoKit `Config/` over `LeoWebDaemonClient.configClient()`. What differs on iOS: navigation-bar machine switcher, UIKit + TCA forms, no hover or popover matrix (push to a cell editor), and the log tail paused in the background.

## Web UI agent actions vs the app's sidebar
- The web Agents page offers Spawn (template, repo, environments), Rename, Set environments, Start, Stop and Delete.
- The app already has every one of them: the spawn sheet, and the row menu's Rename…, Set Environments, Start, Stop and Delete….
- The web `send` / `message` / `interrupt` / `compact` / `clear` routes are agent-MCP routes with no web UI control. The app already offers Message, Interrupt, Compact and Clear in the control bar and the Agents menu.
- Restart All Agents is a web status-banner action. The spec places it in the Service pane.
- **So nothing is added to the sidebar's agent menu.**

## Decisions the spec didn't settle (recommendations; the orchestrator approves or raises)
- **D1 Template duplicate.** The spec wants it, but the web UI has none. Add a daemon `POST …/duplicate`; a client-side copy would drop the excluded keys.
- **D2 PUT semantics.** A present key replaces, `null` clears, and an absent key keeps its value. This tolerates version skew, and Overwrite then resends only the user's edits.
- **D3 Env values stay unredacted,** as in the web UI. `secret` ships with no current fields.
- **D4 The "Edit in the web UI" link** goes to the machine's `web.public_urls[0]`, else its non-loopback bind and port, else no link (text only). A tunnelled machine's loopback web UI isn't reachable.
- **D5 One capability, `config_api`,** on `/version` (socket and the new `/api/v1/version`) and in the hello features.
- **D6 Reload Config.** It is on the web Settings and Service pages but missing from the spec's panes. Put it in the Service pane.
- **D7 Delegation warnings and recent consults** (on the web page, not in the spec) are shown read-only in the Delegation pane.
- **D8 Prompt file.** Pick or create a file through the task's `prompt_file` field; the prompt PUT writes only the current file.
- **D9 Log tail.** Poll `lines=200` every 2 s; no streaming route.
- **D10 Delegation bootstrap.** None, as in the web UI; show "isn't configured".
- **D11 Restart flags** move into the shared `ConfigService`, so the socket, the web banners and the app agree.
- **D12 Role duplicate.** The spec lists "role/profile … duplicate", but the web UI duplicates profiles only. Ship profile duplicate only; a role duplicate (copy one role's cells under a new name) would be a new daemon route.
