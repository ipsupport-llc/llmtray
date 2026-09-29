# 0017 — Support LLMTray (tips, a supporters list)

**Status: accepted** (2026-09-29: the user's brief; the open questions answered by the user or decided here at the user's request).

## Why

LLMTray is free and stays free. People who find it useful should be able
to pay for its development, and those who want to should be thanked in
public. Nothing is sold: a tip unlocks nothing.

The user's brief:

- An optional **Support LLMTray** feature using StoreKit in-app purchase.
- Three tiers: **Coffee $4.99**, **Pro Supporter $24.99**, **Founding
  Supporter $149.99**.
- No feature is locked; everything stays free.
- After a purchase, offer an opt-in **"List my name in Supporters"**. The
  user chooses the public display name. An Apple ID or email is never
  published automatically.
- Supporters are shown in About / Credits. Founding Supporters look
  distinct.
- The list loads from a **signed remote manifest**, so it updates without
  an app release.
- App Store copy: **"No subscriptions. No feature locks. Support
  development if LLMTray is useful to you."**

## Decision

### 1. Where purchases happen

- **Mac App Store build** (separate build, to be decided in its own ADR):
  StoreKit 2 in-app purchases. Apple's guideline 3.1.1 allows a tip jar
  as an IAP that unlocks nothing ("tips"). It also requires that money for
  digital goods inside an App Store app goes through IAP, so no external
  payment links in that build.
- **Developer ID build** (GitHub, Sparkle): StoreKit IAP doesn't work
  outside the App Store. This build's **Support LLMTray** section links to
  **GitHub Sponsors** on the `ipsupport-llc` organization instead:
  - one-time tiers of $5, $25 and $150, mirroring Coffee, Pro and Founding;
  - no payment code in the app.

  The supporters list is shared by both builds.

### 2. The products

| product id | name | price tier | type |
|---|---|---|---|
| `us.ipsupport.llmtray.tip.coffee` | Coffee | $4.99 | consumable |
| `us.ipsupport.llmtray.tip.pro` | Pro Supporter | $24.99 | consumable |
| `us.ipsupport.llmtray.tip.founding` | Founding Supporter | $149.99 | non-consumable |

- Coffee and Pro are **consumable**: they can be bought again, and a tip
  has nothing to restore.
- Founding is **non-consumable**: it's a status, and it comes back through
  *Restore Purchases* on a new Mac (StoreKit `Transaction.currentEntitlements`).
- Prices are App Store price points; the table is USD, and other
  storefronts get Apple's equivalents.
- None of them is a subscription.

### 3. The app

- **Settings > About** gains a **Support LLMTray** section:
  - the three tiers with StoreKit's localized prices;
  - the copy "No subscriptions. No feature locks. Support development if
    LLMTray is useful to you.";
  - *Restore Purchases*;
  - the supporters list, with Founding Supporters first and in their own
    style, then Pro, then Coffee.
- **Nothing nags.** No popups and no counters. The only prompt is the
  optional listing, right after a completed purchase.
