# GitHub Plugin: Implementation Plan

Spec: `docs/superpowers/specs/2026-11-10-github-plugin.md` (source of truth) · Platform: `docs/superpowers/specs/2026-11-10-plugin-platform.md`, `docs/plans/2026-11-10-plugin-platform.md`
Platform call: **Mac only.** Plugins run only on the Mac in v1, and the iOS plugin host is already in the backlog (platform 6.4). This plan makes no changes to LeoKit, the app or the daemon. Step 11 adds one LeoKit test.

## Conventions

- Source: `plugins/github/` (`src/`, `test/`, `test/fixtures/`, `package.json`, `package-lock.json`, `tsconfig.json`, `vitest.config.ts`).
- Shipped output: `macos/Bundled/Plugins/studio.blackpaw.github/{leo-plugin.json, main.js}`. The manifest exists **only** there (`main: "main.js"`). The build writes `main.js` next to it, so the same folder is also the dev-mode folder ("Load local folder…").
- **The built JS is committed.** Xcode builds have no Node. CI rebuilds the bundle and fails if it differs from the committed one (step 0).
- Toolchain is pinned exactly: Node 22 LTS (`.nvmrc`, plus `engines`), `esbuild 0.25.10` and `typescript 5.9.3` (the same as the SDK template), and **`vitest 3.2.4`** as the test runner, chosen for fake timers and an ESM/TS setup that needs no config. `"type": "module"`, and `vitest.config.ts` sets `env.TZ = "America/New_York"`.
- Build: `esbuild src/main.ts --bundle --format=iife --target=es2020 --platform=neutral --legal-comments=none --outfile=../../macos/Bundled/Plugins/studio.blackpaw.github/main.js`. No sourcemap and no banner, so the output is byte-deterministic.
- The SDK is imported in place. `tsconfig.include` has `../sdk/leo.d.ts`, and the code imports `../../sdk/actions` (bundled by esbuild).
- **DI:** all logic takes a `Leo`-typed bridge and a `Clock` as parameters. Only `src/main.ts` touches the global: `createPlugin(leo, systemClock)`. Tests use `test/stubLeo.ts`, which records `render` calls per slot, holds `on` handlers, routes `fetch` to a fixture table keyed by method + URL (with an optional sequence per key, so a 200 can be followed by a 304), uses a Map for secrets, returns `agents.list` from a settable array, and runs `timer`/`after` on manual ticks.
- Commands: `cd plugins/github && npm ci && npm run typecheck && npm test && npm run build`. Targeted: `npx vitest run test/<file>.test.ts`.
- Every step starts from a failing test unless it says "TDD exception". Each step is its own commit.
- `OAUTH_CLIENT_ID` is a single exported constant in `src/config.ts` and defaults to `""`. While it's empty, the sign-in flow shows "GitHub sign-in isn't configured in this build". Tests inject a client ID. Nothing else depends on it.

---

## Steps

**0. Scaffold, manifest and CI sync check.** TDD exception (config).
- Files:
  - `plugins/github/{package.json, package-lock.json, tsconfig.json, vitest.config.ts, .nvmrc, .gitignore (node_modules only)}`
  - `src/main.ts` (stub)
  - `test/stubLeo.ts`
  - `macos/Bundled/Plugins/studio.blackpaw.github/leo-plugin.json`
  - `.github/workflows/leo-ci.yml`
- Manifest:
  - `id studio.blackpaw.github`, `apiVersion 1`, `main main.js`
  - `network: ["github.com","api.github.com","*.actions.githubusercontent.com","*.blob.core.windows.net"]`
  - `secrets: true`, `agents: ["read","send","spawn"]`
  - `views [{id:"github",title:"GitHub",sfSymbol:"arrow.triangle.pull"}]`, `rowAccessories [{id:"pr"}]`
  - `commands`: `new-agent-from-issue`, `open-pr`, `create-pr`, `sign-in`, `sign-out` (titles: "New Agent from Issue", "Open Pull Request", "Create Pull Request", "Sign In to GitHub", "Sign Out of GitHub")
  - `sidebarSections [{id:"assigned-issues",title:"Assigned Issues"}]`
