# Plan: Leo Chat AskUserQuestion questions card
Spec: `docs/superpowers/specs/2026-10-18-chat-askuserquestion.md` (source of truth). Platforms: **both**. Shared logic goes in LeoKit; each app gets only its card UI and glue.
Order: L1–L6 run in sequence (one `implement` run), then the Mac and iOS lanes run in parallel. Commit after each step.

## Decisions made from the code (nothing added beyond the spec)
1. **How "a new case carrying `[LeoChatQuestion]`" is done.** `LeoChatInput` is a struct with a `Kind` enum, so it gains `Kind.questions` plus `questions: [LeoChatQuestion]`, which is empty for the other kinds. Questions inputs are built by a new `init(questions:) throws(LeoChatInputError)`, and `init(kind:…)` refuses `.questions`. Decoding mirrors the leo spec: 1–4 questions, distinct non-empty ids, and each question's options checked by the existing `validate(_:)` (1–12 options, distinct, non-blank).
2. **The spec's `LeoChatMessageAnswer` is the existing `LeoChatAnswer`.** It gains `answers: [String: LeoChatAnswer]?`. The per-question wire shape `{values,text}` is identical, so the type is reused. The daemon always sends `values` (`[]` when empty), so the strict `values` decoding stays.
3. **`closed_reason`.** `LeoChatMessage` decodes `closed_reason` into `closedReason: String?`; it is needed to tell a dismissal from a timeout. It also has to be encoded and kept by `answered(_:)`. The daemon already sends it, with the values timeout, withdrawn and agent_gone.
4. **Unknown input types today.** `LeoChatInput` throws, that one message fails, and `LeoLenientArray` drops it with a log line; the rest of the page loads, and an event becomes `.other(seq:)`. Keep that behaviour and pin it at the page level. `questions` is itself an unknown type today, which is why L1's first test starts red.
5. **One settled-state mapping in LeoKit.** `LeoChatMessage.questionsCard` returns `LeoChatQuestionsCardState`, one of `.open / .answered(lines) / .inTerminal / .timedOut / .expired`, so both UIs read the same source.
   - `dismissed` maps to `.inTerminal`.
   - `timeout` maps to `.timedOut`.
   - Any other or missing reason maps to `.expired`, which shows the existing "Expired" label.
6. **Draft rules.** `LeoChatQuestionsDraft(questions:)` holds its questions, so `isComplete` and `answersPayload` can be plain properties as the spec names them.
   - Choosing the option that is already selected on a single-select question does nothing.
   - Blank text never clears the option.
   - Trimmed text over 4000 characters makes the draft incomplete.
7. **Errors.** Each card keeps its own error, `questionsErrors[messageID]`, on both platforms. Existing asks keep the Mac `notice` and the iOS alert. A 409 reuses the existing `refreshSettled` path with no notice and no alert.
8. **Client.** `answerQuestions` and `dismiss` share the answer route's status mapping, pulled out into one private helper: 409 → `LeoChatAnswerError.settled`, 400 → `.invalid`. Both return `LeoChatMessage?`, since the leo spec says dismiss returns `200 {ok,data:Message}`.

## LeoKit — `cd Packages/LeoKit && swift test --filter <Suite>`
**L1 Model and decoding.**
- Files:
  - `LeoChatModels.swift`: `LeoChatOption.description: String?` in its decoder and init.
  - New `Chat/LeoChatQuestions.swift`: `LeoChatQuestion {id, header, question, multi, allowText, options}`.
  - `LeoChatAsk.swift`: `Kind.questions`, `questions`, `init(questions:)`, `WireOption` gains `description`, decode and encode branches.
