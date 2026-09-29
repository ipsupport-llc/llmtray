# 0017 — Support LLMTray (tips, a supporters list)

**Status: proposed** (2026-09-29, from the user's brief).

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
  outside the App Store. This build gets the same **Support LLMTray**
  window, but it links out to an external page (for example GitHub
  Sponsors or a page on ipsupport.us; which one is open). The supporters
  list is shared by both builds.

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
- **What's sent:**
  - the display name and the optional link;
  - the tier;
  - the purchase's **StoreKit JWS** (`Transaction.jwsRepresentation`),
    as proof of purchase.

  No Apple ID, no email, no device identifiers. The JWS carries Apple's
  transaction id and the product, and nothing personal.
- **Sent to a small submission endpoint.** The endpoint does three things:
  1. It verifies the JWS: Apple's signature chain, our bundle id, the
     product, not refunded (App Store Server API).
  2. It keeps only a **salted hash** of the original transaction id. That
     is enough to update or remove an entry, and to block duplicates.
  3. It queues the entry for **manual approval**. A person reviews every
     name before it's public (impersonation, slurs, spam links).
- **After approval, a maintainer adds the entry to the manifest and signs
  it.** No entry is ever published automatically.
- **Leaving the list.** The same sheet has *Remove my name*. It sends the
  JWS again, and the entry is dropped at the next manifest release.
  Refunded purchases are dropped too; the App Store Server Notifications
  `REFUND` event triggers it.

### 5. The signed manifest

- **Where it lives:**
  - `supporters.json` is published with the site (GitHub Pages, next to
    the appcast);
  - a detached signature goes beside it as `supporters.json.sig`;
  - a snapshot is bundled at build time.
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
  `version` only goes up. The app ignores a manifest older than the one
  it has, so an old copy can't be replayed to hide names.
- **Signing:** Ed25519, the same kind of key Sparkle uses, but a
  **separate key pair**.
  - The public key ships in the app; the app checks it with CryptoKit
    `Curve25519.Signing`.
  - The private key lives only in a GitHub secret. The Pages workflow
    signs on publish.
  - If the signature is invalid or missing, the app keeps its cached or
    bundled copy.
- **When the app refreshes it:**
  - when About opens, at most once a day, over plain HTTPS GET;
  - nothing is sent in the request: no identifiers and no cookies. The
    same rule as the update check ([0015](0015-telemetry.md): nothing
    leaves without consent).
  - Opt-out: the existing "network features" rules apply; offline it is
    simply not fetched.
- **Display:**
  - names are plain text, never rendered as markup;
  - links open in the browser only after a click, and only `https`;
  - if the list gets long, it is truncated with a "Show all" control.

### 6. What isn't done

- No subscriptions, no recurring tiers, no "Pro" features, no ads, no
  in-app "you haven't supported yet" reminders.
- No leaderboard of amounts: the tier is shown, the amount isn't.
- No automatic publishing of anything a purchase carries.

## Open questions

1. **Where the submission endpoint runs.** The bosun host is run by its
   own agent and isn't ours to deploy to. A small serverless function
   (Cloudflare Worker or similar) with a private queue is the simplest.
   Needs the user's pick.
2. **The Developer ID build's external tip page:** GitHub Sponsors,
   Stripe Payment Links, or a page on ipsupport.us. The same listing flow
   would need a proof of payment from that provider instead of a JWS.
3. **Taxes and the business side:** the App Store pays out through IPSupport
   LLC's agreements (Paid Apps agreement, banking, tax forms in App Store
   Connect). This has to be in place before the products can be approved.
4. **Whether Founding Supporter is limited in time** (for example, only
   during the first year on the App Store). The brief doesn't say. A
   `since` date keeps either possible.

## Steps

1. This ADR accepted; the open questions answered.
2. App Store Connect:
   - the three IAP products with review screenshots;
   - the Paid Apps agreement;
   - a StoreKit configuration file for local testing.
3. The manifest:
   - `supporters.json` and the signing step in pages.yml, with a new
     secret `SUPPORTERS_SIGNING_KEY`;
   - the public key in the app;
   - a verifier with tests: a good signature, a bad one, an older
     version, a malformed file.
4. The About section: tiers through StoreKit 2, Restore, the list with
   Founding Supporters distinct, the offline fallback.
5. The listing sheet and the endpoint (after open question 1): verify the
   JWS, a hashed id, a manual approval queue, removal, refunds.
6. The Developer ID build's external link (after open question 2).