- CI: a new `plugin-github` job on `ubuntu-latest` (cheap and independent of `test-macos`):
  - checkout, then `actions/setup-node` pinned by SHA with `node-version-file`
  - `npm ci`, typecheck, test, build
  - `git diff --exit-code -- macos/Bundled/Plugins/studio.blackpaw.github`
  - Check that `package-lock.json` lists the `@esbuild/linux-x64` optional package. If it doesn't, regenerate the lockfile with `npm install --package-lock-only`.
- Verify: the command set passes. `git status` is clean after a build. Rebuilding twice gives a byte-identical `main.js` (`shasum`).

**1. Repo mapping (platform Q14):** `src/repoRef.ts` → `parseRepo(raw): {owner, repo} | null`
- Accepts:
  - `owner/repo`
  - `https://github.com/owner/repo(.git)(/)`, with any userinfo stripped
  - `git@github.com:owner/repo(.git)`
  - `ssh://git@github.com/owner/repo(.git)`
  - `github.com/owner/repo`
- Case is kept as given. Matching is case-insensitive.
- Everything else returns `null`: absolute or `~` paths, other hosts (GHE is out of scope), and anything with extra path segments.
- An agent is **mapped** when `parseRepo(repo)` is non-null and `branch` is non-empty. An unmapped agent gets no accessory, and the view says "This agent isn't on a GitHub branch", with "(repo isn't a github.com repository)" added when `repo` is set but doesn't parse.
- Failing test: `test/repoRef.test.ts`, a table of about 15 cases (credentials in a URL, a trailing `.git`, a path, a GHE host, `a/b/c`).
- Verify: `npx vitest run test/repoRef.test.ts`.

**2. GitHub client:** `src/github/client.ts`, `src/github/errors.ts`, `src/github/etagCache.ts`
- `request(method, path|url, {body?, auth})` adds:
  - `Authorization: Bearer`
  - `Accept: application/vnd.github+json`
  - `X-GitHub-Api-Version: 2022-11-28`
- It decodes `bodyEncoding: base64` and parses JSON.
- `getCached(url)` sends `If-None-Match` from an LRU of 200 entries. A 304 returns the cached body marked `{fresh:false}`.
- Results are classified as:
  - `Unauthorized` (401)
  - `RateLimited(resetAt)`: 403 or 429 with `x-ratelimit-remaining: 0`, using `x-ratelimit-reset`. A `retry-after` header gets the same treatment ✱.
  - `Http(status, body)`
  - `Transport(reason)`: the `leo.fetch` promise rejected, which includes Leo's own 60/min limit
- `graphql(query, vars)`: POSTs to `https://api.github.com/graphql`. A response with `errors[]` becomes `Http`.
- Failing test: `test/client.test.ts` with fixtures `test/fixtures/{pulls-200,pulls-304,401,403-ratelimit,429}.json` (status, a headers subset, body) covers ETag reuse, 304 → cached body, each classification, and base64 decoding.

**3. Request scheduler and poll budget:** `src/scheduler.ts`
- At most 4 in flight.
- Two lanes: **user** (view open, actions, sign-in) always runs first. **poll** is capped at **40 req/min**, which leaves 20/min of the platform's 60 for the user lane ✱.
- Poll work is deduplicated by `owner/repo@branch`. If a cycle can't cover every key, the rest go first next cycle (round-robin), so a large fleet is refreshed less often instead of hitting the limit.
- While `pausedUntil` is set, the poll lane drops its work. A `Transport` error skips that key for the cycle without telling the user.
- Failing test: `test/scheduler.test.ts` with fake timers: a 5th request queues, the user lane overtakes queued poll work, 41 poll requests in a minute leave the 41st for the next cycle, the rotation order is right, and a pause drops poll work while user requests still run.

**4. Auth: device flow, token and sign-out:** `src/auth/deviceFlow.ts`, `src/auth/session.ts`
- Device flow:
  - POST `https://github.com/login/device/code` with a form body `client_id`, `scope=repo read:org` and `Accept: application/json`.
  - Then poll POST `https://github.com/login/oauth/access_token` (`grant_type=urn:ietf:params:oauth:grant-type:device_code`) via `leo.after(interval)`.
  - `authorization_pending` → keep polling. `slow_down` → add 5 s to the interval. `expired_token` or `access_denied` → show "Code expired" or "Denied" with Retry. A success → `leo.secrets.set("token")`.
  - `leo.after` runs only while one of the plugin's slots is visible, so polling pauses on its own when nothing is visible.
