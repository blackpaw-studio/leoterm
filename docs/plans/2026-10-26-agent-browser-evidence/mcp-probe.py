#!/usr/bin/env python3
"""Probe the isolated daemon's `leo mcp-server` over stdio, as agent <name>.
usage: mcp.py <agent> list | call <tool> '<json args>' | listen <seconds>"""
import json, os, subprocess, sys, time, select
E2E = "/private/tmp/claude-501/leoe2e"
agent = sys.argv[1]; cmd = sys.argv[2]
env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": f"{E2E}/home", "TMUX_TMPDIR": f"{E2E}/tmux",
       "LEO_PROCESS_NAME": agent, "LEO_API_TOKEN": open(f"{E2E}/home/.leo/state/agent.token").read().strip(),
       "LEO_TMUX_PATH": "/opt/homebrew/bin/tmux", "LEO_WEB_PORT": "18370"}
p = subprocess.Popen([f"{E2E}/bin/leo", "mcp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=f"{E2E}/work", text=True)
def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
def recv(timeout=60):
    r, _, _ = select.select([p.stdout], [], [], timeout)
    return json.loads(p.stdout.readline()) if r else None
send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": {"e2e-claude":"claude-code","e2e-opencode":"opencode","e2e-codex":"codex-mcp-client"}.get(agent,"e2e-probe"), "version": "0"}}})
init = recv()
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
caps = init["result"]["capabilities"] if init else None
if cmd == "list":
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    names = [t["name"] for t in recv()["result"]["tools"]]
    print(json.dumps({"agent": agent, "capabilities": caps, "count": len(names),
          "browser_or_app": [n for n in names if n.startswith(("browser_", "leo_app_"))], "all": names}, indent=1))
elif cmd == "call":
    timeout = float(sys.argv[5]) if len(sys.argv) > 5 else 120
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": sys.argv[3], "arguments": json.loads(sys.argv[4])}})
    while True:
        m = recv(timeout)
        if m is None: print("TIMEOUT"); break
        if m.get("id") == 3:
            for c in (m.get("result", {}).get("content") or []):
                if c.get("type") == "text": print(c["text"])
                else: print(f"[{c.get('type')} block, {len(c.get('data',''))} bytes b64]", file=sys.stderr)
            if "error" in m: print(json.dumps(m["error"]))
            if m.get("result", {}).get("isError"): print("(isError)")
            json.dump(m, open(f"{E2E}/last-call.json", "w"))
            break
elif cmd == "listen":
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}); recv()
    end = time.time() + float(sys.argv[3])
    while time.time() < end:
        m = recv(max(0.1, end - time.time()))
        if m: print(json.dumps(m)[:300], flush=True)
p.terminate()