- **A purchase is verified on device** (StoreKit 2's signed `Transaction`)
  and needs no server. A "thank you" state is kept locally.
- **Offline, the section still works.** The app shows the manifest it
  last cached, or the copy bundled at build time. Buying needs the App
  Store, as any purchase does.

### 4. Getting listed (opt-in)

After a completed purchase, a sheet asks whether to list a name, with two
choices, **List my name** and **No thanks**. A later purchase or
Settings > About can open it again.

- **The display name is typed by the user.** It is prefilled with
  nothing, and at most 40 characters.
- **An optional link** (for example a website) is shown only if they add
  one; https only.
- **What's sent, to `POST https://ipsupport.us/api/supporters`:**
  - the display name and the optional link;
  - the tier;
  - the proof of payment.

  No Apple ID, no email, no device identifiers.
- **The proof of payment:**
  - **App Store:** the purchase's StoreKit JWS
    (`Transaction.jwsRepresentation`). It carries Apple's transaction id
    and the product, and nothing personal.
  - **GitHub Sponsors:** the sponsor's GitHub login, which is public
    already.
- **The server is `ipsupport-api`**, beside reviews and telemetry. Reviews
  already have the whole moderation cycle this needs (its adr/0004–0006).
  1. **It verifies the proof.**
     - **For a JWS:** Apple's signature chain, our bundle id and product,
       and not refunded (App Store Server API).
     - **For a login:** an active or past sponsorship of `ipsupport-llc`
       at that tier (GitHub GraphQL `sponsorshipsAsMaintainer`).
  2. **It keeps only a salted hash** of the original transaction id or of
     the login. That is enough to update or remove an entry, and to block
     duplicates.
  3. **It moderates the name and link** like a review:
     - the asynchronous local-LLM check answers approve, reject or
       escalate;
     - an escalated one reaches the maintainer by email with signed
       approve and reject links;
     - rules: no impersonation, slurs, spam links or ads.
  4. **It publishes only approved entries.** Nothing a purchase carries is
     ever published automatically.
- **Leaving the list.** The same sheet has *Remove my name*. It sends the
  proof again, and the entry is gone from the next response. Refunded
  purchases are dropped too: App Store Server Notifications `REFUND`, and
  a cancelled or refunded sponsorship on GitHub.
- **Development builds never POST to production.** Like telemetry's
  `LLMTRAY_TELEMETRY_ENDPOINT`, an `LLMTRAY_SUPPORTERS_ENDPOINT` points
  them at a local server.

### 5. The signed list

- **Where it comes from:**
  - `ipsupport-api` serves `GET https://ipsupport.us/api/supporters?product=llmtray`;
  - an app build carries a bundled snapshot (the release workflow fetches
    and checks it).
- **Format:**
  ```json
  {
    "version": 3,
    "updated": "2026-10-01",
    "supporters": [
      { "name": "Ada", "tier": "founding", "link": "https://example.org", "since": "2026-10" },
      { "name": "Grace", "tier": "pro", "since": "2026-10" }
    ]
  }
  ```
  `version` only goes up (the server bumps it on every change). The app
  ignores a list older than the one it has, so an old copy can't be
  replayed to hide names.
- **Signing:**
  - The response carries a detached Ed25519 signature of the exact body,
    in an `X-Signature` header. The body is kept as served and never
    re-encoded before checking.
  - The API holds the private key: its own key, not Sparkle's, kept in
    the cluster's secret store.
  - The public key ships in the app; the app checks it with CryptoKit
    `Curve25519.Signing`.
  - If the signature is invalid or missing, the app keeps its cached or
    bundled copy.
- **When the app refreshes it:**
  - when About opens, at most once a day, over plain HTTPS GET;
  - nothing is sent in the request: no identifiers and no cookies. The
    same rule as the update check ([0015](0015-telemetry.md): nothing
    leaves without consent).
  - Offline, it is simply not fetched.
- **Display:**
  - names are plain text, never rendered as markup;
  - links open in the browser only after a click, and only `https`;
  - if the list gets long, it is truncated with a "Show all" control.

### 6. What isn't done

- No subscriptions, no recurring tiers, no "Pro" features, no ads, no
  in-app "you haven't supported yet" reminders.
- No leaderboard of amounts: the tier is shown, the amount isn't.
- No automatic publishing of anything a purchase carries.

## Decided (were open)

1. **Submission endpoint:** `ipsupport-api` (the user). It is a new
   endpoint beside reviews and telemetry, and reuses the review
   moderation.
2. **The Developer ID build's tips:** GitHub Sponsors on `ipsupport-llc`,
   one-time tiers (decided here: no payment code and no fees to build;
   the listing proof is the public login).
3. **Business side:** the Paid Apps agreement, banking and tax forms are
   in place in App Store Connect (the user).
4. **Founding Supporter is sold for the first 12 months after the App
   Store launch**, then removed from sale; buyers keep it for good
   (the user, 2026-09-29). A founding tier that is always
   on sale means nothing. Changing the window is a price-and-availability
   edit in App Store Connect, no app update.

## Steps

1. **App Store Connect** (with the App Store build, [0018](0018-app-store-build.md)):
   - the three IAP products with review screenshots;
   - Founding's availability window;
   - a StoreKit configuration file for local testing.
2. **`ipsupport-api`** (its own ADR in that repo):
   - `POST /api/supporters`: JWS and GitHub verification, a hashed id,
     review moderation, removal, refunds;
   - `GET /api/supporters`: the signed list, monotonic `version`;
   - the Ed25519 key in the cluster's secrets.
3. **The app:**
   - the verifier with tests: a good signature, a bad one, an older
     version, a malformed body;
   - the About section: StoreKit 2 tiers, Restore, the list with
     Founding Supporters distinct, the offline fallback;
   - the listing sheet;
   - the Developer ID build's GitHub Sponsors link.
4. **GitHub Sponsors** on `ipsupport-llc` with the three one-time tiers
   (the user: the organization's Sponsors profile needs its owner).
