import sys, subprocess, time, json
sys.path.insert(0, "/private/tmp/claude-501/leoe2e")
from drive import *
s = Session("e2e-claude", f"{EV}/c6-quit-transcript.md")
def names():
    s.send({"jsonrpc":"2.0","id":900,"method":"tools/list"}); m = s.recv(900)
    return [t["name"] for t in m["result"]["tools"] if t["name"].startswith(("browser_","leo_app_"))]
print("before quit:", len(names()), "browser tools")
s.call("browser_tabs")
subprocess.run(["ssh","evan@Evans-MacBook-Pro.local","pkill -f XcodeRemote/Leo.app/Contents/MacOS"])
time.sleep(4)
print("after quit tool list:", names())
out = s.call("browser_tabs")
out2 = s.call("browser_click", {"ref": "s1e1"})
s.close()
