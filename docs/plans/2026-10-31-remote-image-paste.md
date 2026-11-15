# Plan: remote image paste (Mac only)

**Spec:** `docs/superpowers/specs/2026-10-31-remote-image-paste.md`. The spec is the source of truth if the two disagree.

**Platform:** Mac only, because the iOS terminal has no paste. The logic stays in the Mac app rather than LeoKit because it is Mac-only and the PNG conversion needs AppKit.

**Commands** (run from `macos/`, with Xcode 26.3):
- `MB` builds for testing. It is slow, so run it under `heavy` in the background:
  `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- `MT(x)` runs one test class without rebuilding:
  `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<x>`

## Steps

1. **Decision table (pure logic).**
   - **Add:** `macos/Sources/Features/Leo/Integration/LeoImagePaste.swift`, containing:
     - `enum LeoImagePaste` with nested enums `Key { controlV, commandV }`, `SurfaceKind { remoteAgent, localAgent, dispatch, plain }` and `Decision { uploadImage, passThrough }`.
     - `static func decide(key:hasImage:hasText:surface:) -> Decision`.
     - `passThrough` means today's behaviour for that key: Ctrl+V sends 0x16 to the pty, ⌘V does a text paste.
   - **Test first:** `macos/Tests/Leo/LeoImagePasteTests.swift`, one parameterised `@Test` that runs every spec row against all 4 surface kinds. Only `remoteAgent` may ever return `uploadImage`.
   - **Verify:** `MB`, then `MT(LeoImagePasteTests)`.

2. **PNG conversion.**
   - **Add to `LeoImagePaste.swift`:**
     - `pngData(from: NSPasteboard) -> Data?`: if the pasteboard has `.png`, return it as is. Otherwise read `.tiff` or any `NSImage(pasteboard:)`, then re-encode with `NSBitmapImageRep.representation(using: .png)`.
     - `hasImage(_:)`, using `canReadObject(forClasses: [NSImage.self])`. It must not decode the image.
   - **Test first,** on a uniquely named `NSPasteboard(name:)`:
     - A TIFF-only item converts to data that starts with the PNG signature and keeps the original pixel size.
     - A text-only pasteboard gives nil and `hasImage == false`.
   - **Verify:** `MT(LeoImagePasteTests)`.

3. **Surface kind.**
   - **Add to `LeoRuntime+FileDrop.swift`:** `imagePasteSurfaceKind(for:)`, built on `fileDropContext(for:)`:
     - nil context gives `.plain`;
     - `identity.host == .local` gives `.localAgent`;
     - any other host gives `.remoteAgent`.
   - Dispatch panes already resolve to nil in `resolve` (line 15), so `.dispatch` only appears in the step 1 table tests.
   - **Test first,** in `LeoRuntimeFileDropTests` using the injected `context` dependency: a remote host, `.local`, and nil.
   - **Verify:** `MT(LeoRuntimeFileDropTests)`.

4. **Temp-file ownership in the queue.**
   - **Change `LeoTerminalFileDropQueue`:**
     - Add `ownedFiles: [URL] = []` to `Job`.
     - Add a private `retire(_ jobs:)` that deletes each owned file and ignores errors.
   - **Call `retire` on every path where a job leaves the queue:**
     - `finish`, both the normal path and the context-changed `jobs = []` path;
     - `cancel`, which also covers the context switch in `enqueue`, `reconcile` and `cancelTerminalFileDrops`;
     - the active job when its task is cancelled.
   - Deleting a file that sftp still has open is safe on POSIX.
   - **Test first,** with the existing fake access:
     - The owned file is gone after a successful upload, after a failed one (`accessError`), and after a context change.
     - A dropped Finder file, which the queue doesn't own, is never deleted.
   - **Verify:** `MT(LeoRuntimeFileDropTests)`.

5. **`performImagePaste(_ key:, pasteboard:, from:) -> Bool`** in `LeoRuntime+FileDrop.swift`.
   - Works out the surface kind and calls `decide`.
   - **On `.uploadImage`:**
     - get the PNG with `pngData`;
     - write it atomically to `temporaryDirectory/leo-paste-<yyyyMMdd-HHmmss-SSS>.png`, taking the date from an injected clock;
     - enqueue `Job(sources: [url], context:, ownedFiles: [url])`, finding the queue the same way `performFileDrop` (line 200) does;
     - return true.
   - **If encoding or the write fails,** return false so the key keeps today's behaviour.
   - **Test first:**
     - A remote context with an image on the pasteboard returns true, makes one host request, and inserts text ending in `.png' `.
     - A local context returns false and makes no request.
   - **Verify:** `MT(LeoRuntimeFileDropTests)`.

6. **Key and menu interception (glue).**
   - **Add to `SurfaceView_AppKit.swift`:** `leoImagePasteKey(for:) -> Key?`. It returns a key when `charactersIgnoringModifiers == "v"` and the device-independent modifiers are exactly `[.control]` or `[.command]`. Ignore `isARepeat`.
   - **⌘V and Ctrl+V:** add the check at the top of `performKeyEquivalent` (line 1347), after the `focused` guard and before `keyIsBinding` and menu routing. If `performImagePaste` returns true, return true. Window views see key equivalents before the main menu, so this one hook catches both the menu `paste(_:)` route and Ghostty's binding → `readClipboard` route.
   - **Ctrl+V backstop:** add the same check at the top of `keyDown` (line 1143), after the `surface` guard and before `interpretKeyEvents`.
   - **Edit ▸ Paste:** in `paste(_:)` (around line 1687), call `performImagePaste(.commandV, …)` first, and run the existing paste only if it returns false. This follows decision 1 below.
   - **No test:** this is AppKit event routing, and the manual end-to-end check covers it.
   - **Verify:** `MB`. Then in the debug app, check that a local agent, a plain shell and a dispatch pane behave exactly as before for both keys with both clipboard kinds.

7. **Integration gate.**
   - Run `MT` on both suites.
   - Check the host load, then run the full `macos/build.nu --action test` under `heavy`.
   - Do the spec's manual end-to-end check: paste a screenshot into a Dionysus agent running Claude Code, once with Ctrl+V and once with ⌘V. Both should show `[Image #1]`. With both text and an image on the clipboard, ⌘V should paste only the text.
   - Then a fresh-context review.

## Risks

- Something earlier in the chain might take Ctrl+V or ⌘V first, such as an AppDelegate local event monitor or a global keybind. During the end-to-end check, add a temporary log line to confirm the hook fires, then remove it.
- `charactersIgnoringModifiers` follows the keyboard layout, so on Dvorak the paste key is wherever that layout puts "v". Every other Mac app behaves the same way.
- A large image is decoded on the main thread. This follows the spec's synchronous flow and is accepted.

## Decisions (orchestrator, on the planner's open questions)

1. **Edit ▸ Paste with an image-only clipboard uploads too.** It is the same intent as ⌘V and costs one line in `paste(_:)`, added to step 6.
2. **Rebound ⌘V or Ctrl+V is not specially handled.** On a remote agent with an image on the clipboard, the app-level hook still takes the key. The spec rules out keybind config changes, so this is an accepted edge case.