- Keep `main` building: add `case .questions: EmptyView()` to the exhaustive switch at `macos/…/LeoChatMessageRow.swift:185`. Grep for any other `switch` on `LeoChatInput.Kind`.
- Tests (new `LeoChatQuestionsTests.swift`), red first:
  - `decodesAQuestionsAskWithItsQuestionsAndOptionDescriptions`: `#expect(input.kind == .questions)`, `#expect(input.questions.map(\.id) == ["q1","q2"])`, `#expect(input.questions[1].multi)`, `#expect(input.questions[0].options[0].description == "Fast")`
  - `anOptionWithoutADescriptionHasNone`, on a buttons ask too
  - parameterized `anInvalidQuestionsInputFailsTheMessage`: 0 questions, 5 questions, duplicate ids, a question with no options, duplicate option values
  - `aQuestionsAskRoundTripsThroughItsOwnEncoding`
  - `aPageKeepsItsOtherMessagesWhenAnAskHasAnUnknownInputType`: `slider` ask + text message → `page.messages.map(\.id) == ["01JT"]`. This one passes before the change; note that in the commit.
- Run `--filter "LeoChatQuestionsTests|LeoChatDecodingTests"`. `slider` must still fail in `anInvalidInputFailsTheMessage`.

**L2 Answers, closed reason, helpers.** Files: `LeoChatAsk.swift`, `LeoChatModels.swift`.
- `LeoChatAnswer.answers` (decode/encode, `encodeIfPresent`).
- `LeoChatAnswer.isFromTerminal`: `values == ["terminal"]` and `answers == nil`.
- `LeoChatAnswer.summaryLines(for: [LeoChatQuestion]) -> [String]`. A question missing from the echo reads `header: None`.
- `LeoChatMessage.isAnsweredInTerminal` widened to questions asks; the `questionsCard` state.
- Tests in `LeoChatQuestionsTests`:
  - `decodesTheAnswersEchoOfAnAnsweredCard`: `#expect(answer.answers?["q2"] == LeoChatAnswer(values: [], text: "because"))`
  - `aTerminalAnswerHasNoAnswersAndSaysSo`: `isFromTerminal`, `questionsCard == .inTerminal`; an answer that has `answers` → `!isFromTerminal`
  - `summaryLinesReadHeaderThenLabelsThenQuotedText`: `== ["Library: Swift", "Scope: A, B, \"docs too\""]`
  - `aDismissedCardReadsAsInTerminalATimeoutAsTimedOut`: dismissed → `.inTerminal`, timeout → `.timedOut`, withdrawn → `.expired`, open → `.open`
- Existing `{"text":"x"}` must still fail to decode.

**L3 Draft.** New `Chat/LeoChatQuestionsDraft.swift`.
- API: `choosing(_:question:)`, `withText(_:question:)`, `values(for:)`, `text(for:)`, `isComplete`, `answersPayload: [String: LeoChatAnswer]`.
- Tests (new `LeoChatQuestionsDraftTests.swift`):
  - `choosingOnASingleSelectQuestionReplacesTheValueAndClearsTheText`
  - `typingNonBlankTextOnASingleSelectQuestionClearsTheOption`
  - `blankTextKeepsTheOption`
  - `multiSelectTogglesInOptionOrderAndKeepsTheText`
  - `unknownValuesAndQuestionIDsAreIgnored`
  - `isCompleteNeedsEveryQuestionAnswered`, as rows: nothing, one of two, whitespace-only text, 4001-character text → false; all answered → true
  - `thePayloadTrimsTextAndDropsBlankText`: `== ["q1": .choice("Swift"), "q2": LeoChatAnswer(values: [], text: "why")]`

**L4 Client.** `LeoChatClient.swift`.
- The protocol gains `answerQuestions(agent:messageID:answers:)` and `dismiss(agent:messageID:)`.
- The body is `{"answers":…}` with sorted keys; dismiss sends no body.
- In the same commit, add both methods to `macos/Tests/Leo/LeoChatTestSupport.swift` `FakeChatClient` (record the calls, script the results like `answerResult`) so the Mac tests still compile.
- Tests in `LeoChatClientTests`:
  - `answerQuestionsPostsTheAnswersMap`: path `/api/v1/chat/zeus/messages/01JA/answer`, body `== ["answers": ["q1": ["values": ["Swift"]]]]`
  - `dismissPostsAnEmptyBody`: path `…/01JA/dismiss`, `request.body == nil`
  - parameterized `aSettledCardIsItsOwnError`: 409 → `.settled`, 400 → `.invalid(reason)`, for both routes

