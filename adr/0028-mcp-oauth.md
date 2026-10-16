# 0028 — MCP servers on the web: signing in with OAuth

**Status: proposed** (2026-10-16). The user's call: "давай сделаем … оаут".
Extends [0027](0027-mcp-client.md), whose "Not now" listed OAuth.

## Why

Most useful web servers (mail and calendar services, chat, documents,
task trackers) don't take a pasted key: they answer `401` and expect the
client to sign the user in. Without it LLMTray can install such a server
but never use it (the Slack server from the registry: `HTTP 402/401`, taken
out again).

## Decision

LLMTray signs in to a web (Streamable HTTP) MCP server the way the MCP
Authorization spec (2025-06-18 / 2025-11-25) describes, as a native app
(RFC 8252), with nothing of ours in between:

1. **Discovery.** A `401` from the server with `WWW-Authenticate: Bearer
   resource_metadata="…"` (or, without it, the server's
   `/.well-known/oauth-protected-resource`) gives the Protected Resource
   Metadata (RFC 9728): its `authorization_servers`. The first one's
   metadata comes from `/.well-known/oauth-authorization-server` (RFC 8414),
   else `/.well-known/openid-configuration`. Every URL must be https; the
   resource in the metadata must be the server's own URL (or a prefix of
   it), else sign-in stops.
2. **Who we are.** A Client ID Metadata Document where the server supports
   it (`client_id_metadata_document_supported`): our client id is
   `https://ipsupport.us/llmtray/oauth-client.json`, a static file on our
   site (name, logo, redirect URIs, `token_endpoint_auth_method: none`).
   Else Dynamic Client Registration (RFC 7591) at its
   `registration_endpoint`, the registration kept per server. Else the
   server can't be signed in to from LLMTray: said so.
3. **Signing in.** Authorization code with PKCE (S256), `state` checked,
   `resource` (RFC 8707) set to the server's URL, `scope` from the
   challenge or the metadata's `scopes_supported`. The page opens in the
   user's browser; the redirect comes back to a loopback listener
   (`http://127.0.0.1:<random port>/callback`) that the app opens for that
   one sign-in and closes after it or after 5 minutes. A public client: no
   secret.
4. **Tokens** go to the Keychain (per server: access, refresh, expiry) and
   ride every request as `Authorization: Bearer`. An expired access token
   is refreshed before a call; a `401` on a call refreshes once; a refresh
   that fails marks the server "Sign in again" (the call is answered "not
   sent: the server needs you to sign in again"). Nothing is ever sent to
   a server other than the one the token is for.

## In the app

- **Install** of a web server that answers `401` with OAuth metadata isn't
  taken out again (0027's failed-install rule): it stays, off, and the
  browser opens to sign in; when it comes back the tools are listed and
  it's on, as any install. Cancel or a failed sign-in takes it out, with
  why.
- The row says "Needs sign-in" with **Sign In**; ⋯ has **Sign Out**
  (tokens deleted, the server's revocation endpoint called when it has
  one). Configure shows where it's signed in (the authorization server's
  host) and the scopes.
- A server whose metadata or flow we don't support still says why in
  words ("it signs in a way LLMTray doesn't support yet").
- App Store build: the same (web servers only there); the loopback
  listener uses the network-server entitlement it already has.

## Trust

Tokens are secrets (Keychain, never in files or logs). The browser shows
the user exactly who they sign in to and what they allow. A server's
metadata can't send tokens elsewhere: the resource must match the server,
the token endpoint is used only for tokens, all https. Calls still go
through the card (0027): signing in grants nothing to the chat by itself.

## Plan

1. Core: metadata discovery (RFC 9728, 8414, OIDC), PKCE, state, the
   authorization URL, token and refresh exchanges, DCR, the loopback
   callback parser; tests with fixture servers.
2. App: the sign-in flow (browser + loopback listener), Keychain tokens,
   the bearer on `MCPHTTPTransport`, refresh on expiry and on `401`, the
   row's Sign In / Sign Out, install keeping a server that needs sign-in.
3. Our client metadata document on ipsupport.us.
4. Live: a public OAuth MCP server (a test one first), then the user's.

## Not now

Signing in to a command (stdio) server (they take keys by environment);
device-code flow; sharing a sign-in between servers of one provider.