- The session keeps the token in memory, loads it on `activate`, and on `Unauthorized` anywhere calls `secrets.delete`, clears caches, stops polling and re-renders every known slot signed out.
- Sign-in UI:
  - `ui/signIn.ts`: `EmptyState` "Sign in to GitHub" with a `callback("sign-in", {slot})` action.
  - The code screen is a `Detail` with the user code plus a `List` with "Open github.com/login/device" (`openURL`) and "Copy code" (`copy`).
- Failing tests: `test/auth.test.ts` covers pending → slow_down → success storing the token, expiry, denial, the empty-client-ID notice, a 401 on any request clearing the token and re-rendering every slot, and sign-out.

**5. PR matching, combined state and accessory:** `src/pr/match.ts`, `src/pr/checks.ts`, `src/ui/accessory.ts`
- Matching: `GET /repos/{o}/{r}/pulls?head={o}:{branch}&state=open&per_page=10`. If there are several, take the most recently updated.
- Then fetch `GET …/commits/{sha}/check-runs?per_page=100` and `GET …/commits/{sha}/status`, both cached by ETag.
- Combined state, in priority order failure > running > success > neutral:
  - check run `conclusion ∈ {failure, timed_out, cancelled✱, action_required, startup_failure}` or status `failure`/`error` → **failure**
  - any run whose `status` isn't `completed`, or a `pending` status → **running**
  - all of `success`/`neutral`/`skipped` → **success**
  - no checks at all → **neutral**
- Accessory (symbols checked: all are already in `LeoPluginSymbolAllowlist`, so no additions are needed):
  - `#123`, clamped to 8 characters
  - symbols: success `checkmark.circle.fill`, failure `xmark.circle.fill`, running `arrow.triangle.2.circlepath`, neutral `arrow.triangle.pull`
  - mapped but no PR: `{text:"no PR", color:"neutral"}` ✱
  - unmapped or signed out: render `[]`, which draws no chip (verified: `LeoPluginAccessoryLayout.chip` returns nil)
  - rate limited: keep the last chip and set `help: "Rate limited until HH:MM"` (local time, zero-padded)
- Failing tests: `test/match.test.ts` and `test/checks.test.ts` with fixtures `pulls-open`, `pulls-empty`, `check-runs-mixed`, `status-pending` cover each state combination, the precedence order, `#12345678` clamped, and the help text format under the fixed TZ.

**6. Failing-check log excerpt → agent:** `src/pr/logExcerpt.ts`, `src/pr/sendFailure.ts`
- A check run from GitHub Actions (`app.slug === "github-actions"`) has a check run id equal to its job id. Fetch `GET /repos/{o}/{r}/actions/jobs/{id}/logs` and follow the 302 to `*.actions.githubusercontent.com` or `*.blob.core.windows.net`.
  - The fetcher already drops `Authorization` when a redirect changes host (`LeoPluginFetcher.credentialHeaders`).
- Trimming:
  - strip ANSI escapes and the ISO timestamp at the start of each line ✱
  - keep the last 150 lines
  - drop whole lines from the front until the excerpt is ≤ 8 KB in UTF-8 bytes
  - never cut inside a code point
- Message: `Check "<name>" failed on PR #N (<o/r>@<branch>)\n<url>\n\n```\n<excerpt>\n```` where `<url>` is the check's `html_url` or `details_url`.
- No excerpt can be fetched when the check isn't from Actions, is a commit status, the log returns 404 or 410, a redirect leaves the allowlist, or the body is over 5 MB. In those cases send the name and URL plus "(log unavailable: <reason>)" ✱.
- Wiring: `callback("send-failure", {agent, checkId})`, a gesture-started follow-up. It resolves to `sendToAgent(agent, text, {title:"Send Failure to Agent"})` within the 30 s limit.
- "Open in Browser" is `openURL` and is left out when the URL isn't https.
- Failing tests: `test/logExcerpt.test.ts` (200 lines → 150, an 8 KB cap with multibyte text, ANSI and timestamp stripping, a CRLF log) and `test/sendFailure.test.ts` (302 → log fixture, 404 fallback, rejected-hop fallback, non-Actions fallback).

