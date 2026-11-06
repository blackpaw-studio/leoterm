# Remote image paste

**Status:** draft · **Platform:** Mac only (iOS terminal is read-only with no paste; iOS chat already pastes images)

## Problem

Ctrl+V image paste into Claude Code works for agents on the local Mac but not for agents on a remote machine. Claude Code reads the clipboard of the host it runs on, and the image is on the Mac's clipboard. ⌘V doesn't help either: Ghostty's paste only carries text, so an image-only clipboard pastes nothing.

## Goal

Pasting an image into a remote agent's terminal attaches it in Claude Code, the same as it does locally.

## Behaviour

Applies only to terminal surfaces attached to an agent on a **remote** machine. These are surfaces where `fileDropContext(for:)` (`LeoRuntime+FileDrop.swift`) resolves to a non-local host. Local agents, dispatch panes (already excluded from file drop), and plain terminals keep today's behaviour.

| Key | Clipboard | Result |
|---|---|---|
| Ctrl+V | contains an image (with or without text) | Upload the image and paste its remote path. Ctrl+V is **not** sent to the pty. |
| Ctrl+V | no image | Unchanged: 0x16 goes to the pty. |
| ⌘V | image and **no** text | Upload the image and paste its remote path. |
| ⌘V | has text | Unchanged: normal text paste. |

Upload and insert reuse the existing Finder-file-drop path (`performFileDrop` → `LeoTerminalFileDropQueue`):
1. Write the image as PNG to a local temp file named `leo-paste-<timestamp>.png`.
2. Enqueue it exactly like a dropped file.
3. The queue uploads it over the machine's ssh ControlMaster/sftp and inserts the shell-quoted remote path, as a drop does.

Claude Code recognises a pasted image path and attaches it.

The image is read from the first pasteboard image type available (PNG, TIFF, or anything NSImage reads) and normalised to PNG.

## Errors

- If the upload fails, use whatever feedback the file-drop queue already gives for a failed drop. Insert nothing.
- Remove the local temp file once the queue has finished with it, whether the upload succeeded or failed.

## Out of scope

- Remote temp-file cleanup, which follows whatever file drop does today.
- Local agents.
- iOS.
- Pasting multiple images at once.
- Any change to keybind config. This is app-level handling, not a new Ghostty action.

## Testing

- Pure logic, unit-tested first: the decision table above. Inputs are the key (Ctrl+V or ⌘V), the clipboard contents (image, text) and the surface kind (remote agent, local agent, dispatch, plain). Output is upload-image, pass-through, or text-paste.
- PNG normalisation from a TIFF pasteboard item, unit-tested.
- Manual end-to-end check: from the Mac app, paste a screenshot into a Dionysus agent running Claude Code. It shows `[Image #1]`.
