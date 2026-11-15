# Plan: chat ask inputs + surfaced-files removal (leoterm clients)

Spec: `../leo/docs/specs/2026-10-12-chat-ask-inputs.md` and `../leo/docs/configuration/chat.md` (the contract), plus our `docs/superpowers/specs/2026-10-12-leo-chat.md`. Daemon: leo PR #268. I checked the wire shapes against `leo/internal/chat/{input,migrate,prompts}.go`.

## Contract facts the plan relies on (verified)
- An Input encodes as `{type, options?, allow_text?, min?, max?, placeholder?}`. `min` is omitted when it is 0 and `max` is omitted when it means "all".
- An Answer encodes as `{values: [...], text: ""}`. `text` is always present and often empty. Decode `""` as nil.
- New `permission` messages carry `input` as buttons allow/deny (`prompts.go:145`). Rows migrated from v0.49 do not. The chat.db migration backfills `input` for old asks and turns old answers into `{values:[a], text:""}`.
- The push relay already has `input_type,omitempty` (`push/relay.go:80`).

## Planning decisions (the orchestrator can veto any of these)
1. **Shared-LeoKit dependency.** The LeoKit `Surfaced/*` deletion moves to **WP2**, in the same commit as the Mac surfaced removal. WP1 only stops iOS using it. The LeoKit *chat* API change lands in WP1, together with a mechanical Mac compile bridge (step 6), so `macos` builds after every commit.
2. **Strict decode.** `LeoChatMessage` throws in three cases: an `ask` with no `input`, a malformed `input`, or a malformed `answer`. `LeoLenientArray` (pages and thread lists) still drops elements it can't decode, but now logs each drop with its `DecodingError` via `os.Logger` (subsystem LeoKit, category `chat`) at `.fault`. If "fail loudly" has to mean visible to the user, make `LeoChatPage.messages` strict instead. That is a one-line change.
3. **Push stays tolerant.** Malformed or missing push `options` means no buttons, so the notification opens the app. A push must always show; it is a hint, not the record.
4. **Asks that can't be answered from a notification** get a new static category `leo.chat.ask.open` with no actions. Without it, the inline Reply action would send a new message that looks like an answer.
5. **Permission rows without `input`** (pre-migration) fall back to the built-in allow/deny.
6. **Mac `Surfaced/` has 8 files, not 7.** `LeoReadDeadline.swift` is shared with the editor (`LeoEditorPaneModel`, `LeoEditorTabs`, `LeoFilePreview:145`, `LeoEditorDocumentPreviewTests:158`). Move it to `Editor/` and drop `.surfacedOpen`. `LeoSurfacedPaneCommitTests` tests `LeoEditorPaneModel` and only mentions surfaced files in comments, so rename it and keep it. With no surfaced caller left, the `readDeadline:` parameter has only test callers; removing it is a possible follow-up.
7. **Answered-state helpers move into LeoKit.** `LeoChatMessage.answered(_:)` is duplicated today in `ChatThread.swift:305-313` and `LeoChatPaneModel.swift:398-403`. It moves into LeoKit and both copies are deleted.

## Commands
- **LeoKit:** `cd Packages/LeoKit && swiftlint lint --strict && swift test`
- **LeoFeatures:** `cd ios/LeoFeatures && swift test`
- **iOS:** `cd ios && xcodegen generate`, then run both of these with `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer` and `-project Leo.xcodeproj -scheme Leo -destination "platform=iOS Simulator,name=iPhone 17 Pro" -derivedDataPath "$TMPDIR/dd-leo-ios"`:
  - `xcodebuild build-for-testing` (add `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`)
  - `xcodebuild test-without-building`
- **Mac build:** `cd macos && DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64'`
- **Mac tests:** `DERIVED_DATA=$TMPDIR/dd-leo-mac DEVELOPER_DIR=…26.3.0… LOG=$TMPDIR/leo-tests.log .github/scripts/leo/run-unit-tests.sh`. If `macos/GhosttyKit.xcframework` is missing, run `zig build -Demit-macos-app=false` first.
- **Mac lint:** `cd macos && swiftlint lint --strict`. `ios/` has no `.swiftlint.yml`.
- **Project files:** the Mac project uses synchronized folders, so it needs no pbxproj edits. iOS uses XcodeGen: regenerate and commit `Leo.xcodeproj`.

---
## WP1: LeoKit + iOS (one `implement` run)
**Commit rule:** every commit keeps LeoKit and LeoFeatures `swift test` green and the Mac building.

**0. Docs.** Amend our client spec. The `{value}` answer (lines 45, 54), `options?` (51, 56) and the `leo_chat_ask` return (78) become `input` and `{values, text}`. The "Attachments" row (22) becomes "Outbound files are `leo_chat_post` attachments".