**L5 Notifications (check only).**
- Add `"questions"` to the arguments of `anAskThatIsNotButtonsOpensTheApp`.
- Add `aQuestionsPushWithoutOptionsOpensTheApp`, expecting `askOpenCategoryID` with no actions.
- Expected to pass with no code change. If it fails, fix `category(for:)`.

**L6** Full `swift test` in `Packages/LeoKit`, plus `swiftlint lint --strict` on the changed files.

## Mac lane (after L6) — `bash macos/scripts/leo-runtests.sh <label>` (Xcode 26.3, full suite, log in `/tmp/leo-tests-<label>.log`)
**M1 Pane model, test-first** in `macos/Tests/Leo/LeoChatPaneModelTests.swift`.
- `LeoChatPaneModel` gains `questionsDrafts` and `questionsErrors` (both `[String: …]`, `@Published private(set)`).
- Methods: `questionsDraft(for:)`, `chooseQuestion(messageID:questionID:value:)`, `setQuestionText(messageID:questionID:_:)`, `submitQuestions(messageID:)`, `dismissQuestions(messageID:)`.
- Reuse `answering` and `refreshSettled`. `dropSettledAskDrafts` also clears the two new maps.
- Tests:
  - `submittingQuestionsPostsTheDraftAndMergesTheAnsweredCard`
  - `aSettledQuestionsCardRefetchesWithoutANotice`: `notice == nil`, draft gone
  - `aRefusedQuestionsAnswerShowsInlineAndKeepsTheDraft`: `questionsErrors["01"] != nil`, `answering.isEmpty`
  - `dismissPostsDismissAndMergesTheExpiredCard`

**M2 Card view** (styling, no unit tests). New `macos/Sources/Features/Leo/Chat/LeoChatQuestionsCard.swift`.
- For each question: the header in small caps (secondary), the question text, then the options.
  - Single-select options are radio rows; multi-select options use `.toggleStyle(.checkbox)`.
  - Each option shows its label, with the description as secondary text.
  - Then the "Other…" `TextField`.
- Footer: Submit (`.borderedProminent`, disabled unless `isComplete` and nothing is in flight) and "Answer in terminal" (`.bordered`). Inline red error text and a `ProgressView` while in flight. Controls disable during a request.
- Settled: one `Text` per summary line, or "Answered in terminal", "Timed out" or "Expired".
- Every control must be reachable with Tab. Use focusable controls; plain-style buttons may need `.focusable()` or a radio-group `Picker`.
- Accessibility ids: `chat.questions.<qid>.option.<value>`, `chat.questions.<qid>.text`, `chat.questions.submit`, `chat.questions.dismiss`.
- `LeoChatMessageRow.bubble` shows the card when `message.input?.kind == .questions`, and `LeoChatAskControls` otherwise.

**M3 Screenshots.** New `macos/Tests/Leo/LeoChatQuestionsCardSnapshots.swift`, enabled only when `LEO_CARD_SNAPSHOTS` is set.
- Fixture messages on `FakeChatClient`, one per state: open, partly filled (driven through the M1 methods), answered, terminal, dismissed, timed out.
- Host each `LeoChatMessageRow` in an offscreen `NSWindow` at chat-column width, in light and dark, and write PNGs.
- Run `LEO_CARD_SNAPSHOTS=$PWD/.autopilot/shots/questions-mac bash macos/scripts/leo-runtests.sh q-shots`, inspect at native pixels, and the orchestrator posts them.
- If v0.55.0 has shipped: a real AskUserQuestion on `autopilot-scratch` only, using the screenshot recipe in `.autopilot/verify.md`, including Tab moving between controls.

## iOS lane (after L6) — Xcode 26.5
**I1 Reducer and dependency, test-first** in `ios/LeoFeatures/Tests/LeoFeaturesTests/ChatThreadTests.swift`.
- `ChatClient.swift` gains `answerQuestions` and `dismiss` closures, plus their `liveValue` wiring.
- `ChatThread.State` gains `questionsDrafts` and `questionsErrors`; `merge` clears both once a card settles.
- New actions: `questionChoiceTapped(messageID:questionID:value:)`, `questionTextChanged(messageID:questionID:_:)`, `questionsSubmitTapped`, `questionsDismissTapped`, `questionsResponse(messageID:, Result<LeoChatMessage?, any Error>)`.
- Tests:
  - `choosingAQuestionOptionUpdatesOnlyItsDraft`
  - `submittingQuestionsSendsThePayloadAndMergesTheCard`
  - `aSettledQuestionsCardRefreshesWithoutAnAlert`: `alert == nil`
  - `aRefusedQuestionsAnswerShowsInlineAndKeepsTheDraft`
  - `dismissPostsDismissAndMergesTheExpiredCard`
