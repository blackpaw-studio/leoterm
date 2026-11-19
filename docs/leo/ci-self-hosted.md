# Self-hosted CI runner

`test-macos` in `.github/workflows/leo-ci.yml` runs on Evan's Tart VM runner
when it is idle, and on hosted `macos-26` otherwise. iOS CI stays hosted
(it needs Xcode 26.5).

## How the picker works

The `pick-runner` job (ubuntu, 5 min cap) outputs `runner`, a JSON value that
`test-macos` feeds to `runs-on: ${{ fromJSON(...) }}`: `["self-hosted","xcode-26.3"]`
or `"macos-26"`. It picks self-hosted only if all hold:

- the event is `push`, `workflow_dispatch`, or a `pull_request` from this repo;
- input `allow_self_hosted` is not `false`;
- secret `LEO_RUNNER_PICKER_TOKEN` is set;
- `GET /orgs/blackpaw-studio/actions/runners` lists a runner that is `online`,
  not `busy`, with labels `self-hosted` and `xcode-26.3`.

Any API error (including 403 while the token lacks the org self-hosted-runners
read permission), missing token, or parse failure falls back to hosted, with a
`::notice::` saying why.

**Fork PRs never use self-hosted**: a fork can change the workflow and run
arbitrary code on the laptop.

**Releases never use self-hosted**: `leo-release.yml` calls `leo-ci.yml` with
`allow_self_hosted: false`.

**Sleeping laptop:** the idle check races with sleep. If the runner goes
offline after it was picked, the job queues until `timeout-minutes` (120) and
fails; re-run it via `workflow_dispatch` with `allow_self_hosted` off.

## Runner requirements

- Org-level runner (blackpaw-studio), name `blackpaw-laptop-vm-*`, labels
  `self-hosted, macOS, ARM64, laptop, vm, xcode-26.3`.
- Xcode 26.3 at one of `/Applications/Xcode_26.3.app`, `Xcode-26.3.0.app`,
  `Xcode-26.3.app`, `Xcode.app` (the workflow checks `xcodebuild -version` is 26.3).
- Homebrew (the workflow installs `coreutils` if missing) and `gh` on PATH.
- Zig: the workflow installs its own via `mlugg/setup-zig` (currently 0.16.0;
  the dev toolchain is 0.15.2), so none is required on the VM.
- SwiftLint: the workflow downloads 0.63.3 per run; no install needed.
- A logged-in GUI session (unit tests need a main screen).

## Runner hooks (proposed)

`.github/scripts/leo/runner-hooks/job-started.sh` and `job-completed.sh` kill
stray `xcodebuild` and Ghostty/Leo test hosts and prune DerivedData older than
3 days (`~/Library/Developer/Xcode/DerivedData`). Copy them to a stable path
outside `_work`, add to the runner's `.env`, and restart the runner service:

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/path/to/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/path/to/job-completed.sh
```
