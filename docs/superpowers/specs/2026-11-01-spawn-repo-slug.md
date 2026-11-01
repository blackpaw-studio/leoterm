# New-agent sheet: repo as an optional GitHub slug

Platform: **Mac only.** iOS has no new-agent flow, and the validation lives in `macos/Sources` (not LeoKit).

## Problem

The Repository field in `SpawnAgentSheet` is a text field plus a "Choose…" button that opens an `NSOpenPanel`. Its validation (`SpawnValidation.swift`) requires a path that exists on This Mac, or an absolute or `~/` path on a remote machine. The daemon (`internal/agent/resolve.go` `ValidateRepo`) accepts only a bare name or `owner/repo`, and rejects any value with more than one `/`. As a result, every value the sheet allows is refused by the daemon, and every value the daemon accepts is refused by the sheet. Only a blank field works. Blank already means "use the template's default workspace", but nothing in the sheet says so.

## Design

1. **Field.** Repository becomes a plain text field with the placeholder `owner/repo (optional)`. Remove the "Choose…" button, `openPanel`, and `canBrowseRepository`.
2. **Hint.** Below the field, show a secondary caption: "Leave blank to use the template's workspace."
3. **Normalization.** Trim whitespace. If the pasted value is a GitHub URL (`https://github.com/owner/repo`, optionally ending in `.git` or `/`), reduce it to `owner/repo`. Send the normalized value.
4. **Validation.** Replace the path checks with one rule that mirrors the daemon's `ValidateRepo` exactly. The value must be empty, a bare name, or `owner/repo` with exactly one `/` and no empty segments. The rule is the same on every machine. The error text names the expected format.
5. **Branch.** If Branch is set while Repository is blank, show the validation error "Branch needs a repository". The daemon already rejects this case, so the error should appear in the sheet before the request is sent.
6. **Wire.** Do not send `repo` when it is blank. `LeoSpawnRequest` already makes it optional; if it does not, sending `""` is acceptable because the daemon treats the two the same.
7. **Worktree mode (B-176).** No change. It already uses a read-only `owner/repo`.

## Out of scope

Local-folder workspaces (would need a daemon change). Repo autocomplete. iOS spawn.

## Testing

Update `macos/Tests/Leo/SpawnValidationTests.swift`. Replace the path-existence cases with cases for:
- blank, bare name and `owner/repo`, which are accepted
- absolute path, `~/x`, `a/b/c` and `owner/`, which are rejected
- URL normalization
- branch without a repo, which is rejected

The tests must fail before the change. Do not test the view directly. Verify by screenshotting the sheet in the debug app.
