# 0029 — The OpenAI Responses API

**Status: accepted** (2026-10-17, by the user: "респонсес точно тоже делаем").

## Why

Some coding agents speak only OpenAI's Responses API. Codex CLI dropped
`wire_api = "chat"`; it needs `POST /v1/responses`. LLMTray serves chat
completions and Anthropic's `/v1/messages`, so Codex couldn't use it.

## Decision

The runtime (our mlx-lm fork, `mlx_lm/responses_api.py`) answers
`POST /v1/responses` the way it answers `/v1/messages`: the request is
converted to a chat request, run like any other (prompt cache, batching,
MTP, thinking budget, tool parsing), and the answer converted back to a
response object or the Responses server-sent events. Our own code; the
upstream drafts (ml-explore/mlx-lm #1207, #1263) were read, not taken —
they don't fit the fork's server.

- **Stateless.** No responses are stored: `previous_response_id` is refused
  with a clear error, and the client sends the whole conversation in
  `input` (Codex does, with `store: false`).
- **Input items:** messages (user, assistant, system, developer; text and
  images), reasoning (sent back; its raw text goes to the assistant turn),
  function calls and outputs, custom tool calls and outputs. Developer text
  in mid-conversation goes where `/v1/messages` puts system text.
- **Tools:** function tools as they are; custom (freeform) tools — Codex's
  `apply_patch` — as a function with one string argument, the grammar in
  its description; hosted tools (web search, file search) are dropped: a
  local model can't call them.
- **Reasoning:** `reasoning.effort` `none` / `minimal` turns thinking off,
  others on, passed to the chat template as `reasoning_effort`. Reasoning
  is streamed as a summary (clients show it) and kept as raw content (it
  comes back next turn).
- **Stream:** `response.created` / `in_progress`, output items with their
  deltas, `response.completed` (or `response.incomplete` at the token
  limit) with usage, cached tokens included.

The LLMTray proxy forwards `/v1/responses` like any route: the model check,
the model switch and the profile's sampling apply.

## Not now

- Stored responses / `previous_response_id`, conversations, background
  responses.
- Structured output (`text.format` json_schema) is not enforced.
- Hosted tools.
