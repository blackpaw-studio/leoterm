# Plugin platform M0 spike: decision note

Date: 2026-11-10. Host: macOS 27.0, Xcode 26.3 (`DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/...`), Apple Silicon, ad-hoc signed (`CODE_SIGN_IDENTITY=-`), Release config, hardened runtime on everywhere.
Code: `spike/plugin-m0/` (throwaway; XcodeGen `project.yml`, not merged). It is a standalone harness app, not `macos/Ghostty.xcodeproj` (that one needs the Zig-built GhosttyKit and adds nothing to the question). Harness app is unsandboxed like Leo; it embeds `PluginHost.xpc` (Swift, NSXPC), `RawHost.xpc` (C, raw `xpc_main`) and `Contents/Helpers/PluginHelper` (Swift CLI). No real Leo app or daemon was touched.

## Verdict

**(a) FAILS. XPC-per-plugin is not possible with an app-embedded XPC service.** `_MultipleInstances=true` is ignored for a third-party `ServiceType=Application` service: every connection lands on one process. **Use the fallback: a sandboxed helper in `Contents/Helpers/`, `posix_spawn`ed per plugin over a `socketpair`.** It passes (a), (b) and (c) in full. This is the Q1 case, so it needs Evan's OK before M2 builds on it, because the spec says "XPC service".
(b) passes in both forms (interpreter only, no `allow-jit`). (c) passes in both forms, but with XPC the kill takes down every plugin.

## (a) One process per plugin

Both services' Info.plist: `XPCService { ServiceType = Application; _MultipleInstances = true }` (`plutil -p` confirmed it landed in the built bundle).

| Variant | Result |
|---|---|
| `NSXPCConnection(serviceName:)` x3 (distinct `Plugin` objects, each its own `resume()`d connection) | service-reported pids `[12283, 12283, 12283]`; `connection.processIdentifier` `[12283, 12283, 12283]`. 1 distinct PID. |
| Raw C API: `xpc_connection_create("...RawHost", nil)` x3, service via `xpc_main` | `[15141, 15141, 15141]`, `xpc_connection_get_pid` same. 1 distinct PID. |
| `ps -o pid,ppid,command` | one `PluginHost.xpc/Contents/MacOS/PluginHost`, ppid 1 |
| Fallback: `posix_spawn` of `Contents/Helpers/PluginHelper` x3 | `[17408, 17409, 17410]` (second run `[19686, 19687, 19688]`), helper-reported identical, ppid = harness pid, 3 distinct processes |

