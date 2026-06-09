# Leo — Phase 1: Fork & Baseline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the empty `leoterm` repo into a buildable, runnable fork of Ghostty's macOS app, tracked against upstream for future merges, with a baseline lightweight rebrand to "Leo".

**Architecture:** Import Ghostty's source into the existing `leoterm` repo via an `upstream` remote and an unrelated-history merge (preserving the design-spec commit and the ability to pull upstream changes later). Install Ghostty's pinned Zig toolchain, build `GhosttyKit` with `zig build`, then build and launch the macOS app via Xcode. Keep all changes surgical so the fork stays mergeable.

**Tech Stack:** Zig (pinned by upstream, `0.15.x` family), Swift / SwiftUI / AppKit, Metal, Xcode 26.5, macOS 26 SDK, tmux 3.6a, git.

---

## Scope

This plan covers **Phase 1 only** (Fork & Baseline) from `docs/superpowers/specs/2026-06-08-leo-terminal-design.md`. Phases 2–6 (grid engine, tmux control-mode client, Leo integration, status layer, polish) reference exact files and types inside Ghostty's source tree, which does not exist in the repo until this plan completes. **Each later phase gets its own plan authored against the real source once this baseline builds.** Do not attempt later phases here.

Because Phase 1 is a build/bootstrap (not feature logic), tasks verify with **build/run/inspect commands and expected output** rather than RED→GREEN unit tests. The TDD cadence begins in the Phase 2 plan, where we write real layout logic.

## Prerequisites (already verified on this machine)

- Xcode 26.5 at `/Applications/Xcode-26.5.0.app` (`xcode-select -p` confirms). Meets "Xcode 26 + macOS 26 SDK".
- macOS 26.5.
- `git` 2.47, `gh` 2.86, `tmux` 3.6a present.
- **Zig is NOT installed** — Task 2 installs the exact pinned version.

## File / change map

- `(repo root)` — gains the entire Ghostty source tree via merge (top-level `build.zig`, `build.zig.zon`, `src/` (Zig core), `macos/` (Xcode app), `HACKING.md`, etc.).
- `.git/config` — gains an `upstream` remote.
- `README.md` — created: how to build Leo, toolchain versions, upstream-sync notes.
- macOS app display name — changed from "Ghostty" to "Leo" (discovery-driven; exact file located via grep in Task 6).
- `docs/superpowers/specs/2026-06-08-leo-terminal-design.md` — already present; preserved by the merge.

---

### Task 1: Import Ghostty source as a tracked fork

**Files:**
- Modify: `.git/config` (adds `upstream` remote)
- Adds: entire upstream tree at repo root

- [ ] **Step 1: Confirm starting state is clean**

Run:
```bash
cd /Users/evan/.leo/agents/leoterm
git status --short && git log --oneline
```
Expected: no uncommitted changes; exactly the spec commit(s) present (e.g. `6acc097 docs: Leo multi-agent terminal design spec`).

- [ ] **Step 2: Add the upstream remote and fetch**

Run:
```bash
git remote add upstream https://github.com/ghostty-org/ghostty.git
git fetch upstream --tags
git remote -v
```
Expected: `upstream` listed for fetch/push; fetch downloads Ghostty history and tags without error.

- [ ] **Step 3: Record the imported upstream commit for traceability**

Run:
```bash
git rev-parse upstream/main
```
Expected: a 40-char SHA. Copy it; it goes in the commit message in Step 5 and the README in Task 7.

- [ ] **Step 4: Merge upstream into main, preserving the spec commit**

Run:
```bash
git merge --allow-unrelated-histories --no-edit upstream/main
```
Expected: a merge commit; the working tree now contains both `docs/superpowers/...` and Ghostty's tree (`build.zig`, `src/`, `macos/`). If git reports a conflict on `.gitignore` or `README`, keep both: for `.gitignore` union the contents (our `.superpowers/` line plus upstream entries), then `git add .gitignore && git commit --no-edit`.

- [ ] **Step 5: Verify the import**

Run:
```bash
ls build.zig build.zig.zon HACKING.md && ls macos && ls src | head
git log --oneline -5
```
Expected: `build.zig`, `build.zig.zon`, `HACKING.md` exist at root; `macos/` contains an Xcode project; `src/` contains Zig sources; the spec commit is still in history.

---

### Task 2: Install the exact pinned Zig toolchain

**Files:** none in-repo (installs a system toolchain).

- [ ] **Step 1: Read the required Zig version from the repo**

Run:
```bash
grep -i "minimum_zig_version" build.zig.zon
grep -iE "zig (0\.|version)" HACKING.md | head
```
Expected: a concrete version string, e.g. `minimum_zig_version = "0.15.x"`. Note the exact version `X.Y.Z` (call it `$ZIG_VER`). If `build.zig.zon` gives a minimum but HACKING.md names a specific pinned build, prefer HACKING.md's exact pin.

- [ ] **Step 2: Download and install that exact Zig version**

