# leo 0.27.0 daemon/CLI contract (as consumed by Leo v2)

Derived from `~/.leo/agents/leo` source on 2026-09-15. Re-derive when leo bumps. File:line refs are into that repo.

## Unix-socket API

- Transport: HTTP/1.1 over `~/.leo/state/leo.sock`; socket mode `0600` [daemon/server.go:205-238]. No auth.
- Success envelope: `{ok:true,data?:...}`. Failure: `{ok:false,error:string,code?:string,matches?:string[]}` [daemon/types.go:5-15].
- Generic failures: malformed/missing input `400`; unresolved name `404` (`not_found`); ambiguous name `409` (`ambiguous`, plus `matches`); manager unavailable `503`; unexpected `500` [daemon/handlers_agents.go:20-35,550-581].

| Route | Request | Successful `data` |
|---|---|---|
| `POST /agents/spawn` | JSON: `template` or `from_agent` required; optional `repo`, `name`, `branch`, `base`, `prompt`, `env`, `idle_suspend` | `Agent` [handlers_agents.go:40-78; types.go:54-79] |
| `GET /agents/list` | none | `Agent[]` [handlers_agents.go:80-93] |
| `GET /agents/resolve?q=` | query `q` required | `{name,session,repo?}` [handlers_agents.go:411-438] |
| `POST /agents/restart` | none; restarts all live agents | `{restarted:string[],skipped:string[],failed?:{name:string}}` |
| `GET /agents/stale` | none | `StaleAgent[]` |
| `POST /agents/{name}/stop` | optional `{wake_on_message?:bool}` | no `data`; `200` [handlers_agents.go:95-127] |
| `POST /agents/{name}/start` | none | no `data`; `200` |
| `POST /agents/{name}/reset` | none | no `data`; `200` |
| `POST /agents/{name}/restart` | none | canonical `Agent` |
| `POST /agents/{name}/set-template?template=` | **query** `template` required; no JSON body | `SwitchResult` [handlers_agents.go:206-242] |
| `DELETE /agents/{name}` | optional `{force?:bool,delete_branch?:bool}` | no `data`; `200` [handlers_agents.go:467-498] |
| `GET /agents/{name}/delete-plan` | none | `{name,has_worktree,branch?,worktree_path?}` |
| `POST /agents/{name}/rename` | `{new_name}` required | updated `Agent`; `409` collision, `400` unchanged/invalid |
| `GET /agents/{name}/logs?lines=N` | `lines` optional, default 200 | `{output:string}` |
| `GET /agents/{name}/session` | none | `{session,name,stopped?}` |
| `GET /agents/{name}/attach-spec` | none | `{name,harness,tmux_session?}` |

- `{name}` accepts canonical names and unambiguous shorthands; percent-encode as one path segment.
- Stable error codes: `not_found`, `ambiguous`, `worktree_dirty`, `branch_checked_out`, `branch_not_merged`, `branch_not_found`, `agent_still_running`, `not_worktree_agent`, `worktree_requires_slash`, `source_agent_not_found`, `source_not_git_repo`, `agent_stopped`, `agent_not_stopped`, `agent_already_running`, `agent_not_running` [types.go:17-33].

## `Agent` record

Fields: `name` (required); `template?`, `repo?`, `workspace?`, `branch?`, `canonical_path?`, `status?`, `started_at?` (RFC3339), `restarts?` (int), `stopped_reason?`, `wake_on_message?` (bool). Every field except `name` is `omitempty` [agent/manager.go:175-199]. **No `env` field.** Dormant records serialize `status:"stopped"`. Status values: `starting`, `running`, `stopped`.

## Observability TCP API

- leo.yaml: `web.enabled` (bool, default false — missing `web:` means disabled), `web.port` (default 8370), `web.bind` (default 127.0.0.1) [config/config.go:163-190].
- Token: `~/.leo/state/api.token`, 64 hex chars; `Authorization: Bearer <token>`.
- `GET /api/v1/state` → `{ok:true,data:{version,server_time,leo_version,agents,tasks,recent_runs,recent_messages}}`. Agent entries include `model`, `harness`, `status`, `activity`, `restarts`, `wake_on_message`, `started_at`, `last_activity_at?`, `current_action` [observe/snapshot.go:56-83].
- Activity values: `working`, `idle`, `unknown`; `current_action` = `{kind:"pane",detail}`.
- `GET /api/v1/events` raw SSE. First event `hello` `{seq,at,version,server_time}`. Events: `agent_spawned:{seq,at,agent:<Agent>}`; `agent_state_changed:{seq,at,agent:string,status,restarts,wake_on_message}`; `agent_activity:{seq,at,agent:string,activity,current_action}`; `agent_stopped:{seq,at,agent:string,wake_on_message}`; `task_run_*:{seq,at,run}`; `agent_message:{seq,at,from?,to}` [observe/event.go:9-29,70-131].
- Heartbeat: SSE comment `: ping` every 20 s. Slow subscribers may be dropped; on a `seq` gap, refetch `/state`.
- `client.hosts.<name>` keys: `ssh`, `ssh_args`, `leo_path`, `tmux_path`. **No per-host observability URL.**