The raw-API result rules out "NSXPCConnection caches the instance". The key is honoured only for Apple's own services; for third-party apps launchd keeps one instance per app. Don't plan around it. (Per-plugin pre-built service copies in the bundle don't work either: plugins are dynamic.)

## (b) JSContext without allow-jit

Entitlements, `codesign -d --entitlements -` (needs `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, else Xcode adds `get-task-allow` to ad-hoc builds):
- `PluginHost.xpc`, `RawHost.xpc`, `PluginHelper`: `com.apple.security.app-sandbox` only. Flags `0x10002(adhoc,runtime)`.

`JSContext` created and run inside the service and the helper, no crash, correct results (`typeof Intl`, `map/join` fine). The loop `for (i<20_000_000) s=(s+i*3)%1000003` returned `5490` everywhere. Sandbox is enforced in both (probe: `open(~/.zshrc)` and `connect(1.1.1.1:53)`): service `errno 1/errno 1` (EPERM), helper `errno 1/errno 1`; the unsandboxed harness got OK/OK.

Timings (20M-iteration loop; machine load avg 5 to 17 during runs, so noisy; best-of shown, range in brackets):

| Where | No allow-jit (interpreter) | With allow-jit (same binary re-signed) |
|---|---|---|
| In-app (hardened, no JIT) | 0.60 s [0.6 to 1.9] | n/a |
| XPC service | 0.58 s [0.58 to 1.8] | 0.11 to 0.32 s |
| Helper | 0.59 s [0.59 to 1.9] | 0.20 to 0.35 s |

- The sandbox adds no measurable cost over in-app. The interpreter (LLInt/baseline-less) is about 2x to 5x slower than JIT on a tight numeric loop, about 30 ns per iteration. Plugin glue (building component trees, parsing JSON) will not notice. Q2 stays: **no `allow-jit`**. The watchdog's 2 s CPU budget is the safety net for slow handlers.

## (c) Watchdog reads and kill

`proc_pid_rusage(pid, RUSAGE_INFO_V4)`, `ri_user_time + ri_system_time` converted with `mach_timebase_info` (it is mach ticks, not ns, on Apple Silicon: do this in M2), `ri_phys_footprint` for memory. Works on sandboxed children of an unsandboxed parent (same uid).

| | XPC service | Helper |
|---|---|---|
| PID source | `NSXPCConnection.processIdentifier` (equals service-reported pid) | `posix_spawn` result |
| Idle | cpu 1.17 s, footprint 4.1 MiB | cpu 0.60 s, 4.5 MiB |
| After 1 s burn + 200 MiB alloc | cpu 2.18 s (+1.01), 203.7 MiB | cpu 1.83 s (+0.80 in that run; peer B unchanged at 1.25 s), 204.8 MiB |
| `kill(pid, SIGKILL)` | rc 0; `interruptionHandler` fired within 5 s, **on all three connections** (pluginA, B, C, one shared process); later call respawned a new process (pid 12787) | rc 0; `DispatchSource.makeProcessSource(.exit)` fired; socket call on dead helper returns nil; peer B stayed alive and answered |

So with XPC, killing one runaway plugin kills every plugin and the CPU/memory read is the sum of all of them. That alone defeats the watchdog design even if everything else worked.

## Fallback notes for M2 (all observed in the spike)

- Helper must be signed with `app-sandbox` **and** carry an embedded Info.plist with a unique `CFBundleIdentifier` (`CREATE_INFOPLIST_SECTION_IN_BINARY=YES`), else the sandbox can't name a container. A container dir is created at `~/Library/Containers/<helper bundle id>` on first launch (the spike left three under `studio.blackpaw.spike.*`; harmless, delete by hand).
- Wire: `socketpair(AF_UNIX, SOCK_STREAM)`, child end dup2'd to fd 3 with `posix_spawn_file_actions_adddup2`, u32 big-endian length + JSON. Worked first try, including inside the sandbox.
- **Must set `FD_CLOEXEC` on the parent's ends (or `POSIX_SPAWN_CLOEXEC_DEFAULT`).** Without it each helper inherits its siblings' parent-end fds, so when the app dies no helper sees EOF and they linger as orphans (observed: 2 orphans after a crashed run). Also exit the helper when the socket EOFs, and ignore `SIGPIPE` in the app (writing to a killed helper otherwise terminates the app, exit 141).
- Death detection is `DispatchSource.makeProcessSource(.exit)` plus socket EOF; there is no `interruptionHandler`, so the manager owns restart/backoff.
- Developer ID signing: nested helper in `Contents/Helpers` is signed like the app's other code (sandbox entitlement on the helper only; the app stays as-is). Not tested: notarization, and the helper under the real Leo signing identity (Q13's signed-build check in 2.2 should cover this).
- Spec/plan wording to change if approved: "`LeoPluginHost.xpc`" becomes "`LeoPluginHost` helper executable in `Contents/Helpers`", and plan 2.2's `XPCService` Info.plist step (plan line 122) is dropped.

## Reproduce

```
cd spike/plugin-m0 && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer heavy xcodebuild -project SpikeHarness.xcodeproj \
  -scheme SpikeHarness -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
APP=build/Build/Products/Release/SpikeHarness.app/Contents/MacOS/SpikeHarness
$APP                    # NSXPC: (a)(b)(c)
SPIKE_MODE=raw $APP     # raw xpc_connection_create PIDs
SPIKE_MODE=helper $APP  # fallback: (a)(b)(c)
```