**7. Review threads → agent:** `src/reviews/threads.ts`, `src/reviews/batch.ts`, `src/ui/reviews.ts`
- One GraphQL query per view open or refresh: `repository(owner,name){pullRequest(number){reviewDecision, reviewThreads(first:100){nodes{id isResolved isOutdated path line originalLine comments(first:1){nodes{author{login} body url}}}}}}`.
- **Correction:** `reviewThreads` takes no `isResolved` argument, so the plugin filters `isResolved:false` itself. This keeps the spec's intent.
- `reviewDecision` comes from this same query, because REST pulls don't return it.
- UI: a `Form` with one checkbox per thread (label `path:line · @author: <first 120 chars of body>`, checked by default ✱) and a submit labelled "Send Comments to Agent" ✱.
  - Field labels are fixed when the form renders, so the submit label can't show the live N. N is the first line of the message instead.
- The submit sends a `callback` whose values come back as `{formId, values}`. It resolves to one `sendToAgent` with the selected threads grouped by file:
  - opening line: `N review comments on PR #12 (o/r):`
  - `## path`, sorted by path, then `- L<line> @author: body` sorted by line
  - an outdated thread with no `line` uses `originalLine` and "(outdated)"
- None selected → no follow-up.
- Failing tests: `test/batch.test.ts` (grouping and order, outdated threads, none selected, resolved threads filtered) and `test/threads.test.ts` (a GraphQL fixture, `errors[]` handling).

**8. Issues → new agent:** `src/issues/list.ts`, `src/issues/branchName.ts`, `src/issues/spawn.ts`, `src/ui/issues.ts`
- Fetch `GET /issues?filter=assigned&state=open&per_page=100`, cached by ETag and limited to the first page ✱. Items carrying `pull_request` are dropped.
- `branchName(n, title)`:
  - `issue-<n>-` plus a slug: NFKD, combining marks removed, lowercased, every run of non-`[a-z0-9]` characters becomes `-`, trimmed, cut to 40 characters, then trailing `-` trimmed again
  - an empty slug → `issue-<n>`
- Each item's action: `spawnAgent({repo, branch, prompt}, {title:"New Agent from Issue"})`. No `machine` (Leo's default) and no `template`. The sheet's picker is the only template control.
  - `prompt` = `title\nurl\n\n` + body capped at 8 KB in UTF-8 bytes, with "…(truncated)" added when it was cut.
  - `repo` is the raw `repo` string of an existing agent whose `parseRepo` gives the same `owner/repo`, so the daemon sees a form it already uses. If none exists, `owner/repo` ✱.
- The same list renders in the `assigned-issues` section (activated on first expand, then refreshed on the poll lane at most once per cycle) and in the `new-agent-from-issue` palette slot.
- Failing tests: `test/branchName.test.ts` (accents, emoji, punctuation runs, a 40-character cut landing on `-`, an empty title) and `test/spawn.test.ts` (8 KB cap, PRs excluded, both repo-mapping cases).

**9. Open or create a PR:** `src/pr/createPr.ts`, `src/ui/prForms.ts`
- The platform doesn't tell a palette command which agent is focused (`command(id, slot)` carries no agent). So `open-pr` and `create-pr` first render a `List` of mapped agents in the palette slot ✱:
  - `open-pr` items: `openURL(pr.html_url)`. An agent with no PR shows a disabled-looking subtitle "No open PR".
  - `create-pr` items: `callback("create-pr:pick", {agent, slot})`. The view's PR section offers the same two actions for its own agent.
- The pick fetches `GET /repos/{o}/{r}` for `default_branch`, then **renders** a `Form` into the slot carried in the payload. It doesn't use `pushView`, which can't be refilled after async work.
  - Fields: title (branch name humanised: separators become spaces, first letter capitalised), body, base (default branch), and a draft checkbox (on).