**1. Ask models.** New `Chat/LeoChatAsk.swift`. `LeoChatModels.swift` is already 324 lines.
- `LeoChatInput {kind: .buttons|.radio|.checkboxes|.text, options, allowsText, min, max, placeholder?}`
  - Strict `Codable` that mirrors `validateInput`.
  - Options must be `{value,label}` objects with both fields as strings. Values are non-empty and distinct.
  - Choice types need 1–12 options; `text` takes none.
  - `min`/`max` apply to checkboxes only. Defaults are 0 and the option count. Valid when 0 ≤ min ≤ max ≤ count and max ≥ 1.
  - Placeholder ≤ 200 `unicodeScalars`.
  - An unknown type throws.
  - Provides `static let permission`.
- `LeoChatAnswer {values, text?}`
  - Encodes `text` only when it is non-nil. Decodes `""` as nil.
  - `static func choice(_:)` and `maxTextScalars = 4000`.
- `LeoChatMessage`
  - Remove `options` and the `answerChoices` property; `answer` becomes `LeoChatAnswer?`; add `input: LeoChatInput?`.
  - `answerInput` is `input`, or `.permission` for a permission row without one.
  - Delete `LeoChatOption.permissionChoices` (it is replaced by `.permission`) and update `LeoChatNotificationActions:81`.
  - Add the `LeoLenientArray` drop log from decision 2.
- **Failing tests first** (`LeoChatDecodingTests`, parameterized):
  - Each type decodes with its defaults.
  - Each invalid input throws: string options, 0 or 13 options, options on `text`, min/max on radio, min > max, max 0, max > count, duplicate values, a 201-scalar placeholder, an unknown type, an ask with no input.
  - A permission row with no input gets `.permission`.
  - `{values:["terminal"],text:""}` decodes with text nil.
  - Update the `LeoChatContractTests` fixture (lines 14–25) to the new shape.

**2. Draft logic.** `LeoChatAskDraft {selected, text}`.
- `choosing(_ value, in:)`: radio replaces the selection; checkboxes toggle and keep option order.
- `withText(_:)`.
- `answer(for:) -> LeoChatAnswer?`: trims the text and returns nil unless the result is valid under the `validAnswerFor` rules with ≤ 4000 scalars.
- `remainingTextScalars`.
- **Failing test:** `LeoChatAskDraftTests`, a table copied from `chat.md` lines 115–123. Cover: allow_text with an empty selection, min > 0 with text only, text on a choice type without allow_text, whitespace-only text, and 4001 scalars.

**3. Message helpers.**
- `answered(_ answer:)`.
- `isAnsweredInTerminal`: true when `kind == .permission` and `values == ["terminal"]`.
- `answerSummary`: labels in answer order (an unknown value falls back to the raw value), then the text.
- `continuesPost(after:)`: true when self is an `ask`, and the previous message is outbound `text`/`file`/`task` with the same agent, task and runID.
- **Failing tests:** extend `LeoChatDecodingTests` with one case per helper.

**4. Client.** `LeoChatClient.answer(agent:messageID:answer:)`.
- The body is `{values, text?}`.
- A 409 throws `LeoChatAnswerError.settled`. Check `status` before `checked()`, because the 409 body may have no `ok` and `LeoDaemonEnvelope` requires it.
- A 400 throws `.invalid(message)`.
- Lines touched: `LeoChatClient.swift:11-13,119-125`.
- **Failing tests** (`LeoChatContractTests`): the exact body bytes; `text` omitted when nil; 409 with `{"error":"message already settled"}`, with and without `ok:false`, gives `.settled`; 400 gives `.invalid` carrying the daemon's text.

**5. Push.**
- `LeoPushPayload.inputType` (`input_type`) and `LeoPushChat.inputType`, in `LeoPushCipher.swift:20-75` and `LeoPushNotification.swift:45-83`.
- `category(for:)` (`LeoChatNotificationActions.swift:51-63`) gives the per-choice-set ask category only when all of these hold: the kind is `ask`, a `messageID` is present, options are present, and `inputType` is nil or `buttons`. Every other ask gets `askOpenCategoryID`, which also goes into `staticCategories`.
- The response's `.answer` keeps its `value: String`.
- **Failing tests:** `LeoPushCipherTests` round-trips `input_type` and tolerates it missing. `LeoChatNotificationTests` covers four cases: buttons with options; `input_type` missing with options; `input_type` missing without options (opens the app); radio/checkboxes/text (open the app).

