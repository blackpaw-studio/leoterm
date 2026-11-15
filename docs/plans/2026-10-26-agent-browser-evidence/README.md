# Agent Browser E2E evidence (2026-10-26)

Setup: isolated leo v0.62.0 daemon on Dionysus (own config, `HOME`, `TMUX_TMPDIR`, web port 18370), scratch agents
`e2e-claude` / `e2e-codex` / `e2e-opencode` in a scratch Vite app (`localhost:5173`), debug Leo app (HEAD 0af60e4aa)
on the laptop with a machine "Dionysus-e2e" over ssh to the isolated socket. Agent-side evidence only: no laptop
screen-capture path exists from the build host (ssh has no window-server session).

| Criterion | Result | Evidence |
|---|---|---|
| 1 never-registered baseline | pass | `c1-before-app-tools-*.json` (28 tools, none `browser_*`/`leo_app_*`; `ever_registered:false`) |
| 1 claude native mid-session | pass | `c1-claude-native-tools-midsession.txt` |
| 1 opencode native mid-session | pass | `c1-opencode-native-tools-midsession.txt` |
| 1 codex fallback | pass after ONE restart (as the plan resolved) | `c1-codex-no-leo_app-before-restart.txt`, `c2-codex-leo_app_call-pane.txt` |
| 2 claude navigate/snapshot/click/type | pass | `c2-claude-agent-pane.txt`, `c2-c5-claude-direct-transcript.md`, `c2-home-after-click-and-submit.png` |
| 2 codex / opencode core | pass | `c2-codex-leo_app_call-pane.txt`, `c2-opencode-native-pane.txt` |
| 3 takeover / give back | pass (run by orchestrator with `drive.py`): click → `user_has_control`, after Give back click ok | `c3-takeover-transcript.md`, `c3-user-has-control.png`, `c3-after-give-back.png` |
| 4 handoff | pass: `browser_handoff("Log in please")` blocked 38.8 s, returned `done` after Evan pressed Done | `c4-handoff-transcript.md`, `c4-after-handoff.png` |
| 5 two tabs, `_blank` | pass | `c2-c5-claude-direct-transcript.md`, `c5-*.png` |
| 6 quit app | pass | `c6-quit-transcript.md`, `c6-claude-agent-pane-after-quit.txt`, `c6-recover-transcript.md` |

`mcp-probe.py` / `drive.py` speak MCP over stdio to `leo mcp-server` with an agent's env and its harness `clientInfo.name`.

Notes:
- The tested app is a build of HEAD 0af60e4aa; later commits (`c8517bd9f`, `d2f6c1b36`) are lint and test-gating changes not in the tested binary.
- `browser_navigate` on an agent with no tabs returns `no_such_tab` ("call browser_tab_new"); agents recover on their own.
- Agents spawned while the daemon's web port was disabled keep the default `LEO_WEB_PORT` (8370, production's port); the E2E agents were respawned with 18370.
