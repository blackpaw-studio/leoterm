# GitHub Plugin — v1 Spec

Date: 2026-11-10 · Status: draft for approval · Platform call: **Mac only** (it is a plugin and therefore Mac-only in v1) · Depends on: `2026-11-10-plugin-platform.md`

## Goal

Close the review loop with Orca from inside Leo. For each agent you can see its PR and CI status, send failures and review comments back to it, start agents from issues, and open or create PRs. This plugin is first-party but uses **only** the public plugin API.

## Manifest

- id `studio.blackpaw.github`.
- Network: `github.com`, `api.github.com`, and the Actions log redirect hosts (`*.actions.githubusercontent.com`, `*.blob.core.windows.net`).
- Permissions: `secrets: true`, `agents: [read, send, spawn]`.
- Contributes:
  - view `github` ("GitHub")
  - rowAccessory `pr`
  - commands: `new-agent-from-issue`, `open-pr`, `create-pr`, `sign-in`, `sign-out`
  - sidebarSection `assigned-issues`

## Auth

- Device-flow OAuth against a Blackpaw GitHub OAuth App, with scopes `repo` and `read:org`. The sign-in view shows the user code, offers "Open github.com/login/device", and polls until approved.
- The token is stored with `leo.secrets` (Keychain).
- A 401 at any point clears the token and turns every slot into a "Sign in to GitHub" empty state.
- github.com only; GitHub Enterprise is out of scope.

## Features

1. **PR and CI status**
   - **Matching:** an agent matches a PR when it has `repo` (owner/repo) and `branch`. The plugin looks up `GET /repos/{o}/{r}/pulls?head={o}:{branch}&state=open`, then checks the head SHA's check runs and statuses.
   - **Row accessory:** `#123` coloured by combined state: success, failure, running, or neutral when there is no PR.
   - **Refresh:**
     - every 60 s for agents with a repo and branch
     - when the agent list changes
     - when the view opens
   - Requests use ETags so unchanged data comes back as 304.
   - **View, top section:** PR title, state, draft flag, and review decision, plus a link. Below that is a list of checks with their state.
   - **Failing check actions:** "Send failure to agent" sends the check name, URL, and the last 150 lines of the job log, capped at 8 KB. It goes through the confirmation sheet like every agent action. "Open in browser" opens the check.
2. **Review comments → agent**
   - The view lists unresolved review threads, fetched with GraphQL `reviewThreads(isResolved:false)`, each showing `path:line`, author, and body.
   - Each item has a checkbox. "Send N comments to agent" sends one batched message grouped by file, through the confirmation sheet.
3. **New agent from issue**
   - The `assigned-issues` sidebar section and the `new-agent-from-issue` command both list open issues assigned to you across repos (`GET /issues?filter=assigned&state=open`).
   - Choosing an issue opens a spawn action with these fields:
     - repo = the issue's repo
     - branch = `issue-<n>-<slug(title, 40)>`
     - prompt = issue title, URL, and body (body capped at 8 KB)
     - machine = Leo's default
   - The user edits the fields in the confirmation sheet before the agent is spawned.
4. **Open or create a PR**
   - **Open PR** opens the matched PR's URL.
   - **Create PR** opens a form with:
     - title (default: the branch name humanised)
     - body
     - base (default: the repo's default branch)
     - a draft toggle (on by default)
   - Submitting calls `POST /repos/{o}/{r}/pulls`.
   - On a 422 "no commits / branch not found" error, the form shows "Branch isn't pushed" and offers "Ask agent to push", a send action with preset text.
   - Merging is out of scope.

## Errors and limits

- **Rate limiting:** after a 403/429 with `x-ratelimit-remaining: 0`, the plugin pauses polling until the reset time and shows a "Rate limited until HH:MM" accessory tooltip and view banner.
- **Agents without a repo or branch:** they get no accessory, and the view says "This agent isn't on a GitHub branch".
- **Network failures:** the `Error` component with Retry. Polling continues silently.

## Testing

- The plugin's TypeScript logic is unit-tested with recorded GitHub fixtures and a stub `leo` bridge. Tests cover:
  - PR matching
  - combining check states
  - trimming log excerpts
  - grouping batched comments
  - deriving branch names
  - 401 and rate-limit handling
- **End-to-end:** sign in to a scratch repo, then do one round of each feature against the real Leo app. Screenshot every slot.

## Out of scope

- Merging
- Writing review replies
- GitHub Actions re-runs
- Notifications and webhooks
- GitHub Enterprise
- Autonomous sends (every agent action goes through the user)

## Open items (need Evan)

- Register the Blackpaw GitHub OAuth App with device flow enabled, and store its client ID. The client ID is public and gets embedded in the plugin.
