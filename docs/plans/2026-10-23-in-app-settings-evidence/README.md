# In-app settings: real-daemon evidence (2026-10-23)

Integration-gate run of every settings pane against a real daemon built from
leo PR #295 (`feat/config-json-api`, 18e2d86b). Isolated: scratch `HOME`,
`CFFIXED_USER_HOME` and `TMUX_TMPDIR`, short socket path, foreground
`leo service`, no real agents. Debug app from head 204ec3db7. After each save
the scratch `leo.yaml` was read back to confirm the change landed.

| Screenshot | Pane | Action | Result in leo.yaml / UI |
|---|---|---|---|
| [02-templates-saved.png](02-templates-saved.png) | Templates | Max turns 99 + system prompt edit, Save | `max_turns: 99`, `append_system_prompt` updated |
| [03-tasks-toggled.png](03-tasks-toggled.png) | Tasks | Enabled toggle in the list row | `enabled: true` |
| [04-tasks-run-now.png](04-tasks-run-now.png) | Tasks | Run Now | "Started morning-brief"; run listed in History |
| [05-tasks-prompt-saved.png](05-tasks-prompt-saved.png) | Tasks | Prompt editor, Save | prompt file on disk changed |
| [06-environments-secret-set.png](06-environments-secret-set.png) | Environments | `ANTHROPIC_AUTH_TOKEN` shows "Set", never the value | n/a (read) |
| [07-environments-secret-replaced.png](07-environments-secret-replaced.png) | Environments | Replace the secret, Save | token replaced in the file; row still reads "Set" |
| [08-delegation-cell-edited.png](08-delegation-cell-edited.png) | Delegation | thorough/implement cell: model opus to haiku | `model: haiku`, effort `max` kept |
| [09-defaults-saved.png](09-defaults-saved.png) | Defaults | Max turns 50, Save | `max_turns: 50` |
| [10-daemon-web.png](10-daemon-web.png) | Daemon | Web UI page loads (port/bind not edited) | n/a (read) |
| [11-daemon-hosts-saved.png](11-daemon-hosts-saved.png) | Daemon | Remote hosts: Tmux path, Save | `tmux_path: tmux` |
| [12-service-log-tail.png](12-service-log-tail.png) | Service | Status and live log tail | n/a (read) |
| [13-service-reload.png](13-service-reload.png) | Service | Reload Config | "Configuration reloaded" |
| [14-defaults-conflict.png](14-defaults-conflict.png) | Defaults | External PUT while the form was dirty, then Save | conflict banner (Reload / Overwrite) |
| [15-defaults-overwrite.png](15-defaults-overwrite.png) | Defaults | Overwrite | their `model: haiku` kept, our `max_turns: 6050` applied |
| [16-tasks-history-log.png](16-tasks-history-log.png) | Tasks | History and run log | n/a (read) |

Notes
- Restart Daemon and Restart All Agents were not pressed (no agents to restart; Restart Daemon would drop the scratch daemon).
- The daemon reports `version: "dev"` for a source build; the app's version gating accepted it.
- Window height varies between shots because the restart banner takes space.
