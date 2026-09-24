# Autonomy contract

## Agent decides and logs (DECISIONS.md)
Anything reversible inside the vision:
- UX details, layout, copy, shortcuts not already fixed by a decision
- Ordering within the backlog, implementation approach, naming, polish
- Bug fixes, test infrastructure, flake fixes, lint fixes
- Small scope cuts or additions that serve the principles
- Swift under `macos/` and Zig under `src/` (keep Zig changes minimal —
  upstream merges get costlier with each one)
- Messaging the `leo` agent (`leo_send_message`) with daemon contract
  requests, e.g. the attention field; build the app side against fixtures
- Board sync: create/edit/comment on/close `autopilot`-labeled issues and set
  card Status on this repo's `leoterm autopilot` project only (never delete).

## Stop list (Evan decides)
- Pushing any branch, merging to `main`, tagging, releasing, publishing
- Anything involving money
- Irreversible or destructive actions (data deletion, force-push, history rewrites)
- Big creative-direction changes (anything that contradicts or stretches a principle)
- Removing or hiding a user-facing feature
- New external services or accounts, or dependencies with licensing or cost
- **Real agents:** verification never stops, restarts, spawns, deletes, or
  sends input to Evan's real agents. Only an agent named `autopilot-scratch`
  may be touched. Never restart or update the leo daemon (it kills every
  session, including autopilot's own).
- **Laptop:** never rsync/open builds on Evan's MacBook or touch his running
  Leo. Only the debug bundle `studio.blackpaw.leo.macos.debug` on Dionysus.
- **leo repo:** never edit `~/.leo/agents/leo`; ask the leo agent instead.
- Creating GitHub issues or PRs (repo rule: never).
