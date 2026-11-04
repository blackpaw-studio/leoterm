# Mac agent window toolbar + activity capsule

Status: DRAFT 2026-11-04 · Platform: **Mac only**. iOS already has a nav bar and its own progress panel, so it doesn't change.
Mockup: `docs/mockups/2026-11-03-agent-progress/v2-C.png` (option C, branch `docs/progress-design-v2` e057eb4f1).
This spec supersedes the Mac surfaces in `2026-11-03-agent-progress.md`: the pane-header strip (Detail B) and the chat progress card (Chat panel B). The row popover (Detail A), the iOS surfaces, and the daemon contract don't change.

## Why
Today an agent window has a hidden titlebar. The terminal has no header, progress sits in an overlay strip above the terminal, chat has its own SwiftUI header, and Terminal/Chat is a square segmented control in the bottom bar. Evan picked option C: a real Mac toolbar that carries the agent's identity and a centered activity capsule, in the style of Xcode. Progress then costs the terminal no vertical space.

## Toolbar (agent windows only)
- A unified `NSToolbar` in the Liquid Glass style, with the standard traffic lights showing. Settings, browser and editor side panes keep their own chrome.
- **Leading:** the agent name as the window title, with the subtitle `<cwd, ~-abbreviated> · <harness>`. These come from `NSWindow.title` / `subtitle`, so Window menu, Mission Control and VoiceOver get them for free. The sidebar toggle appears when the sidebar is collapsed.
- **Center:** the activity capsule (below), a centered toolbar item.
- **Trailing:** a "⋯" menu holding Interrupt, Compact Context and Clear (same actions and shortcuts as the Agents menu), plus "Show Messages ▸" (All Messages / per task, from today's chat task filter).
- In full screen the toolbar follows the standard reveal behavior.
- The sidebar header's fixed titlebar inset is replaced by the toolbar's real safe area. The sidebar keeps its look.

## Activity capsule
- Shows whenever the selected agent has at least one task, in both Terminal and Chat view. It is hidden when there are none and leaves no gap.
- It is a 32 pt capsule with a max width of 500 pt. Contents:
  - a spinner (running), or a status glyph when ended (✓ succeeded, ⚠ failed, ⊘ cancelled);
  - the primary task title (semibold) and its status/ETA text (secondary);
  - a 4 pt determinate bar along the bottom edge (indeterminate shimmer when no fraction is set);
  - a count badge when there are 2 or more tasks, red when any task has failed.
- The primary task uses the existing order: failed agent task, running agent task, running auto task, ended.
- At narrow widths the status text drops first and the title truncates. Spinner, badge and bar always stay.
- Click opens a popover titled "Tasks" with a "3 · 1 failed" summary, listing every task in primary order:
  - each row has a 32 pt icon tile, the title, a bar and a status line;
  - ended tasks get Dismiss (same rules as today: running → not dismissable, auto tasks never);
  - **no stop buttons**, because nothing can stop a task.
- Keyboard and accessibility:
  - the capsule is a focusable toolbar item (Space or Return opens the popover);
  - its VoiceOver label is `<title>, <status>, <n> tasks`;
  - Reduce Motion replaces the shimmer and spinner animation with static states.

## Removed
- The `LeoTaskStrip` overlay above the terminal.
- The chat progress card.
- The chat pane header: name, filter and Close Chat move to the toolbar or the switcher. The file-viewer header (Back, file name, actions) stays in the content area.

## Terminal/Chat switcher
- It stays in the bottom control bar beside the composer, but becomes a capsule. Each segment is a capsule, and the selected one is accent-filled with white text, matching the mockup.
- It is still a system segmented control. If AppKit can't produce the shape (verify), a custom control has to match its accessibility: the "View" label and the selected-state trait.
- New: View ▸ Terminal and View ▸ Chat menu items with shortcuts. The plan picks shortcuts that collide with nothing existing (Ghostty binds ⌘1–9).
- The unread badge stays.

## Testing
- Model tests (TDD) for the capsule presentation:
  - primary pick;
  - badge count and red-on-failure;
  - narrow-width degradation states;
  - VoiceOver label;
  - hidden when there are no tasks.
- Titlebar style tests updated for the toolbar. A launch check confirms the window still opens (see the NSSplitView launch-crash memory).
- Screenshots from the isolated debug build, light and dark:
  - one task, three tasks with the popover open, no tasks;
  - a 480 pt narrow window;
  - Chat view;
  - full screen.

## Out of scope
- iOS.
- Stopping tasks.
- Toolbar customization (`allowsUserCustomization` stays off).
- The browser and editor pane headers.
- The apps half of automatic tasks (plan D2): it lands after this, into the popover.
