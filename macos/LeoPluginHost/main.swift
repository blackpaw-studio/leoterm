import Darwin
import LeoKit

// Sandboxed per-plugin JavaScriptCore host. The app spawns this with one end
// of a socketpair on fd 3. See Packages/LeoKit/.../Host/LeoPluginHostLoop.swift.
signal(SIGPIPE, SIG_IGN)
exit(LeoPluginHostLoop.run(fd: 3))
