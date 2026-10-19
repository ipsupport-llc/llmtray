# 0030 — Showing the model a window, the screen or a browser tab

**Status: accepted** (2026-10-18, by the user: "давай первые 2", with the
App Store gate from the start). Designed with codex, muse and Devin.

## Why

"I can't do X, help me": the user is stuck in an app or on a web page and
wants the local model to see what they see. Describing a settings window
in words is the hard part; showing it is one click.

## Decision

Two ways to show, both from the composer's + menu, both off until
Settings › Files › "Windows and pages" is on (every heavy feature is
opt-in):

- **Show a Window… / Show the Screen…** — Apple's content-sharing picker
  (ScreenCaptureKit `SCContentSharingPicker`), one still
  (`SCScreenshotManager`), no cursor, LLMTray's own windows not offered.
  The user's click in the system picker is the consent: no Screen
  Recording permission is asked for, nothing is captured without it, and
  nothing is captured again later. The popover steps aside while the
  picker is up and comes back with the capture.
  - A model that sees gets the image (the usual attachment: PNG, long side
    at most 2048 px) and a line naming what it is ("Window: Safari —
    Account settings").
  - A model that doesn't gets the window's text instead, read on this Mac
    with Vision's text recognition, top to bottom, at most
    `SharedContext.maxText` characters, and told that it's recognized text
    (icons and states can be missing).
- **Attach Current Tab** — the front tab of Safari or a Chromium browser
  (Chrome, Edge, Brave, Arc, Vivaldi), the browser that was in front
  before LLMTray: its title, address and readable text through Apple
  Events. Safari gives the page text itself; Chromium browsers run a
  fixed script of ours (never model text) and need "Allow JavaScript from
  Apple Events" — without it the tab still goes, title and address only,
  and the composer says how to turn it on. macOS asks once per browser
  (Automation).

What's shown appears as a chip in the composer (preview, remove) and in
the sent message; it's saved with the chat like an attachment (a
temporary chat saves nothing). The text goes with that message only, as
a block marked as the user's shared window or page.

**Outside text.** A page or a window can carry instructions. A turn whose
message carries shared text is treated like one with pinned files
(`ToolTrust.TurnState.sharedText`): no network tools or generators in it.

## App Store

The sandboxed build (adr/0018) has the window and screen capture: the
picker needs no entitlement and no permission. It has no **Attach Current
Tab**: Apple Events to browsers need a temporary-exception entitlement
App Review is unlikely to accept. Compiled out (`#if !APP_STORE`), not
shown disabled.

## Later (not in this change)

- **Walkthrough**: after a capture, "Done — show again" re-captures the
  same window after each step the model gives; a strip over the composer
  says what's shared and ends it. Snapshots only, each on a click.
- **`look_at_screen`**: a tool the model calls during a walkthrough; each
  call is a card in the chat ("Show Safari again? · Capture · Skip").
  Never a capture without the click.
- **`web_page(url)`**: a page loaded fresh in an offscreen WKWebView with
  no cookies (not the user's tab), read in pages; both builds.
- The focused window's accessibility text (exact labels, cheap) —
  standalone only.
