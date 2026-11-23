# Leo CI on Ghast runners

Every Leo macOS and iOS job runs on a Ghast self-hosted runner. Each job gets
a fresh, throwaway Tart VM (Cirrus `macos-tahoe-xcode` image), so nothing
persists between jobs. At most 2 jobs run at once.

| Label | Xcode | Used by |
| --- | --- | --- |
| `blackpaw-macos-tahoe-xcode-26-3` | 26.3 | `leo-ci` (test-macos), `leo-build`, `leo-release` (publish), `leo-bump`, `leo-bump-release` |
| `blackpaw-macos-tahoe-xcode-26-5` | 26.5 | `leo-ios`, `leo-ios-testflight` |

Workflows use the bare label string (no `self-hosted`, no label arrays).
Ubuntu helper jobs and `leo-relay` stay on GitHub-hosted ubuntu; the upstream
Ghostty workflows are untouched.

## Hosts

The Ghast host runs on Evan's laptop first, with Dionysus as standby. Either
one serves both labels. While no host is up, jobs queue until one registers
(or the job timeout hits). There is no hosted fallback.

## Per-job setup

- `.github/scripts/leo/select-xcode.sh X.Y` finds the installed Xcode with that
  version, exports `DEVELOPER_DIR`, and fails if it is missing. It never falls
  back to another Xcode (26.5's SDK breaks Zig linking on the Mac app; Xcode 27
  crashes the iOS code; see `ci.md`).
- `.github/scripts/leo/ensure-tools.sh cmd[=formula]...` brew-installs only
  what the image lacks (`gh`, `jq`, `pkg-config`, `python3`, `coreutils`,
  `openssl@3`). Nothing beyond Homebrew and Xcode is assumed.
- Signing still uses per-job temp keychains built from repo secrets and
  removed in an `always()` step.

## Security boundary

Secrets and a signed-in VM are reachable by whatever code a job runs, so
fork-PR approval is the boundary. Fork PRs need manual approval before their
workflows run. **Never approve a fork PR that changes `.github/` without
reading it.** VMs are destroyed after each job, which limits persistence but
not what a malicious job can do with secrets while it runs.
