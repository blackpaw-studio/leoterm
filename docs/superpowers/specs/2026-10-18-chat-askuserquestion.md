# Leo Chat: AskUserQuestion as a questions card

Platforms: **both**. The model, draft logic and validation are shared in LeoKit; Mac (SwiftUI) and iOS (UIKit) each build their own card UI.

## Problem
Claude's AskUserQuestion arrives in chat as a generic permission bubble: clipped JSON with Allow/Deny. The user can't see or pick the options.

## Server contract (leo daemon v0.55.0, feature flag `chat.questions`)
- **Message:** kind `ask` with no `permission` field. `input = {type:"questions", questions:[{id, header, question, multi, allow_text:true, options:[{value, label, description?}]}]}`.
  - Ids are `q1..qN`.
  - `value == label`.
- **Answer:** `POST /messages/{id}/answer {answers:{"q1":{values:[…], text?}}}`.
  - Every question is required. A question counts as answered when it has at least one value or non-blank text.
  - Single-select takes one value or text, not both.
  - Multi-select takes any set of distinct values, plus optional text.
  - Text is at most 4000 runes.
  - Responses: 400 for a bad shape, 409 if the card is already settled.
- **Dismiss:** `POST /messages/{id}/dismiss` with an empty body. The message becomes `expired` with `closed_reason:"dismissed"`, and the terminal dialog takes over.
- **Answered:** `state:"answered"`, with `answer.answers` echoing what was submitted.
  - If the question was answered in the terminal, the answer is `{values:["terminal"]}` and has no `answers`.
- **Timeout:** `expired` with `closed_reason:"timeout"`. Late answers get 409.
- **Push:** the normal chat push with `input_type:"questions"`. It must not use the Allow/Deny category.

## Design
### LeoKit
- **`LeoChatInput`:** decodes `type:"questions"` into a new case carrying `[LeoChatQuestion]`.
  - `LeoChatQuestion` has `id`, `header`, `question`, `multi`, `allowText`, and `options`.
  - `LeoChatOption` gains an optional `description`.
- **Unknown input types:** they must keep decoding without throwing, so the whole transcript still loads. Check what happens today and keep that behavior.
- **`LeoChatQuestionsDraft`:** a pure, immutable value type that holds each question's selected values and free text.
  - Choosing an option on a single-select question clears its text. Typing non-blank text clears the option.
  - `isComplete` mirrors the server rules.
  - `answersPayload` produces the request body, trimming text and dropping blank text.
- **`LeoChatMessageAnswer`:** decodes the optional `answers` map.
  - Add a helper that reports whether the card was answered in the terminal.
  - Add a helper that gives one display line per question: `header: label, label, "text"`.
- **`LeoChatClient`:**
  - `answerQuestions(agent:messageID:answers:)` posts to `/answer`.
  - `dismiss(agent:messageID:)` posts to `/dismiss`.
  - Both surface 409 as a distinct "already settled" error.

### Card UI (Mac and iOS)
- **Open card:** for each question:
  - The header as a small caps label, then the question text.
  - Options as radio buttons (single-select) or checkboxes (multi-select). Each option shows its label and, when present, its description as secondary text.
  - An "Other…" text field.
- **Footer:**
  - **Submit:** the primary button, enabled only when `isComplete`.
  - **Answer in terminal:** a secondary button that dismisses the card.
- **After submit:**
  - The controls disable while the request is in flight.
  - On a 409 the card refreshes and shows its settled state, with no error toast.
  - Other errors show inline and the controls re-enable.
- **Settled card:**
  - Answered: a read-only summary with one line per question.
  - Answered in the terminal, or dismissed: "Answered in terminal".
  - Timed out: "Timed out".
- **Platform differences:**
  - Mac sits in the chat column at bubble width and supports keyboard focus between controls.
  - iOS goes in the chat cell with full-width tap targets (44pt minimum). On iOS the text field must not lose its draft when the cell is reused; keep the draft per message id in the pane state, not in the cell.
- **Notifications:** a `questions` push uses the default open-chat category on both platforms. Verify this in `LeoChatNotificationActions`.

## Testing
- **LeoKit unit tests (test-first):**
  - Decoding `questions` input, and the `answers` and terminal answer shapes.
  - Draft rules: exclusivity on single-select questions, `isComplete`, trimming, and the payload shape.
  - Client request paths and bodies, plus mapping a 409 to its error.
  - Unknown input types keep decoding.
- **UI:** no unit tests, because these are styling changes. Instead, take screenshots of the Mac and iOS card in each state (open, partially filled, answered, terminal, timed out) against an isolated v0.55.0 daemon, or a fixture message if the daemon hasn't shipped yet.

## Out of scope
- Daemon and hook changes. The `leo` agent owns these.
- Gating on the `chat.questions` flag. Older daemons never send this type.
