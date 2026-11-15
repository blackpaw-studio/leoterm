import json, os, subprocess, select, base64, time, sys, re
E2E = "/private/tmp/claude-501/leoe2e"
EV = "/Users/evan/.leo/agents/.worktrees/leoterm/agent-browser/docs/plans/2026-10-26-agent-browser-evidence"
CLIENT = {"e2e-claude": "claude-code", "e2e-opencode": "opencode", "e2e-codex": "codex-mcp-client"}
class Session:
    def __init__(self, agent, log):
        self.agent, self.log, self.n = agent, open(log, "a"), 10
        env = {"PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": f"{E2E}/home", "TMUX_TMPDIR": f"{E2E}/tmux",
               "LEO_PROCESS_NAME": agent, "LEO_API_TOKEN": open(f"{E2E}/home/.leo/state/agent.token").read().strip(),
               "LEO_TMUX_PATH": "/opt/homebrew/bin/tmux", "LEO_WEB_PORT": "18370"}
        self.p = subprocess.Popen([f"{E2E}/bin/leo", "mcp-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=env, cwd=f"{E2E}/work", text=True)
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                   "clientInfo": {"name": CLIENT[agent], "version": "0"}}}); self.recv(1)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}); self.recv(2)
    def send(self, o): self.p.stdin.write(json.dumps(o) + "\n"); self.p.stdin.flush()
    def recv(self, want, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([self.p.stdout], [], [], max(0.1, end - time.time()))
            if r:
                m = json.loads(self.p.stdout.readline())
                if m.get("id") == want: return m
        return None
    def call(self, tool, args=None, timeout=60, shot=None):
        self.n += 1
        self.send({"jsonrpc": "2.0", "id": self.n, "method": "tools/call", "params": {"name": tool, "arguments": args or {}}})
        m = self.recv(self.n, timeout)
        out = []
        if m is None: out = ["TIMEOUT"]
        else:
            for c in (m.get("result", {}).get("content") or []):
                if c.get("type") == "text": out.append(c["text"])
                elif c.get("type") == "image" and shot:
                    open(shot, "wb").write(base64.b64decode(c["data"])); out.append(f"[image saved {os.path.basename(shot)}]")
                else: out.append(f"[{c.get('type')}]")
            if "error" in m: out.append("RPC-ERROR " + json.dumps(m["error"]))
            if m.get("result", {}).get("isError"): out.append("(isError)")
        text = "\n".join(out)
        self.log.write(f"## {self.agent} {tool} {json.dumps(args or {})}\n{text}\n\n"); self.log.flush()
        print(f"{tool} {json.dumps(args or {})} -> {text[:700]}")
        return text
    def close(self): self.p.terminate()
