# Chat follows the agent's machine: real-app evidence

Run 2026-10-22 (EDT), branch `fix/chat-follows-machine`, Debug `Leo.app` built from the
branch with Xcode 26.3. Plan step 5.3; the bug is "every agent on a remote machine shows
`<Machine> isn't connected.`".

## Rig

A scratch rig on the build host, not a Tart VM (see "Differences from the S11 topology").

- **This Mac**: an isolated leo 0.58.0 daemon (`HOME`, `CFFIXED_USER_HOME`, `TMUX_TMPDIR` and
  the config all under a scratch directory), scratch agent `cfm-mac`.
- **Box** (the remote): a second isolated leo 0.58.0 daemon with scratch agent `cfm-box`. The
  app reaches it as a configured machine, `evan@localhost`, over the real ssh tunnel path, with
  `remoteSocketPath` pointing at the scratch daemon's socket.
- Both agents run a fake `claude` that idles, so nothing talks to a model. Chat history is
  seeded through the daemon's own `chat/post` route with a scratch API client, so every
  bubble reads "via poster".
- The app ran on its own `UserDefaults` suite (`GHOSTTY_USER_DEFAULTS_SUITE`), so no real
  machine config was involved. Only the two scratch agents were ever in the sidebar, and no key
  was sent to the app. Every interaction was a menu click or a row click, each followed by a
  screenshot.

## What the screenshots show

| File | State |
|---|---|
| `01-sidebar.png` | Both machines connected. `cfm-box` on Box carries an unread badge of 2: Box's unread seeded from Box's own daemon. Before the fix, remote agents never had one. |
| `02-box-chat-loaded.png` | Selecting `cfm-box` loads its thread from Box (the reported bug: this pane read "Box isn't connected."). Chat auto-opened for the unread agent and marked it read. |
| `03-box-live-message.png` | A message posted to Box's daemon while the thread was open appears live. |
| `04-box-connection-failed.png`, `04b-box-reconnecting.png` | Box's daemon stopped. The machine goes to "Connection failed" (with Reconnect) and then "Reconnecting…". Its agent row disappears, its unread badge is gone, and the Chat pane closed with the selection. |
| `05-box-after-restart.png`, `05-box-reconnected.png` | Box's daemon restarted. The registry's own retry reconnected it, the selection came back, and the thread reloaded, including messages posted while it was down. |
| `06-this-mac-chat.png` | Control: This Mac's agent still loads its own thread. |

## Notes and gaps

- **The "isn't connected." text was not visible in the app.** When a machine drops, the
  sidebar removes its agent rows and the selection with them, so the pane closes before the
  chat pane could show the message. The message state is covered by
  `chatShowsNotConnectedOnlyWhileItsMachineIsDownAndReloadsOnReconnect` and
  `aRemovedMachineDropsItsChatClientAndUnreadCounts` (`LeoRuntimeMachinesTests`). It matters
  where a selection survives a drop; the pane model keeps it as its plan describes.
- **The Reconnect button was not clicked.** The machine's own auto-retry reconnected before I
  could (the button is visible in `04-box-connection-failed.png`). The reload after
  reconnect is what `05-*` shows, whichever path triggers it.
- **Auto-open of Chat over a terminal on a live agent message** was not exercised: it needs
  the terminal pane showing the agent. The auto-open gate (`isBound(host)`) is covered in unit
  tests only.
- **Replying from the composer** was not exercised: typing into a pane is what the keystroke
  safety rule forbids without extra care, and the scratch agents made it low risk but it is
  outside what this check set out to show.
- **A first, aborted launch** (about 30 s, before the defaults suite was set) used the Debug
  bundle's normal `studio.blackpaw.leo.macos.debug` defaults: `CFFIXED_USER_HOME` does not
  isolate `cfprefsd`. It only showed the sidebar and was quit; the app's real preferences
  were not edited by hand.
- **The machine's template fetch over ssh to `localhost`** runs the real
  `~/.local/bin/leo template list --json` (read-only) against the production daemon, because
  an ssh login lands in the real home. Nothing else touched production.

## Differences from the S11 topology

The Tart VM and containers from S11 were not used. A two-VM boot was far heavier than needed
to check this change: the machine tunnel, the daemon and the app are the same code paths over
ssh to localhost, and the rig is isolated by `HOME`, tmux socket and defaults suite. What a VM
would add is a clean OS image and a different host, neither of which this change depends on.

## Clean-up

Both daemons, their tmux servers, the app and the leftover ssh tunnel were stopped, and the
defaults suite was deleted. The scratch directory under the session temp folder holds the
rig scripts and can be removed.