- Submit calls `POST /repos/{o}/{r}/pulls` with `{title, body, head: branch, base, draft}`. Success → re-render "Created #N" and a follow-up `openURL`.
- A 422 whose `errors[].field === "head"` or whose `message` starts with "No commits between" → the form shows "Branch isn't pushed" plus a list item "Ask Agent to Push" (`sendToAgent(agent, "Please push branch <branch> to origin so I can open a PR.")`).
- Any other 422 shows its message inline.
- Failing tests: `test/createPr.test.ts` (humanising, request body shape, both 422 fixtures, a generic 422, success → openURL).

**10. Plugin wiring and view composition:** `src/plugin.ts`, `src/ui/view.ts`, `src/state.ts`
- Slot registry:
  - accessory slots by `machine/name` from `activate(slot)`
  - view slots from `viewOpened`
  - the section slot
  - palette slots from `command`
  - forgotten when an agent leaves `agents.list`
- Lifecycle:
  - `activate`: loads the token and starts `leo.timer(60, poll)` once
  - `agentsChanged`: refreshes new or changed keys at once (user lane) and drops removed ones
  - `viewOpened`: renders `Loading`, then the PR, checks and threads on the user lane
- View stack: `[rate-limit banner (EmptyState) | Error with Retry, PR Detail, checks List, threads Form | "No unresolved review comments"]`.
  - An unmapped agent gets "This agent isn't on a GitHub branch".
  - A network failure shows `Error` with Retry, and polling keeps going.
- `sign-out` deletes the token, re-renders everything, and the palette shows "Signed out".
- Failing test: `test/plugin.test.ts` drives the stub through these flows:
  - activate → timer → accessory rendered for a mapped agent, `[]` for an unmapped one
  - a 304 cycle re-renders nothing new
  - a 401 mid-poll → every slot signed out
  - rate limited → the banner plus the help text, polling resumes after reset
  - removing an agent drops its slot
  - view stack shape snapshot
  - the callback ids from steps 6, 7 and 9 return the right actions
  - every rendered tree passes `test/limits.ts`: depth ≤ 8, ≤ 2000 nodes, unique item ids, accessory text ≤ 8 and help ≤ 80, action titles ≤ 40, symbols for accessories on the allowlist

**11. Bundle, manifest guard and app checks.**
- Files: the built `main.js`, plus `Packages/LeoKit/Tests/LeoKitTests/Plugins/LeoBundledGitHubManifestTests.swift`, which reads the manifest via a `#filePath`-relative path and checks:
  - `LeoPluginManifestValidator` accepts it
  - the network hosts are exactly the four from the spec
  - the contribution ids match `src/config.ts` (the TS side has a mirrored check in `test/manifest.test.ts`)
- Failing test: the Swift test is red until the manifest's contribution ids match the constants.
- Verify:
  - `swift test --package-path Packages/LeoKit --filter LeoBundledGitHubManifestTests`
  - `bash macos/scripts/test_leo-bundle-plugins.sh`
  - app build (background, `heavy`), then check that `Leo.app/Contents/Resources/Plugins/studio.blackpaw.github/main.js` exists and its `shasum` matches the source

**12. E2E against a scratch repo.** TDD exception (live). See below.

## Parallelism

| Lane | Steps | Depends on |
|---|---|---|
| — | 0, then 2 (client interface and errors) | — |
| A (PR/CI) | 1, 5, 6 | 2 |
| B (reviews) | 7 | 2 |
| C (issues/PRs) | 8, 9 | 1, 2 (C can stub `parseRepo` until A lands 1) |
| D (auth/budget) | 3, 4 | 2 |

Then 10 (integration, one implementer), 11, 12. Lanes A–D each touch their own `src/` subfolder and test files. Only step 10 touches `plugin.ts`. The client, auth and token handling (2, 4, 10) get a `review.security` pass.

## E2E check (step 12)

