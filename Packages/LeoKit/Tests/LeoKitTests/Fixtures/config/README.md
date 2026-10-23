# Config API fixtures

`golden/` holds the bodies the daemon's `TestConfigAPIGolden` wrote (leo#295,
head 3b1c26cd), one file per route, with the HTTP status of each in
`golden/STATUS.json`. `LeoConfigGoldenTests` decodes every one through the
app's models. Refresh the directory by copying the daemon's
`internal/web/testdata/configapi/*.json` over it; a file that stops decoding
is a contract bug to report, not to patch around.

`LeoConfigFixtures.data(_:)` serves the golden body when there is one and
falls back to the hand-written file in this directory, which exists only
where the daemon has no body of that name yet:

- `history.json` (the daemon's is `task_history`), `version.json`,
  `write_result.json` (carries a `warning`, which no golden body does).

The registered daemon schema has no `secret` field, no `multiline` or
`nullable` non-harness field, and no `pattern` constraint, so tests of those
controls build a small synthetic schema inline.