**6. Mac compile bridge.** These are the mechanical edits that ride in the commits from steps 1–4. Behavior stays buttons-only until WP2.
- `LeoChatMessageRow.swift:49,160-168` uses `answerInput.options` and `answerSummary`.
- `LeoChatPaneModel.swift:192-207` calls `answer(…, .choice(value))`. Delete the `answered` extension at `LeoChatPaneModel.swift:398-403`.
- `Tests/Leo/LeoChatTestSupport.swift:136-140`: `options:` becomes `input:`, plus the fake client's new `answer` signature. `LeoChatPaneModelTests:152`.
- Verify with the Mac build only.

**7. iOS dependency.**
- `ChatClient.answer` takes a `LeoChatAnswer`; update `ChatClient.swift:35,67`.
- Move `safeComponent` from `ChatClient.swift:150-156` to `ChatClient.safeComponent` and update lines 58–60.
- No new test: the move is pure, and `swift test` stays green.

**8. ChatThread reducer** (`ChatThread.swift:28-29,84-85,121-144,305-313`).
- State: `askDrafts: [String: LeoChatAskDraft]`.
- Actions: `askChoiceTapped(id, value)` (buttons submit at once; radio/checkboxes update the draft), `askTextChanged(id, text)`, `askSubmitTapped(id)`, `answerResponse(id, LeoChatAnswer, Result)`.
- `.settled`: drop the draft, show no alert, send `.resync`.
- `.invalid`: show an alert with the daemon's text and keep the draft.
- A merged message that is no longer open clears its draft.
- **Failing TestStore tests** (`ChatThreadTests`):
  - A buttons tap sends `{values:[v]}`.
  - Checkbox toggles don't submit; Submit sends the selection in option order.
  - Submit does nothing while the draft is invalid.
  - Text is trimmed on submit.
  - A 409 resyncs without an alert.
  - A 400 shows an alert and keeps the draft.
  - A `chat.updated` event with `answered` clears the draft.

**9. Notification answers** (`AppFeature.swift:211-230`).
- `.answer` sends `.choice(value)`.
- `.settled` is swallowed: no failure notification.
- **Failing test** in `AppFeatureChatTests`: a 409 posts no failure notification.

**10. iOS views** (TDD-exempt).
- `ChatMessageCell.addPromptControls` (`ChatMessageCell.swift:136-167`) renders by input type:
  - buttons as today;
  - radio as a checkmark list plus Submit;
  - checkboxes as a multi-select with a "Choose min–max" hint plus Submit;
  - text as a `UITextView` with placeholder and a 4000 counter;
  - an allow_text field under the choices.
- The answered state shows `answerSummary`, or "Answered in terminal".
- `Event` becomes `.choice / .text / .submit`, mapped in `ChatThreadViewController.swift:217`.
- Never overwrite a text view that is first responder when the cell is reconfigured.
- `continuesPost` means tight spacing and no header.
- Accessibility ids: `chat.ask.option.<v>`, `chat.ask.text`, `chat.ask.submit`.
- Check the result with a simulator screenshot of each type against an isolated daemon (isolated-daemon recipe).

**11. Remove surfaced files from iOS** (LeoKit `Surfaced/*` stays until WP2).
- **Delete:**
  - `ios/Leo/Files/*` (4 files)
  - `Features/Files.swift`
  - `Features/DiscardingPreviews.swift` (only `Files` uses it)
  - `Dependencies/SurfacedFileClient.swift` (includes `SeenFilesClient`)
  - `Models/FilePreviewKind.swift` (no other users)
  - Tests `FilesTests.swift` and `SurfacedFilesTests.swift`
- **Edit:**
  - `AgentDetail.swift:7,27-54,108` (the `.files` destination and `filesButtonTapped`)
  - `Fleet.swift:14-15,49-50,79-97,304-306,355-356`, where `daemonsLoaded` loses `seen:`
  - `AppFeature.swift:161,198,243,305`
  - `AppDelegate.swift:25-27,60-61`
  - `AgentDetailViewController.swift:79-80,203-222,259,270,288`
  - Test `Fixtures.swift:22-26,59-70`
  - `FleetTests:379`, `AppFeatureChatTests:155`, `AppFeaturePushTests:129`
  - `LeoE2ETests.swift`: lines 9–10, and rename `testTerminalAndSurfacedFiles` (75–139) to `testTerminal`, dropping the file assertions.
- Run `xcodegen generate`.

**WP1 done when:** LeoKit and LeoFeatures `swift test` pass, the iOS build and app tests pass, the Mac build succeeds, and LeoKit swiftlint is clean. Return the commit range.

---
## WP2: Mac (one `implement` run; needs WP1 merged into `ios`)

**12. LeoChatPaneModel.**
- Add `askDrafts`, `choose(messageID:value:)`, `setAskText(messageID:_:)`, `submitAsk(messageID:)` and `answer(messageID:_:LeoChatAnswer)`.
- A 409 calls `resync`; it sets no `notice`.
- A 400 sets `notice` to the daemon's text.
- **Failing tests** (`LeoChatPaneModelTests`, rewriting 152–173): the same cases as step 8.

