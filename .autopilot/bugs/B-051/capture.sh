#!/bin/bash
# usage: capture.sh <scenario>  -- runs until <scenario>.stop exists
D="$(cd "$(dirname "$0")" && pwd)"; N="$1"; S=~/.leo/state/leo.sock
rm -f "$D/$N.stop"
( curl -sN --max-time ${CAP_MAX:-900} --unix-socket $S http://leo/events | python3 "$D/ts.py" > "$D/$N.events.raw" ) &
EP=$!
(
 while [ ! -f "$D/$N.stop" ]; do
  curl -s --max-time 3 --unix-socket $S http://leo/state | jq -c '.data as $d | {agent: ($d.agents[]|select(.name=="autopilot-scratch")|{status,activity,bridge,attention,current_action}), dispatches: [$d.dispatches[]?|select(.caller_agent=="autopilot-scratch")|{id,status,role,parent_dispatch_id}]}' 2>/dev/null | python3 "$D/ts.py"
  sleep 1
 done > "$D/$N.state.log"
) &
SP=$!
while [ ! -f "$D/$N.stop" ]; do sleep 1; done
