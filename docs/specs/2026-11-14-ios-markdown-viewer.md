# iOS: rendered Markdown viewer

Approved by Evan 2026-11-14 ("Build it now").

## Problem
On iOS, a `.md` file opened from Leo Chat goes to QuickLook (`ios/Leo/Chat/ChatPresentation.swift`, `ChatQuickLookController`), which shows Markdown as raw text. The Mac renders Markdown natively (`macos/Sources/Features/Leo/Editor/Markdown/LeoMarkdownRenderer.swift`, B-278), but that renderer is AppKit/TextKit 1 (`NSTextTable`) and can't run on iOS.

## Behavior
- Tapping a `.md` / `.markdown` chat attachment opens a native UIKit viewer (no WKWebView), showing headings, paragraphs, emphasis/strong/code spans, links, ordered/unordered/nested lists, code blocks, block quotes, thematic breaks and GitHub tables.
- A Rendered/Raw segmented toggle in the navigation bar; Rendered is the default. Raw is selectable monospaced text.
- Same safety rules as the Mac: images show alt text and are never fetched; only http, https and mailto links are tappable; other links are plain text. Input the parser can't take shows as plain text; never crash.
- Wide tables scroll horizontally instead of squashing; Dynamic Type and light/dark mode respected.
- Share/Open-in remains available (as QuickLook offered).
- Every other file type keeps opening in QuickLook.

## Shape
- Platform-neutral parsing (Markdown → block model: block kind, nesting, inline runs with link/emphasis attributes, table cells) lives in LeoKit with unit tests. The Mac renderer may adopt it only if that is a small, low-risk change; otherwise leave the Mac untouched.
- iOS-only UI and layout in `ios/Leo/Chat/` (UIKit; the iOS app is UIKit + TCA, no SwiftUI).

## Out
Editing, WebView rendering, other file types, Markdown in chat message bodies, remote image loading.

## Mac/iOS
iOS only for UI (the Mac already renders Markdown). Shared parsing in LeoKit.

## Done
LeoKit tests for the block model (headings, nested lists, tables, code, links filtering, malformed input); iOS build + tests pass; simulator screenshots of a sample doc in light and dark, Raw mode, and a wide table scrolled.