## CLI

- `leo template list --json` → sorted `[{name,model?,agent?,workspace?}]`.
- `leo host list --json` → local entry (`name:"localhost"`, `local:true`) plus sorted remotes, each `{name,ssh?,default,local}`.
- `leo host forward <name> --json` → one line `{socket,host,pid}`; `pid:0` when reusing a healthy forward. SIGTERM tears it down.
- `leo agent attach <name>` supports `--host <name>` and `--cc`.
- `leo agent logs <name>` supports `--host`, `-n|--lines` (default 200), `-f|--follow` (tails tmux).

## Legacy (`legacy/grid`) Swift porting notes

- `LeoSSEParser.swift`: port as-is.
- `LeoModels.swift`: remove `env`; add `branch`, `canonical_path`, `restarts`, `stopped_reason`, `wake_on_message`; template model includes `model/agent/workspace`.
- `LeoSocketClient.swift`: add all lifecycle routes; `set-template` is query-based; optional request bodies.
- `LeoActivityClient.swift`: decode exact event payloads (`agent` is a string in state/activity/stopped, an object in `agent_spawned`).
- `LeoObserveConfig.swift`: missing `web:`/`enabled` ⇒ disabled.
- `LeoHost.swift`/`LeoCLI.swift`: honour configured `leo_path`/`tmux_path`; don't hardcode `~/.local/bin/leo`.

## Proposed for leo v0.29.0 — daemon-owned hosts (agreed with the leo agent 2026-09-16, pending Evan's approval of leo's spec)

Unix socket, existing envelope, no auth. All hosts must run ≥ v0.29.0 to emit events; older remotes proxy agent routes but produce no activity (host `/state` falls back to polling `/agents/list`).
- `GET /hosts` → `[{name, local, default, ssh?, state: local|connecting|connected|disconnected|error, error?, code?, connected_at?}]`; `localhost` always present with `state:"local"`.
- `POST /hosts/{name}/connect` (idempotent; returns the row; starts the forward), `POST /hosts/{name}/disconnect`. Daemon ssh uses `BatchMode=yes`; failure codes: `ssh_auth_required`, `ssh_host_key_unknown`, `ssh_unreachable`, `ssh_failed`, each with the stderr tail in `error`. Lazy connect on first proxied call; `client.hosts.<name>.autoconnect: true` connects at daemon start. Reconnect backoff 1–30 s.
- Proxy, unchanged semantics + status passthrough: `/hosts/{name}/agents/list`, `/hosts/{name}/agents/spawn`, `/hosts/{name}/agents/{agent}/{start|stop|restart|reset|set-template|rename|logs|session|attach-spec|delete-plan}`, `DELETE /hosts/{name}/agents/{agent}`, `GET /hosts/{name}/templates` (and new local `GET /templates`). `/hosts/localhost/...` routes in-process. Connection problems → `503 {code:"host_unavailable", error}`.
- `GET /events` and `GET /state` accept `?scope=local` (local-only projection; used hub-to-hub to avoid loops). The GUI uses the default merged scope. Every event carries `host`, including localhost's own.
- `GET /events` (SSE): `hello` first; same event names/payloads as `/api/v1/events` with `host` added to every payload; plus `host_state_changed {host, state, error?, code?}`; `: ping` every 20 s. `GET /state`: same agents shape as `/api/v1/state.data.agents` with `host` per row, merged across localhost and every connected host.
- Envelope everywhere except the SSE stream (pinned in leo spec commit 9310658): `GET /hosts` → `{ok:true,data:[...]}`; `GET /state` → `{ok:true,data:{agents:[...]}}`; `GET /templates` → `{ok:true,data:[...]}`; `GET /health` → `{ok:true,data:{version}}` (today's bare `{ok:true}` stays compatible ⇒ missing `data.version` means < 0.29); `GET /version` → `{ok:true,data:{version}}`; unknown host `404 {ok:false,code:"host_unknown",error}`; proxied `/hosts/{name}/...` responses are the remote's envelope + status passed through unchanged.
- CLI: `leo host forward` retired (no shim); `leo host list|connect|disconnect` talk to the daemon. `leo agent attach --host <name> -- <agent>` reuses the hub's ControlPath (no re-auth). `--` confirmed honoured on `agent attach` and `agent logs`.
