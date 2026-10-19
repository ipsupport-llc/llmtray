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

**Outside text.** A page or a window can carry instructions, in its text
or in a title. What's shown stays in the conversation, so a chat that has
shown anything is treated like one with pinned files from then on
(`ToolTrust.TurnState.sharedText`, set at every turn's start): no network
tools or generators in it. A new chat has them again.

## App Store

The sandboxed build (adr/0018) has the window and screen capture: the
picker needs no entitlement and no permission. It has no **Attach Current
Tab**: Apple Events to browsers need a temporary-exception entitlement
App Review is unlikely to accept. Compiled out (`#if !APP_STORE`), not
shown disabled.

## Reading a web page (2026-10-19)

`web_search` reads a page as one more of its sources (`source=page`, `url`,
`page`): one tool for small models, its own switch in the profile ("Read
web pages", a network tool -- off by default, refused after outside text
like the others). Both builds.

- A fresh load, not the user's tab: an ephemeral session, no cookies,
  nothing on disk; the page's article or main part when it holds the
  text, else all of it; about 4000 characters a page, "page=2" for more.
- A page that's only scripts is rendered in an offscreen WKWebView
  (non-persistent store, 15 s) and read the same way.
- Nothing on this Mac or the local network, in two layers. Every load of
  a read -- the page, its redirects, and in WebKit everything the page
  asks for, WebSockets too -- goes through a CONNECT proxy of its own on
  loopback (WebPageProxy): it resolves the host itself, refuses one that
  is or resolves to a local or private address, and connects to the very
  address it checked, so DNS rebinding can't slip through. Address
  literals don't go through a proxy in WebKit: content rules block local
  and private ones (WebKit writes 2130706433 as 127.0.0.1 before the
  rules see it), "localhost", IPv6 literals and addresses with a user
  name. Without the rules nothing is rendered. Checked with a probe page:
  without the two layers it reached a local server 7 times, with them 0.
- The proxy is the read's own: a password per read (407 otherwise), no
  failover to a direct connection; addresses on a network this Mac is on
  (its interfaces' networks, embedded IPv4 in mapped, NAT64 and 6to4
  addresses too) are refused as local. The WebKit view runs in Lockdown
  Mode: no WebRTC (its sockets go around any proxy) in any frame, no
  WebAssembly or JIT -- checked: RTCPeerConnection is undefined in the
  page and a new iframe, scripts and fetch still run.
- Limits: 5 MB of HTML (counted as it comes), 25 MB and 25 s for all a
  read loads, 20 s for a render, 400 000 characters of rendered text;
  one read at a time, the next waits.
- The page's own encoding (the server's charset, or its meta tag); the
  largest article, or main, found outside comments and scripts.
- Read pages are kept ten minutes in memory, so the next page is free.

## Later (not in this change)

- **Walkthrough**: after a capture, "Done — show again" re-captures the
  same window after each step the model gives; a strip over the composer
  says what's shared and ends it. Snapshots only, each on a click.
- **`look_at_screen`**: a tool the model calls during a walkthrough; each
  call is a card in the chat ("Show Safari again? · Capture · Skip").
  Never a capture without the click.

- The focused window's accessibility text (exact labels, cheap) —
  standalone only.
