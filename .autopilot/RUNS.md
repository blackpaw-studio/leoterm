# Runs

## Run 2026-09-22 (16:49–19:20 EDT): 5 shipped, 0 blocked
Shipped
- B-002 Attention contract → leo agent. Accepted, then implemented as leo PR #210; not released (D-010, D-011)
- B-001 Attention model: 4e064d6f7 cb18a2a6c 013840a46 465676949 93e0c4f78 60cb67072 f378da52c a0899a492 190b70f4b c5540f3c7. Verified: screenshot (DEBUG fixture)
- B-008 Test flake + lint: d806f8ecf c3edaf507 a80bd0475. Test-only change
- B-006 Tab ↔ row linkage: 54ae397a2 e05e818b7 71d366ad1 e07fa6b65. Verified: screenshots with autopilot-scratch
- B-003 File access (local + SFTP): 7fd10dad9 6f92f70e9 9b466088a a0b838dcd 1c7c93e5f 7858fbda8 4ee7c8353 515e6554b e780ead10 6f52a67c8 da7fca9c4. Not visually verified (no UI); the E2E over localhost stopped at SFTP because it's disabled in sshd_config
Calls for veto: D-010–D-025
Queued: B-015, B-016, B-017 (ready next run)
Notes: the Jump test attached the debug app to real agent `brand` (view-only, since detached; its window stayed at 74x30). verify.md updated to prevent a repeat. The autopilot-scratch agent is deleted; its workspace dir ~/.leo/agents/autopilot-scratch is left in place.