Setup:
- A private scratch repo, `blackpaw-studio/leo-github-plugin-scratch` ✱ (**creating it needs Evan's OK**).
- Its workflow:
  - a `pass` job
  - a `fail` job that prints about 400 lines and then exits 1
  - a `big` job that writes more than 5 MB of log, to exercise the fallback
- One PR with two unresolved review threads plus one resolved thread.
- One issue assigned to the test account.
- A pushed branch with no PR, and an unpushed branch.

Run:
1. Use the isolated daemon recipe (memory: isolated-leo-daemon-recipe) with stub scratch agents whose `repo` covers the three forms `owner/repo`, an https URL and a local path, each on those branches.
2. Load `macos/Bundled/Plugins/studio.blackpaw.github/` in the debug app.
3. **Sign in:**
   - With the client ID registered: run the real device flow.
   - Before registration: seed the Keychain with a fine-grained PAT for the scratch account: `security add-generic-password -A -s leo.plugin.studio.blackpaw.github -a token -w …` on the test Mac only.
4. One round of each feature:
   - accessory states: running → failure → success
   - Send Failure: check that the excerpt is 150 lines and ≤ 8 KB, and capture the redirect hop hosts from OSLog `leo.plugins` to confirm the manifest covers them
   - the `big` job takes the fallback path
   - Send 2 Comments, checking the grouping
   - New Agent from Issue: check the sheet fields and spawn
   - Open PR
   - Create PR on the pushed branch, then on the unpushed branch → "Branch isn't pushed" → Ask Agent to Push
   - revoke the token → every slot signed out
   - optionally force a rate limit by stubbing the `/rate_limit` response
5. Screenshot every slot (view, accessory, palette list and form, section, sign-in, confirm sheets) in light and dark with Peekaboo `--capture-engine cg`. Open and audit each image, then post them to Evan via `leo_chat_post`.

## Risks and open questions (✱ = not settled by the spec; recommendation given)

- **OAuth client ID** (needs Evan): register the Blackpaw OAuth App with device flow enabled, then set `OAUTH_CLIENT_ID` and rebuild. Every other step goes ahead without it, and E2E uses the PAT seed.
- **Scratch repo and test account** (needs Evan): creating a private repo is an outward-facing action. Recorded fixtures start out shaped from GitHub's documentation. Step 12 re-records them from the scratch repo using `gh api -i` with headers trimmed to `etag`, `x-ratelimit-*`, `retry-after`, `location`, and no tokens, then commits them.
- **Q14 repo mapping:** paths and non-github hosts are unmapped and shown as not on a GitHub branch. Changing the daemon so it exposes the remote URL is out of scope. The daemon's actual `repo` forms are confirmed in E2E.
- **Spawn `repo` format ✱:** reuse an existing agent's raw string when one maps, otherwise `owner/repo`. Confirm in E2E that the daemon accepts `owner/repo`. If it doesn't, the user edits the field in the sheet.
- **Poll budget ✱:** 40/min poll cap plus round-robin. More than about 13 mapped PR branches means each one refreshes less often than every 60 s. 304s still count toward Leo's 60/min (though not toward GitHub's limit).
- **Palette commands need an agent ✱:** an agent picker list is the first palette page, and the view offers the same actions directly.
- **Rendering into a slot from a callback ✱:** `create-pr` and sign-in render into the slot echoed back in the callback payload. If the router refuses a render to a palette slot that isn't open, fall back to doing these flows only in the view and section. Confirm early in step 10's test, and again in E2E.
- **Log redirect hosts:** GitHub has moved log storage before. A new host makes the hop fail cleanly, the fallback message is sent, and the manifest is amended (which re-prompts approval for bundled plugins, per platform Q11). Large logs (> 5 MB) always take the fallback. A suffix `Range` request is not used because Azure support for it is unverified.
- **`*.blob.core.windows.net` is broad:** any Azure blob is reachable. This is accepted for a first-party plugin, as the spec chose.
- **Smaller ✱ calls:** `cancelled` counts as failure; mapped with no PR shows a "no PR" chip; ANSI and timestamps are stripped from log excerpts; threads are checked by default; the submit label is fixed; issues are limited to the first 100; `retry-after` is treated as a rate limit.
- **The built bundle can drift from the source:** the CI sync check catches it. The local reminder is to run `npm run build` before committing any `plugins/github/src` change.

---

## Orchestrator decisions (2026-11-11)

- All ✱ recommendations are accepted as written.
- The scratch repo for step 12 still needs Evan's explicit OK when E2E is reached.
- The OAuth client ID stays `""` until Evan registers the app.
- Execution order:
  1. Steps 0 and 2, one implementer.
  2. Lanes A–D in parallel worktrees.
  3. Steps 10 and 11, one implementer.
  4. Review.
  5. Step 12.
