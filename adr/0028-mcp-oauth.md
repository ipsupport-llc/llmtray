# 0028 — MCP servers on the web: signing in with OAuth

**Status: proposed** (2026-10-16). The user's call: "давай сделаем … оаут".
Extends [0027](0027-mcp-client.md), whose "Not now" listed OAuth.

## Why

Most useful web servers (mail and calendar services, chat, documents,
task trackers) don't take a pasted key: they answer `401` and expect the
client to sign the user in. Without it LLMTray can install such a server
but never use it (the Slack server from the registry answered `HTTP 402`,
and was taken out again).

## Decision

LLMTray signs in to a web (Streamable HTTP) MCP server the way the MCP
Authorization spec describes -- the 2025-11-25 revision (and what
2025-06-18 servers need) -- as a native app (RFC 8252), a public client,
with nothing of ours in between.

**Canonical URL** (used for every comparison and for `resource`): scheme and
host lowercased, default port dropped, fragment and query dropped, a lone
trailing slash on the root ignored.

**1. Discovery** (credential-free requests; https only, the loopback
redirect excepted; no redirects followed across origins; private and
link-local addresses refused unless the server itself is local).
- Protected Resource Metadata (RFC 9728): the `resource_metadata` URL of
  the server's `401` challenge, else
  `/.well-known/oauth-protected-resource/<path of the server URL>`, else
  the same at the root. Its `resource` must equal the server's canonical
  URL exactly for a header or path-inserted lookup, the root URL for the
  root lookup -- no prefix matching.
- Scope to ask for: the challenge's `scope` if the `401` has one, else this
  metadata's `scopes_supported`, else none (no `scope` parameter).
- Authorization server metadata, for the first listed authorization server
  (RFC 9728 §7.6: the user sees its host in the browser and in Settings):
  for an issuer with a path, `/.well-known/oauth-authorization-server/<path>`,
  `/.well-known/openid-configuration/<path>`, `<issuer>/.well-known/openid-configuration`;
  without one, the first two at the root. The metadata's `issuer` must equal
  the issuer it was fetched for. `code_challenge_methods_supported` must
  list `S256`, else sign-in stops ("it doesn't support a safe sign-in").

**2. Registration.**
- A Client ID Metadata Document where the server says it supports them:
  our client id is `https://ipsupport.us/llmtray/oauth-client.json`, a
  static file with `client_id` equal to that URL, `client_name`, `logo_uri`,
  `redirect_uris` (`http://127.0.0.1/callback`: any port, RFC 8252 §7.3),
  `grant_types` (`authorization_code`, `refresh_token`),
  `token_endpoint_auth_method: none`.
- Else Dynamic Client Registration (RFC 7591) asking for the same, with
  `token_endpoint_auth_method: none`; the answer is checked (a
  confidential registration is refused) and kept per issuer, the client id
  in the settings file.
- Else a client id the user pastes in Configure (a server that
  pre-registers clients), else "it signs in a way LLMTray doesn't support".

**3. Signing in.** Authorization code + PKCE (S256), a fresh `state`, the
`resource` parameter (the server's canonical URL) and `scope`. The page
opens in the user's browser; the redirect comes to a loopback listener on
a random port, opened for that one flow and closed after it or 5 minutes.
The pending flow is bound to its issuer, endpoints, client id, resource,
port and verifier: a callback is taken only on that port with that
`state`.

Mix-up between authorization servers (a hostile one pairing an honest
authorization endpoint with its own token endpoint) is stopped by one of:
- the response's `iss` (RFC 9207) equal to the issuer -- required, and a
  missing one fails, when the metadata says
  `authorization_response_iss_parameter_supported`;
- else a callback path that names the issuer (`/callback/<hash of the
  issuer>`), matched exactly, where we registered by DCR (per issuer);
- else (a client metadata document and no `iss`): the authorization and
  token endpoints must share the issuer's origin. Otherwise sign-in stops.

**4. Tokens.** Kept in the Keychain per (server, issuer, resource) with the
client id they belong to; never in files, logs, URLs or query strings.
- Every token request (code exchange, refresh) goes only to the token
  endpoint of the issuer the tokens came from, with `resource`; a token is
  sent only to the server it's for, and an authenticated MCP request isn't
  re-sent by a redirect to another origin.
- Refresh before expiry, and after any `401` to a request that carried a
  token (with or without `invalid_token`): refresh once, retry the call
  once. One refresh at a time per server (a lock: with rotation, two
  refreshes with one token can revoke the grant); a new refresh token
  replaces the old at once.
- `403 insufficient_scope` with a `scope`: a new sign-in asking for the
  scopes granted so far plus the challenged ones (some servers replace
  rather than add), at most once per call, the user seeing the browser page.
- A refresh refused with `invalid_grant` means "Sign in again";
  `invalid_client` (a dynamic registration the server dropped) drops our
  registration, registers again and signs in again; a network or 5xx
  failure keeps the tokens and the call fails as such. A call that was sent
  and got `401` after the retry is reported as failed, not "not sent".

What a token is good for is the server's to enforce (audience); LLMTray
asks for the right resource and keeps each token to its server.

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

Tokens are secrets (Keychain only). The browser shows the user who they
sign in to and what they allow, and Settings shows the issuer's host. The
invariants above -- exact resource and issuer, S256 required, flows bound
to their issuer, tokens kept to their server and token endpoint, no
cross-origin redirects with credentials -- are what keeps a hostile
server's metadata from getting a code or a token elsewhere. Calls still go
through the card (0027): signing in grants nothing to the chat by itself.

## Plan

1. Core: discovery (path and tenant variants), the checks (resource,
   issuer, S256, iss), PKCE, state, the authorization URL, token and
   refresh exchanges with resource, DCR, the callback parser; tests with
   fixture servers, negative ones too (a hostile resource_metadata, a
   mismatched resource or issuer, no S256, a wrong iss or state, a callback
   on another port, insufficient_scope).
2. App: the sign-in flow (browser + loopback listener), Keychain tokens,
   the bearer on `MCPHTTPTransport`, refresh on expiry and on `401`, the
   row's Sign In / Sign Out, install keeping a server that needs sign-in.
3. Our client metadata document on ipsupport.us (served with cache
   headers; DCR remains the fallback if the site is down).
4. Live: a public OAuth MCP server (a test one first), then the user's.

## Not now

Signing in to a command (stdio) server (they take keys by environment);
device-code flow; sharing a sign-in between servers of one provider.
