# Agent Toolbar: tool toggles and agent menu

- **Date:** 2026-11-12
- **Status:** Evan chose option C on 2026-11-12, "exactly as mocked, HIG-compliant".
- **Mockup:** https://claude.ai/artifact/CPqu4XoJGsGTyhM3fgP9sy (option C).
- **Platform:** Mac only. iOS has its own tab bar and no Files or Browser panes.
- **Code:** `macos/Sources/Features/Leo/Toolbar/LeoAgentToolbar.swift` (NSToolbar).

## Goal

Make Files, the Agent Browser and per-agent actions reachable from the window toolbar. Today Files and the Browser open only from the sidebar's right-click menu.

## Toolbar layout

The toolbar uses three functional groups (HIG: at most three) on Liquid Glass, with no custom backgrounds.

**Leading**
- Sidebar toggle. It is unchanged and appears only while the sidebar is collapsed.
- **Agent title menu.** The title and subtitle (`<cwd> · <harness>`) become a pull-down (`NSMenuToolbarItem` or a title-styled pull-down) with a ▾ indicator. The title text itself is unchanged.

**Center**
- Status capsule, unchanged.

**Trailing**, three glass groups:
1. **Tool toggles.** Three icon-only toggles, each showing an on state while its panel is open:
   - **Files** (`folder`): the workspace browser pane, the same as Agents ▸ Browse Agent Files (⌥⌘B).
   - **Browser** (`globe`): the agent's browser in the row's pane. When the Agent browser setting is off, this item is removed, not disabled.
   - **Agent Pane** (`rectangle.bottomthird.inset.filled`, or the nearest symbol): the bottom drawer.
2. **Terminal | Chat.** The segmented control shows a symbol plus a text label in both segments (today it is symbols only). HIG: the same content kind in every segment, and noun labels. The unread count on Chat stays.
3. **Interrupt and ⋯** share one glass group. Interrupt is unchanged. ⋯ keeps Interrupt, Compact Context, Clear Conversation…, Show Messages ▸ and the plugin views.

**Browser badge:** the Browser toggle shows a count (`NSItemBadge`) of tabs the agent opened in its browser since you last showed it. The badge is hidden at zero. If the browser can't tell agent-opened tabs from user-opened ones, the plan drops the badge and says so.

**Scope:** every item acts on the agent shown in this window. With no agent shown (a plain terminal or the start screen), the toggles and the title menu are disabled, the same rule Interrupt uses today. The title still shows the window title.

## Agent title menu

These items come from the sidebar right-click menu, in this order:

1. Start, Stop, Restart. Only the ones valid for the agent's state are enabled.
2. Separator.
3. **Reveal Workspace in Finder** (new). Disabled for an agent on another machine, or when the workspace path is gone.
4. **Copy Workspace Path** (new). For a remote agent it copies the remote path.
5. Separator.
6. View Logs, Move To ▸, Rename…, Appearance…, Open in New Window.

Delete… stays in the sidebar menu only, so a destructive action isn't in a menu people click often.

Each item reuses the existing action the sidebar menu calls. There is no second implementation.

## Menu bar

HIG: every toolbar action must also be in the menu bar, and Show/Hide titles reflect state.

- **View ▸ Show/Hide Files (⌥⌘B).** Agents ▸ Browse Agent Files moves here, keeping its shortcut and behaviour.
- **View ▸ Show/Hide Agent Browser:** new.
- **View ▸ Show/Hide Agent Pane:** renames "Toggle Agent Pane", and the title follows its state.
- **View ▸ Customize Toolbar…** and **Show/Hide Toolbar (⌥⌘T):** standard items, added if missing.
- **Agents ▸ Reveal Workspace in Finder** and **Agents ▸ Copy Workspace Path:** new. Also add both to the sidebar right-click menu, next to Browse Files.

New shortcuts:
- Any new shortcut must not collide with Ghostty's default keybindings or an existing Leo menu item.
- Where Ghostty or Leo already uses the key, the menu item ships with no shortcut, and users can bind one in macOS settings.
- Candidates: ⇧⌘R for Reveal and ⌥⌘C for Copy Path. The plan verifies them.

## Customization

- Turn on `allowsUserCustomization` and `autosavesConfiguration`. The default set is the layout above.
- **Removable, and movable within the center and trailing area:** the tool toggles, the status capsule and Interrupt.
- **Always present and not removable** (`toolbarImmovableItemIdentifiers` or the equivalent): the title menu, Terminal | Chat and ⋯.
- Each item has:
  - a palette label: "Files", "Browser", "Agent Pane", "Status", "View", "Interrupt", "More";
  - a tooltip;
  - an accessibility label, with the toggle state exposed as selected or not selected.

## Narrow windows

- The subtitle hides first, as today.
- After that, NSToolbar's own overflow folds items in this order: the tool toggles, then Interrupt.
- No manual overflow menu is added.

## Testing

**Unit tests (pure logic):**
- which items are enabled for each agent state (no agent, local, remote, stopped or running, Agent browser off);
- title-menu item enablement, including Reveal being disabled for remote agents and for a missing path;
- Show/Hide titles following state;
- the default and immovable item sets.

**App:**
- a launch check (exit 124 means alive);
- a customization round-trip, checking that the configuration survives a relaunch.

**E2E** in an isolated debug app with a scratch daemon:
- each toggle opens and closes its panel, and the on state follows;
- the title menu actions work;
- Reveal opens Finder at the workspace;
- the Customize Toolbar sheet;
- a narrow-window overflow;
- VoiceOver labels;
- screenshots in light and dark, wide and narrow. Inspect each one before posting.

## Out of scope

- An "Open in Editor" item. Evan dropped it on 2026-11-12.
- A Browser or plugin views in the Terminal | Chat switch (option B).
- Any change to the sidebar's Delete flow.
- iOS.
