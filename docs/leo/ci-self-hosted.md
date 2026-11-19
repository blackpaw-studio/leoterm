# Self-hosted CI runner

`test-macos` in `.github/workflows/leo-ci.yml` runs on Evan's Tart VM runner
when it is idle, and on hosted `macos-26` otherwise. iOS CI stays hosted
(it needs Xcode 26.5).

## How the picker works

The `pick-runner` job (ubuntu, 5 min cap) outputs `runner`, a JSON value that
`test-macos` feeds to `runs-on: ${{ fromJSON(...) }}`: `["self-hosted","xcode-26.3"]`
or `"macos-26"`. It picks self-hosted only if all hold:

- `github.ref` is `refs/heads/main` (push or `workflow_dispatch` on main);
  pull requests (including same-repo ones) and branch dispatches go hosted;
- input `allow_self_hosted` is not `false`;
- secret `LEO_RUNNER_PICKER_TOKEN` is set;
- `GET /orgs/blackpaw-studio/actions/runners` lists a runner that is `online`,
  not `busy`, with labels `self-hosted` and `xcode-26.3`.

Any API error (including 403 while the token lacks the org self-hosted-runners
read permission), missing token, or parse failure falls back to hosted, with a
`::notice::` saying why.

## Security boundary

The boundary is the **org runner group**, restricted to the workflow
`blackpaw-studio/leoterm/.github/workflows/leo-ci.yml@refs/heads/main`. A PR,
fork or branch can edit workflow YAML, so nothing in YAML is a control. The
`refs/heads/main` check in the picker only mirrors the group so it never picks
a runner the group would refuse (the job would sit queued forever).

**Releases never use self-hosted**: `leo-release.yml` calls `leo-ci.yml` with
`allow_self_hosted: false`.

## Queue time and a sleeping laptop

`timeout-minutes` (120) bounds a job's run time, **not** its queue time. A job
waiting for a self-hosted runner stays queued until GitHub gives up (24 hours).

- Laptop sleeps after the pick, before the job starts: the job stays queued on
  the offline runner. Cancel it and re-run, or dispatch on main with
  `allow_self_hosted` off.
- Laptop sleeps mid-job: the runner stops reporting, GitHub marks the job
  failed after losing contact (about a few minutes). Re-run.

The picker's online and idle check keeps the pick-to-start window small, so
this is rare.

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

Both scripts only act inside the runner's own work dir (the parent of
`$RUNNER_TEMP`, which must be named `_work`); they do nothing otherwise.

- `.github/scripts/leo/runner-hooks/job-started.sh` kills leftover `xcodebuild`
  and `.app` test-host processes whose command line contains that work dir, and
  deletes `$RUNNER_TEMP/DerivedData-*` older than 3 days.
- `job-completed.sh` does only the scoped process kill; it deletes nothing.

Neither touches `~/Library/Developer/Xcode/DerivedData` or unrelated processes.
Copy them to a stable path outside `_work`, add to the runner's `.env`, and
restart the runner service:

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/path/to/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/path/to/job-completed.sh
```
