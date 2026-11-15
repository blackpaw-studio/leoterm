# Portable CI tests (spec)

Status: approved by Evan 2026-11-01 ("do it"). Platform call: **Mac only.** The
iOS app and LeoKit tests already run on plain runners; LeoKit has no
environment-dependent tests.

## Problem

The macOS unit suite (`GhosttyTests`, run by
`.github/scripts/leo/run-unit-tests.sh`) only passes on the self-hosted runner
because that Mac has a logged-in, unlocked console. On a GitHub-hosted
`macos-26` runner it hangs: `LeoChatCopyTests.commandCCopiesSelectedChatText`
(`macos/Tests/Leo/LeoChatCopyTests.swift:21`) builds a real Ghostty surface and
sends a real ⌘C through `NSApp.sendEvent`, blocking the main thread, so the
60 s `.timeLimit` can't fire and the 900 s script timeout kills the run. One
hosted run also crashed in `LeoEnvironmentActionsTests.swift:109`.

Goal: CI depends on nothing a plain hosted runner lacks, so we can retire the
self-hosted runners.

## Decision

Split the suite into two tiers:

- **Portable (CI, default):** pure logic. No window server or key window, no
  real event delivery, no real Ghostty surface or child process, no real
  sockets/tmux/ssh/network, no keychain, no `UserDefaults.standard`, and no
  wall-clock waits for behavior that a clock could drive.
- **Host (opt-in):** tests that genuinely need a real app session: real
  surfaces, `sendEvent` key/mouse paths, WKWebView, real ssh/tmux/leo end to
  end. They run locally on demand and before a release, and are skipped
  (reported as skipped, not silently dropped) everywhere else.

### Mechanism

The runner injects the bundle into `Leo.app` and runs `-XCTest All`, so
Xcode test plans don't apply. Use one Swift Testing trait (for example
`.hostOnly`) that is enabled only when `LEO_HOST_TESTS=1`, and fold the
existing `.requiresActiveHost` / `hasWindowServer` gates (11 files) into it so
there is one rule. For XCTest-style cases, use an equivalent `XCTSkip` helper.
`run-unit-tests.sh` gains a `LEO_HOST_TESTS` passthrough; CI leaves it unset.
Add a documented local command for the host tier.

### Per-test rule

Revised 2026-11-02 (Evan approved): the first cut gated every real-Ghostty-surface
test, which was too broad (~313 cases skipped on hosted, ~175 of them real-terminal
suites that had passed there). A test is `.hostOnly` / `.requiresActiveHost` only if it:

1. needs Leo to be the active app with a key window, or real posted key/mouse
   events (`.requiresActiveHost`, via the focus probe);
2. needs a real SSH host (`LeoSSHEndToEnd.trait`); or
3. has been observed to fail on hosted `macos-26` because AppKit draws or measures
   differently there and can't reasonably be made portable (re-gate the specific
   test, not the suite, with a one-line comment saying what differs).

Everything else runs in CI, including real Ghostty surfaces, child shells and
WKWebView. Prefer making a test portable over gating it: inject the clock, a fake
transport, an in-memory defaults store (`LeoInMemoryDefaults`), a screen frame, or
a fake binary on PATH. A test that only needs a view hierarchy runs without key focus.

Audit counts (grep, files): 44 window/NSApp, 33 real surface/AppDelegate,
21 `sendEvent`, 64 `Task.sleep` (122 sites), 11 `Process()`, 2 `NSScreen`,
1 `UserDefaults.standard`. Real sleeps that don't hang on a hosted runner
are not in scope unless they make the suite slow or flaky; record the rest
as a follow-up.

## CI

- New `.github/workflows/leo-ci-hosted-bench.yml` (on branch
  `ci/hosted-runner-bench`) is the starting point: `macos-26`, Xcode 26.3,
  pinned zig/swiftlint, caches for zig, LeoKit `.build` and DerivedData.
- Done = the portable tier is green on `macos-26` three runs in a row
  (one cold, two warm), with timings recorded. Switching `leo-ci.yml` and the
  other `leo-*` workflows off self-hosted is a **separate, later** change.

## Acceptance

1. Hosted run of the full portable tier completes with no hang/crash, three
   consecutive green runs.
2. Self-hosted run with `LEO_HOST_TESTS=1` still runs every moved test and
   passes, so no coverage is lost.
3. Skipped host tests are listed by name in the CI log.
4. The run on hosted shows per-step timing for cold vs warm.
5. A short note in `macos/Tests/README` (or the nearest existing testing
   doc) states the portable rule and the host-tier command.

## Out of scope

Retiring the runners, migrating release/signing/TestFlight workflows,
rewriting the remaining `Task.sleep` waits, the iOS suite.
