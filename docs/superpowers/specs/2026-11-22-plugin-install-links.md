# Plugin install links, unverified warning, external Usage plugin

Date: 2026-11-22 · Platform: **Mac only** (the plugin host exists only on Mac; nothing goes to iOS).

## Goal

Make installing a plugin that is not bundled with Leo one click from a README, warn when the source is not Blackpaw's, and ship the Usage plugin as the first external plugin.

Install from URL, commit pinning, permission review and update checks already exist (`LeoPluginGitInstaller`, `LeoPluginInstallFlow`, `LeoPluginUpdater`, Settings → Plugins). This spec only adds on top of them; the install pipeline itself does not change.

## A. Unverified-source warning

- A git source is **verified** only if its validated URL (after `LeoPluginGitSource` validation) has the host `github.com` (case-insensitive, an exact match, so not `www.` and no other subdomain) and its first path segment is `blackpaw-studio` (case-insensitive). Every other git source is **unverified**. Bundled and dev (local folder) sources get no trust label.
- The rule lives in LeoKit as a pure function: `LeoPluginSourceTrust.classify(LeoPluginSource) -> .verified | .unverified | .notApplicable`. The owner is hard-coded; there is no setting.
- UI:
  - The install approval sheet shows a warning banner for unverified sources: "Not from Blackpaw Studio. Only install plugins from people you trust." The banner never blocks the install.
  - The update approval sheet shows the same banner.
  - The plugin's row in Settings → Plugins shows an "Unverified" label.
- Inputs that must classify as unverified:
  - `github.com.evil.com/blackpaw-studio/x`
  - `github.com/blackpaw-studio-x/y`
  - `evil.com/blackpaw-studio/x`
  - `gitlab.com/blackpaw-studio/x`

## B. `leo://` install link

- Format: `leo://plugin/install?url=<percent-encoded https git URL>[&ref=<tag|branch|sha>]`.
- The Mac app registers the URL scheme in its Info.plist. **Debug builds register `leo-debug`** so that a dev build never steals links from the installed app.
- Parsing is a pure LeoKit function: `LeoPluginInstallLink.parse(URL) -> Result<(source, ref?), Error>`. It is strict:
  - The scheme is `leo` (or `leo-debug`), the host is `plugin`, and the path is `/install`.
  - The only allowed query keys are `url` and `ref`. Each appears at most once. Any other key rejects the link.
  - `url` must pass the same validation as `LeoPluginGitSource`: https only, no embedded credentials.
  - `ref` is limited to the characters git accepts in a ref name. Parsing rejects anything else.
- Handling a link:
  - Bring Leo to the front, open Settings → Plugins, and open the existing Install-from-URL flow with `url` (and `ref`, if given) filled in.
  - The user then goes through the normal review: manifest, permissions, unverified banner. **A link never installs anything without that review and the user's click.**
  - The link is ignored if any install or update sheet is already open, to avoid a page spamming sheets. Leo logs that it ignored the link.
  - If parsing fails, Leo shows an alert with the reason and installs nothing.
  - Cold launch works: a link that arrives before the window is up is held and handled once Settings can open.
- If the current Install-from-URL flow has no way to pass a ref, add one. The planner should check this.

## C. Usage plugin moves to its own repo

- Order: the `usage-plugin` branch (apiVersion 2 + `credentials`) merges to main first. That merge still waits on its pending live E2E with Evan (the Keychain prompt). This spec does not change that gate.
- Create the **public** repo `blackpaw-studio/leo-plugin-usage`. Evan approves the exact `gh repo create` command before it runs.
- Move the contents of `plugins/usage/` there, keeping its tests and adding a minimal CI workflow that runs them. Remove `plugins/usage/` from leoterm, along with the CI guard that only existed to keep it out of the bundle.
- If `plugins/usage` imports from `plugins/sdk` by relative path, vendor what it needs or pin it in the new repo. The planner should check this.
- Tag `v<manifest version>`. The README carries the install link: `leo://plugin/install?url=https%3A%2F%2Fgithub.com%2Fblackpaw-studio%2Fleo-plugin-usage&ref=v<version>`.

## Out of scope

Curated index or browse UI, code signing, archive/tarball installs, user-editable trusted owners, and iOS.

## Testing

- LeoKit unit tests:
  - `LeoPluginSourceTrust`: the verified case plus each spoof listed in A.
  - `LeoPluginInstallLink.parse`: the valid case with and without `ref`; rejecting a wrong scheme, host or path, an unknown key, a duplicate key, an http URL, a URL with credentials, and a bad ref.
- Mac tests:
  - A parsed link routes to the settings model with the URL (and ref) filled in.
  - A link that arrives while a sheet is open is ignored.
- Live check: in a debug build, run `open 'leo-debug://plugin/install?url=…&ref=…'` against the new repo, then install Usage end to end. Screenshot the sheet with the unverified banner using a non-Blackpaw fork, and the clean sheet with the Blackpaw repo.