**13. Mac views** (TDD-exempt). `LeoChatPromptButtons` becomes `LeoChatAskControls` in `LeoChatMessageRow.swift`:
- radio as a checkmark button group;
- checkboxes as `Toggle(.checkbox)`;
- `TextField(axis: .vertical)` with a counter;
- a `.borderedProminent` Submit button, with ⌘↩ to submit;
- the answered summary and "Answered in terminal";
- `continuesPost` spacing.
- Keep the composer focus routing from 9f9755c2e/022fe0cbc. Clicking a field in an ask must not send focus to the composer or the terminal.
- Check by screenshot (Peekaboo, `--capture-engine cg`), using only the autopilot-scratch agent.

**14. Remove surfaced files (one commit: LeoKit + Mac).**
- **Failing tests first:**
  - `LeoObserveTests`: a `file_surfaced` event decodes as `.other`.
  - `LeoObservedStateDecodingTests`: a snapshot with `surfaced_files` decodes and ignores it.
- **LeoKit:**
  - Delete `Surfaced/*` (3 files), `Remote/LeoSurfacedFileDownloader.swift`, and the tests `LeoSurfacedFile{Decoding,Index,Downloader}Tests`.
  - Edit `LeoActivityClient.swift:24-29,43,55-56,66,82-84,144,334-337,436`.
- **Mac:**
  - Delete `Surfaced/` except `LeoReadDeadline.swift`, which moves to `Editor/` without `surfacedOpen`.
  - Edit `LeoRuntime.swift:31-32,65,135,293,353-355,376,397`.
  - Edit `TerminalController.swift:2134-2135`.
  - Edit `MainMenu.xib:452-457`: drop the "Open Surfaced File" item, which frees ⌥⌘O.
  - Edit `LeoSidebarFeed.swift:100-104,152,161,335-336`, `+Metadata:83`, `+Fetch:73` and `LeoSidebarFeedTarget:84`.
  - Edit `LeoPollScheduler:152`, `LeoSidebarModel:59-79`, `LeoSidebarState:27-29,46-118` (`withSurfacedFiles`), `LeoAgentRow:77-79,98,146-150`, `LeoAgentRowContent:5,17-18,44,97-105` and `LeoSidebarView:385-386`.
  - Edit `Attention/LeoAttentionFixture:181`, and update the surfaced comments in `LeoRowPaneRouter:4` and `LeoRuntime+Editor:98`.
- **Mac tests:**
  - Delete `LeoSidebarFeedSurfacedFilesTests`, `LeoSurfaceFixtureTests`, `LeoSurfacedAutoOpenTests`, `LeoSurfacedFileIndexRowTests`, `LeoSurfacedFileOpenerTests` and `LeoSurfacedFileRoutingTests`.
  - Rename `LeoSurfacedReadDeadlineTests` to `LeoReadDeadlineTests` and drop the test at line 75.
  - Rename `LeoSurfacedPaneCommitTests` to `LeoEditorPaneCommitTests`.
  - Edit `LeoAgentRowHeightTests:79-90`, `LeoAttentionPresentationTests:141-144` and `LeoNoTabBarTests:206-208` (switch to a neutral ⌥⌘O fixture).

**WP2 done when** the final checklist passes. Return the commit range.

---
## Final verification checklist
- [ ] `Packages/LeoKit`: swiftlint is clean and `swift test` passes.
- [ ] `ios/LeoFeatures`: `swift test` passes.
- [ ] iOS: `xcodegen generate` leaves no diff; `build-for-testing` and `test-without-building` pass.
- [ ] Mac: `build-for-testing` with Xcode 26.3 passes; `run-unit-tests.sh` prints "All tests passed"; `macos` swiftlint is clean.
- [ ] `rg -n 'LeoSurfaced|surfacedFile|fileSurfaced|surfaced_files|file_surfaced|SurfacedFile|surfaceFixture|FilePreviewKind' Packages ios macos` returns nothing. "Surfaced" in the editor-link sense (`LeoEditorLink:35`, `LeoEditorTabs+Links:4,15`) is fine.
- [ ] Live check against an isolated daemon (leo #268 build): post a file, then ask with each of buttons, radio, checkboxes (min 1, max 2, allow_text) and text. Answer each on iOS and Mac and confirm the summaries.
- [ ] Settle an ask by curl while the app shows it as open; submitting must refetch with no error.
- [ ] Answer a permission in the terminal; the row must show "Answered in terminal".
- [ ] Notifications: a buttons ask shows buttons; a radio ask has no actions and opens the thread.
- [ ] Fresh-context `review` of each WP range. The severity bar: wire and contract mismatches, crashes, and lost answers are P0/P1.