- Run `cd ios/LeoFeatures && swift test --filter ChatThreadTests`.

**I2 Card UI.** New `ios/Leo/Chat/ChatQuestionsCard.swift`, a `UIStackView` kept across reconfigures, like `ChatAskControls`.
- One section per question id, each owning a persistent `UITextView` for "Other…".
  - It copies the `syncText` rule: take the draft's text unless that field is being edited, and reset when the message id changes.
- Option rows are full-width plain buttons: title, the description as subtitle, a radio or checkbox symbol, and height ≥ 44.
- Footer: Submit (borderedProminent, enabled only when `isComplete` and nothing is in flight) and "Answer in terminal" (bordered). An inline error label (systemRed), and the settled labels.
- `ChatMessageCell`:
  - `Event` gains `.questionChoice(questionID:value:)`, `.questionText(questionID:_:)`, `.questionsSubmit`, `.questionsDismiss`.
  - `Model` gains `questionsDraft` and `questionsError`.
  - `configure` keeps the card in place the way it keeps `askControls`.
  - `promptViews` sends `.questions` inputs to the card, and `focusedTextFrame` checks both kept views.
- `ChatThreadViewController`: build the cell model from the store (draft per message id) and map the new events in `handle(_:)`.
- Run `cd ios && xcodegen generate` and commit the regenerated project. Then: `xcodebuild build -project Leo.xcodeproj -scheme Leo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`.

**I3 Screenshots.**
- A DEBUG-only launch argument `-questionsCardFixture` shows a real `ChatThreadViewController` whose `ChatThread` store has `chatClient` and `secrets` overridden with fixture messages, one per state.
- New `ios/LeoUITests/LeoQuestionsCardTests.swift`:
  - It taps options and types into an "Other…" field.
  - It scrolls away and back, then asserts the typed text survives cell reuse.
  - It captures light and dark into `TEST_RUNNER_LEO_SCREENSHOTS`.
- Run `TEST_RUNNER_LEO_SCREENSHOTS=$PWD/../.autopilot/shots/questions-ios xcodebuild test … -only-testing:LeoUITests/LeoQuestionsCardTests`.

## Risks
- **The daemon is still changing.** If the shipped validation differs from L1's strict decoding, cards are silently dropped (a fault is logged). Re-check `input.go` against L1 before the Mac and iOS lanes start.
- **Two compile breaks** — the exhaustive Mac switch and the protocol conformers — are handled inside L1 and L4.
- **Mac keyboard focus.** Plain-style SwiftUI buttons aren't in the Tab order unless Full Keyboard Access is on, so this needs the live check.
- **iOS text views.** Several persistent text views per cell must not be rebuilt on every keystroke's reconfigure.
- **Dismiss with no returned message.** There is no local "dismissed" copy, so the card relies on `chat.updated` or a resync.

## Open questions
1. withdrawn or agent_gone on a questions card shows "Expired". OK?
2. Re-tapping the selected single-select option does nothing. OK?
3. The pane-model and reducer tests in M1/I1 follow the repo's test-first rule. The spec's "no unit tests" line is read as covering only the views. Confirm.
4. No character counter on "Other…" (the spec doesn't ask for one). Past 4000 characters Submit just stays disabled with no reason shown.
5. No ⌘↩ submit on Mac (spec silent).

## Orchestrator resolutions
1. `withdrawn`/`agent_gone` → "Expired": yes.
2. Re-tapping the selected single-select option does nothing: yes.
3. M1/I1 pane-model/reducer tests are required (test-first). The spec's "no unit tests" applies to views only.
4. Over 4000 chars: Submit stays disabled and a one-line inline hint shows under that field ("Too long — 4000 characters max"). No counter.
5. No ⌘↩ submit (YAGNI).