Run (substitute the version from Step 1; arm64 assumed for Apple Silicon — use `x86_64` on Intel):
```bash
ZIG_VER=<paste exact version>
curl -fsSL "https://ziglang.org/download/${ZIG_VER}/zig-macos-aarch64-${ZIG_VER}.tar.xz" -o /tmp/zig.tar.xz
mkdir -p ~/.local/zig && tar -xf /tmp/zig.tar.xz -C ~/.local/zig --strip-components=1
ln -sf ~/.local/zig/zig ~/.local/bin/zig
```
Note: if the download 404s, the version is a nightly/master build — get the exact URL from `https://ziglang.org/download/` for that version and adjust. Do NOT install a different version via Homebrew; the build is version-sensitive.

- [ ] **Step 3: Verify Zig is on PATH at the right version**

Run:
```bash
which zig && zig version
```
Expected: path is `~/.local/bin/zig` (already on Evan's PATH); version exactly matches `$ZIG_VER`.

---

### Task 3: Build GhosttyKit with `zig build`

**Files:** none changed (produces build artifacts under `zig-out/` / `macos/`).

- [ ] **Step 1: Select the correct Xcode and confirm SDKs**

Run:
```bash
sudo xcode-select --switch /Applications/Xcode-26.5.0.app/Contents/Developer
xcodebuild -version && xcrun --sdk macosx --show-sdk-version
```
Expected: Xcode 26.5; macOS SDK 26.x.

- [ ] **Step 2: Build the Zig core / GhosttyKit framework**

Run:
```bash
cd /Users/evan/.leo/agents/leoterm
zig build 2>&1 | tail -30
```
Expected: build completes without error. If it fails with a Zig-version mismatch, return to Task 2 and install the exact version the error names. If it fails citing "Xcode 26.4 linking issue" (noted in HACKING.md for Zig 0.15.x), follow HACKING.md's stated workaround for that combination.

- [ ] **Step 3: Confirm the framework artifact exists**

Run:
```bash
find . -name "GhosttyKit.xcframework" -o -name "libghostty*.a" 2>/dev/null | head
```
Expected: at least one GhosttyKit/libghostty artifact produced by the build.

---

### Task 4: Build and launch the macOS app (baseline, unmodified)

**Files:** none changed.

- [ ] **Step 1: Discover the Xcode scheme and project path**

Run:
```bash
ls macos/*.xcodeproj
xcodebuild -list -project macos/*.xcodeproj 2>&1 | sed -n '1,40p'
```
Expected: the project path (e.g. `macos/Ghostty.xcodeproj`) and a list of schemes. Note the app scheme name (call it `$SCHEME`, e.g. `Ghostty`).

- [ ] **Step 2: Build the app via xcodebuild (Debug)**

Run (substitute `$SCHEME` and the project path from Step 1):
```bash
xcodebuild -project macos/Ghostty.xcodeproj -scheme "$SCHEME" -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. If it fails because `zig build` outputs are expected at a path Xcode references, read the project's build phase that invokes zig (it usually runs `zig build` as a pre-build script) and ensure `zig` is on the PATH the Xcode build uses (it inherits the login shell PATH; `~/.local/bin` is already there).

- [ ] **Step 3: Locate and launch the built app**

Run:
```bash
APP=$(find build/DerivedData -name "*.app" -maxdepth 6 | head -1); echo "$APP"
open "$APP"
```
Expected: the path prints; a terminal window opens and renders a working shell (type `echo hello` and see output). This confirms the renderer, PTY, and emulation all work in the fork.

- [ ] **Step 4: Quit the app**

Quit via `⌘Q`. Confirms baseline interactivity. No commit yet (no source changes — artifacts are ignored).

---

### Task 5: Ensure build artifacts are ignored

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Check what the merge left untracked**

Run:
```bash
git status --short | grep -E "build/|zig-out/|DerivedData|\.xcframework" | head
```
Expected: build outputs appear as untracked (they must not be committed).

- [ ] **Step 2: Add ignore entries (only those not already present from upstream's .gitignore)**

Edit `.gitignore` to ensure these lines exist (do not duplicate any upstream already provides):
```
.superpowers/
/build/
/zig-out/
/.zig-cache/
**/DerivedData/
```

- [ ] **Step 3: Verify a clean status**

Run:
```bash
git status --short
```
Expected: no build artifacts listed; only `.gitignore` shows as modified (if you changed it).

- [ ] **Step 4: Commit**

Run:
```bash
git add .gitignore
git commit -m "chore: ignore Leo/Ghostty build artifacts"
```

---

### Task 6: Lightweight rebrand to "Leo" (app display name)

**Files:**
- Modify: the macOS app's display-name source (located via grep below — typically an Xcode build setting `PRODUCT_NAME`/`INFOPLIST_KEY_CFBundleDisplayName` in `macos/*.xcodeproj/project.pbxproj`, or an `Info.plist`).

Keep this minimal: change only the **user-facing app name** to "Leo". Do NOT rename the `GhosttyKit` framework, Zig modules, or bundle identifier in this phase — those ripple widely and we keep the fork mergeable.

- [ ] **Step 1: Find where the display name "Ghostty" is set**

Run:
```bash
grep -rn "CFBundleDisplayName\|CFBundleName\|PRODUCT_NAME\|MARKETING_VERSION\|= Ghostty;" macos --include="*.pbxproj" --include="*.plist" --include="*.xcconfig" | grep -i ghostty | head -20
```
Expected: one or more lines that set the visible app name to `Ghostty`. Identify the one(s) controlling the menu-bar/window app name (`CFBundleDisplayName`, falling back to `CFBundleName`/`PRODUCT_NAME`).

- [ ] **Step 2: Change the display name to "Leo"**

Edit only the display-name value(s) found in Step 1, changing `Ghostty` → `Leo`. Leave bundle identifier (`PRODUCT_BUNDLE_IDENTIFIER`) and framework/module names unchanged.

- [ ] **Step 3: Rebuild and verify the name**

Run (substitute `$SCHEME`/project from Task 4):
```bash
xcodebuild -project macos/Ghostty.xcodeproj -scheme "$SCHEME" -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -5
APP=$(find build/DerivedData -name "*.app" -maxdepth 6 | head -1)
/usr/libexec/PlistBuddy -c "Print CFBundleDisplayName" "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Print CFBundleName" "$APP/Contents/Info.plist"
open "$APP"
```
Expected: `** BUILD SUCCEEDED **`; the plist print shows `Leo`; on launch the menu bar reads **Leo**, not Ghostty.

- [ ] **Step 4: Commit**

Run:
```bash
git add macos
git commit -m "feat: rebrand macOS app display name to Leo"
```

---

### Task 7: Document the fork & tag the baseline

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

Create `README.md` with this content (replace `<UPSTREAM_SHA>` with the SHA from Task 1 Step 3 and `<ZIG_VER>` with the version from Task 2):
```markdown
# Leo

A macOS terminal optimized for running multiple coding agents at once — an auto-arranging grid of agent cells, forked from [Ghostty](https://github.com/ghostty-org/ghostty).

Design: `docs/superpowers/specs/2026-06-08-leo-terminal-design.md`.

## Status

Phase 1 (fork & baseline) complete: builds and runs as an unmodified-behavior Ghostty fork branded "Leo". Grid engine and Leo-daemon integration are subsequent phases.

## Build

Requirements: Xcode 26 + macOS 26 SDK, Zig `<ZIG_VER>`, tmux 3.x.

```bash
sudo xcode-select --switch /Applications/Xcode-26.5.0.app/Contents/Developer
zig build
xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug -derivedDataPath build/DerivedData build
open "$(find build/DerivedData -name '*.app' -maxdepth 6 | head -1)"
```

## Syncing with upstream Ghostty

Forked from upstream commit `<UPSTREAM_SHA>`.

```bash
git fetch upstream
git merge upstream/main   # resolve conflicts in new files we added; keep upstream changes to shared files
```

New Leo functionality lives in new files; edits to upstream files are kept surgical to minimize merge conflicts.
```

- [ ] **Step 2: Commit and tag the baseline**

Run:
```bash
git add README.md
git commit -m "docs: add Leo README and build instructions"
git tag -a baseline-ghostty-fork -m "Buildable Ghostty fork baseline (Phase 1)"
git log --oneline -8
```
Expected: README committed; `baseline-ghostty-fork` tag created; history shows spec → merge → artifact-ignore → rebrand → README.

- [ ] **Step 3: Final verification of the whole phase**

Run:
```bash
git status --short
zig build 2>&1 | tail -3
xcodebuild -project macos/Ghostty.xcodeproj -scheme Ghostty -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -3
```
Expected: clean working tree; `zig build` succeeds; `** BUILD SUCCEEDED **`. Phase 1 done.

---

## Self-Review

**Spec coverage (Phase 1 scope):** "Fork Ghostty's macOS app… build, confirm a single surface still works" → Tasks 1–4. Tracked-fork / mergeable principle → Task 1 (upstream remote) + Task 7 (sync docs). User-facing name "Leo" → Task 6. Stripping the split UI is explicitly deferred to the Phase 2 plan (it belongs with the GridLayout replacement, where the removed code is replaced rather than left as a hole) — noted here intentionally, not a gap.

**Placeholder scan:** Version/SHA/scheme/app-path values are intentionally read from the repo or discovered via exact commands (`grep`, `xcodebuild -list`, `find`) and then substituted — these are precise investigative steps, not vague placeholders. No "TBD"/"handle errors"/"similar to" instructions remain.

**Consistency:** `$ZIG_VER` defined in Task 2 Step 1, used in Task 2 Step 2 and Task 7. `$SCHEME`/project path defined in Task 4 Step 1, reused in Tasks 4/6/7. `<UPSTREAM_SHA>` captured in Task 1 Step 3, used in Task 7. Display name changed only via the file located in Task 6 Step 1.

**Next:** After this baseline builds, author `docs/superpowers/plans/2026-06-NN-leo-phase2-grid-engine.md` against the now-present `macos/Sources/` tree (GridLayout, PTYSource cells, dynamic/fixed sizing, hover-grow mode A, sticky focus, and removal of the split UI).
