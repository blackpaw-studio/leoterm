import re, sys
sys.path.insert(0, "/private/tmp/claude-501/leoe2e")
from drive import *
s = Session("e2e-claude", f"{EV}/c2-c5-claude-direct-transcript.md")
def ref(snap, name):
    m = re.search(r'"%s"[^\n]*\[ref=(s\d+e\d+)\]' % name, snap); return m.group(1) if m else None
print("== C2: navigate/snapshot/click/type/submit")
s.call("browser_tab_select", {"tab": 1})
s.call("browser_navigate", {"url": "http://localhost:5173/"})
snap = s.call("browser_snapshot")
s.call("browser_click", {"ref": ref(snap, "Increment")})
snap = s.call("browser_snapshot")
s.call("browser_click", {"ref": ref(snap, "Increment")})
snap = s.call("browser_snapshot")
s.call("browser_type", {"ref": ref(snap, "Name"), "text": "Grace", "submit": True})
snap = s.call("browser_snapshot")
assert 'text: "2"' in snap and "Submitted: Grace" in snap, "C2 FAIL"
print("C2 PASS: count=2 and Submitted: Grace")
s.call("browser_screenshot", {}, shot=f"{EV}/c2-home-after-click-and-submit.png")
print("== C5: tabs")
s.call("browser_tabs")
t = s.call("browser_tab_new", {"url": "http://localhost:5173/login.html"})
s.call("browser_tabs")
s.call("browser_snapshot")
s.call("browser_screenshot", {}, shot=f"{EV}/c5-login-tab.png")
s.call("browser_tab_select", {"tab": 1})
snap = s.call("browser_snapshot")
s.call("browser_click", {"ref": ref(snap, "Open second page")})
time.sleep(1.5)
tabs = s.call("browser_tabs")
assert "page2.html" in tabs, "C5 FAIL: _blank link did not open a tab"
print("C5a PASS: _blank link opened a new tab")
tabs_j = json.loads(tabs)
p2 = [x for x in tabs_j if "page2" in x["url"]][0]["id"]
s.call("browser_snapshot")
s.call("browser_screenshot", {}, shot=f"{EV}/c5-blank-target-tab.png")
s.call("browser_tab_close", {"tab": p2})
after = s.call("browser_tabs")
assert "page2" not in after, "close failed"
s.call("browser_tab_select", {"tab": 99})
print("C5 PASS: list, select, close, _blank")
s.close()
