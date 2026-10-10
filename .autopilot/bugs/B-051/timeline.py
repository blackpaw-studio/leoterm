"""Condense a capture's raw SSE log into a timeline of autopilot-scratch events.

usage: python3 -I timeline.py <scenario>.events.raw
"""
import json
import re
import sys

AGENT = "autopilot-scratch"


def involves_agent(data):
    agent = data.get("agent")
    if agent == AGENT or data.get("to") == AGENT:
        return True
    if isinstance(agent, dict) and agent.get("name") == AGENT:
        return True
    return data.get("dispatch", {}).get("caller_agent") == AGENT


def main(path):
    event = None
    for line in open(path):
        line = line.rstrip("\n")
        m = re.match(r"(\S+) event: (\S+)", line)
        if m:
            event = (m.group(1), m.group(2))
            continue
        m = re.match(r"(\S+) data: (.*)", line)
        if not (m and event):
            continue
        try:
            data = json.loads(m.group(2))
        except ValueError:
            continue
        if not involves_agent(data):
            continue
        slim = {k: (v[:90] if k == "preview" else v) for k, v in data.items() if k not in ("at", "session_id", "seq")}
        print(event[0], event[1], json.dumps(slim, separators=(",", ":")))


main(sys.argv[1])
