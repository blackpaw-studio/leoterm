# Config API fixtures

Hand-written from Part A of `docs/plans/2026-10-23-in-app-settings.md` (A4–A8).
The daemon side is not merged yet, so none of these were captured from a real
daemon. Field keys and values are illustrative; the **shapes** follow the plan.

When the leo PR's `TestConfigAPIGolden` files exist
(`internal/web/testdata/configapi/*.json`), copy them over these, keeping the
file names, and fix any decoding test that disagrees. Do that at the
integration gate.

Every success body is the daemon envelope `{ok, data}`; error bodies are
`{ok:false, error, code, ...}`.

`schema.json` deliberately carries one field of every type, including a
`secret` (no registered daemon field is a secret today) and a `yaml` harness
option, so the form-layout tests cover every control.
