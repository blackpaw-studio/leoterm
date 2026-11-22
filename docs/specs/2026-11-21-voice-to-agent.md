# Voice to Agent — Action Button, Siri, Shortcuts, Spotlight

Status: draft, awaiting approval · 2026-11-21

## Goal

Press the iPhone Action button (or ask Siri, run a Shortcut, use Spotlight), speak a message, and have it delivered to a Leo agent without opening the app. The reply arrives through the existing push notification path.

## Platform call

**Both.** Agent resolution and sending go in LeoKit. Each app adds a thin App Intents layer.
- iOS: an App Intent, an App Shortcut phrase, and a Control (`ControlWidget`) that can be assigned to the Action button, Control Center, or the Lock Screen.
- Mac: the same App Intent, exposed through Spotlight and Shortcuts. The Mac has no Action button or Control.

## Behaviour

1. **Intent `SendMessageToAgent`**, parameters:
   - `agent: AgentEntity?` (optional)
   - `message: String` (required). Siri asks for it by voice with "What should I tell <agent>?"
2. **Choosing the agent:**
   - Control or Shortcut configured with an agent: send to that agent with no prompt.
   - No agent configured: Siri asks "Which agent?" from the `AgentEntity` options (spoken names, disambiguation list).
   - The same agent name on two machines: the entity shows `name · machine`, and Siri disambiguates.
   - A configured agent that no longer exists: say "<agent> isn't available," then ask which agent.
3. **Sending:** one `POST /api/v1/chat/agents/<name>/messages` through the existing `LeoChatClient` and `LeoHTTPSTransport` with the paired daemon's credentials. No long-lived connection.
4. **Success:** Siri says "Sent to <agent>." The intent does not wait for a reply. The reply arrives as the normal chat push and can be answered from the banner (existing `leo.chat.reply`).
5. **Failure** (daemon unreachable, auth error, or timeout): Siri says "Couldn't reach <machine>." Leo also posts a local notification that keeps the message text and offers **Retry**. This reuses the existing failed-notification-reply pattern. The message is never silently dropped.
6. **No paired machines:** the intent says "Pair a machine in Leo first" and opens the app.

## Components

- **LeoKit:** a `LeoAgentMessageSender` that takes `(AgentRef, text)`, resolves the connection, sends, and returns a typed result (`sent` / `unreachable(machine)` / `unauthorized` / `agentMissing`). It also needs an agent query that lists `AgentRef`s across paired daemons for the entity. Platform-neutral, with injected dependencies, and unit-tested.
- **iOS app target:** `AgentEntity` + `EntityQuery`, `SendMessageToAgent`, and an `AppShortcutsProvider` ("Tell an agent in Leo"). **The intent runs in the app process**, so it can read the existing default-group Keychain secrets (`SecretsClient`) with no new access group.
- **iOS widget extension (new XcodeGen target):** the `ControlWidget` only, configurable with an optional `AgentEntity`. It hands off to the in-app intent and holds no secrets.
- **Mac app:** `AgentEntity` + `SendMessageToAgent` backed by the Mac's existing per-machine `LeoChatClient`, plus an App Shortcuts phrase for Spotlight.

## Out of scope (backlog)

- An in-app voice composer with live transcription (`SFSpeechRecognizer`).
- Reading the agent's reply aloud.
- Attachments, and replies to a specific message.
- A "last used agent" default.

## Risks to prove first

1. **Background reachability:** a backgrounded or locked phone completing the POST inside the intent's time budget, over cellular through Cloudflare Access. The first plan step is a device spike.
2. **Configured Control → in-app intent:** whether a Control with a parameter can run an app-process intent without opening the app. If it can't, the fallback is the Control opening a minimal confirmation in the app.
3. **Keychain while locked:** secrets use `AfterFirstUnlockThisDeviceOnly`, so they should be readable once the phone has been unlocked after boot. Before first unlock, return the failure path.

## Testing

- Unit tests (LeoKit): agent resolution (configured, missing, duplicate names across machines), the mapping from send result to spoken dialog, and the failure that produces a retry notification payload. Transport mocked at the HTTP boundary.
- Device check (manual, required for done): Action button with an agent configured; with none configured, so Siri asks; daemon unreachable, so Retry appears; locked phone. Mac: Spotlight "Tell an agent in Leo".
