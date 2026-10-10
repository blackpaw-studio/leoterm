# Contract change: supervised claude agents hold `working` while background tasks run (B-051 follow-up)

Problem (trace 2026-10-08, daemon 0.41.0, autopilot-scratch): a turn that starts `Bash run_in_background` and
ends gets `attention.state=finished` at turn end (17:37:47.143, rev 5) although the shell runs until 17:39:15;
the wake turn then gives working (17:39:16, rev 6) -> finished (17:39:17, rev 7). Cause: bridgefeed.go
(turn.complete handler) calls AttentionStore.AdvanceBridge(finished) without reading ev.Pending; only
dispatch runs (consult) honour `pending`. The mod already sends pending.tasks from the Stop hook's background_tasks.

Change (daemon only; app needs none: it mirrors attention.state):
1. A turn.complete whose pending.tasks is non-empty holds working exactly like outstanding subagents/dispatches:
   the finished is held as working; attention.outstanding gains additive `tasks = sum(pending.tasks)`.
2. The hold drops at the next turn.start (the task's wake turn or a user prompt), session.end, interrupt or
   stop; that turn's own turn.complete then decides again (finished, or held again if tasks remain).
3. pending.wakeups (session crons) never hold: waiting on a timer is idle.
4. Pending is per turn.complete, never carried over (matches the mod's "earlier Stop never rides a later turn").

Open choice for Evan: never-ending tasks (dev servers, watchers) would show Working indefinitely.
Pick: hold them (live work, honest to "working"); alternative: exclude by task type (e.g. `monitor`).
Risk to cover in daemon tests: a background task that never wakes the session would never release
the hold on its own (release = next turn.start, interrupt, stop, or session end).
