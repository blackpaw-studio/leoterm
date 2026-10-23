# Config API fixtures

`golden/` holds the bodies the daemon's `TestConfigAPIGolden` wrote (leo#295,
head 18e2d86b), one file per route, with the HTTP status of each in
`golden/STATUS.json`. `LeoConfigGoldenTests` decodes every one through the
app's models. Refresh the directory by copying the daemon's
`internal/web/testdata/configapi/*.json` over it; a file that stops decoding
is a contract bug to report, not to patch around.

`LeoConfigFixtures.data(_:)` serves the golden body when there is one and
falls back to the hand-written file in this directory, which exists only
where the daemon has no body of that name yet:

- `version.json`, `write_result.json` (carries a `warning`, which no golden body
  does), and, built from `docs/configuration/config-api.md` and
  `handleTaskLogAPI` / `handleTaskRunAPI` (`internal/web/config_ops.go` at
  leo#295 18e2d86b), `task_log.json` (`{file, text, truncated}`) and
  `task_run.json` (202 `{name, status}`), which the golden run does not cover.

The registered daemon schema has no `secret` field, no `multiline` or
`nullable` non-harness field, and no `pattern` constraint, so tests of those
controls build a small synthetic schema inline.
