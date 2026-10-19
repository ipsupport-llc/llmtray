# Architecture decisions

Why things are the way they are — the investigations and dead ends behind
constraints the code relies on. The code keeps a one-line reason and points
here; this is where the history lives.

| ADR | Topic |
|---|---|
| [0001](0001-mlx-runtime.md) | The mlx-lm runtime: our fork, a pinned commit, a venv outside the bundle, the Full build |
| [0002](0002-model-proxy-and-lifecycle.md) | The model proxy and the server lifecycle |
| [0003](0003-field-lessons.md) | Launch defaults and other lessons from live failures |
| [0004](0004-update-feed.md) | The Sparkle update feed, built from releases |
| [0005](0005-profiles.md) | Config profiles: layered overlays, per-launch settings, the proxy's sampling fill |
| [0006](0006-chat-sessions-and-library.md) | Chats: tabs, sessions on disk, temporary chats, projects, compaction |
| [0007](0007-chat-tools.md) | The chat's tools: native Swift tools, the tool loop and its limits |
| [0008](0008-localization-and-release.md) | Localization and releases, CI on the older toolchain |
| [0009](0009-media-generators.md) | Image and music generators: Python runners, the queue, the proxy's wait |
| [0010](0010-music-ace-step.md) | Music: ACE-Step 1.5 turbo and sft on MLX |
| [0011](0011-creator-mode-and-media-variants.md) | Creator mode, Regenerate / Tweak / Remove, media sources |
| [0012](0012-project-files-rag.md) | Project files, a local micro-RAG (SQLite FTS5 + vectors, bge-m3, tiered OCR) |
| [0013](0013-first-run-wizard.md) | The first-run wizard |
| [0014](0014-folder-tools.md) | Folder tools: listing, file info, moving and deleting in folders the user grants |
| [0015](0015-telemetry.md) | Usage telemetry, on for new installs (never turned on by an update): one anonymous report a day, what's counted and what never is |
| [0016](0016-voice.md) | Voice: a speech-to-speech Voice Lab first, then voice chat (push to talk, spoken answers) on the chat model |
| [0017](0017-supporters.md) | Support LLMTray: optional tips (StoreKit IAP in the App Store build, GitHub Sponsors otherwise), opt-in supporters list moderated and signed by ipsupport-api; nothing locked |
| [0018](0018-app-store-build.md) | A Mac App Store build beside the Developer ID one: every runtime bundled and signed, sandboxed, no Sparkle, StoreKit tips |
| [0019](0019-command-line.md) | The `llmtray` command-line tool: an owner-only control socket, the tray's own actions, a symlink in ~/.local/bin; not in the App Store build |
| [0020](0020-documents.md) | Documents: `make_document` turns the model's Markdown and chart data into a PDF laid out by the app; tools declared on demand (`load_tools`, + menu) and kept for the chat |
| [0021](0021-concurrent-requests.md) | Concurrent requests: batching with a quantized KV cache, speculation (MTP, drafter) by load with handoff into the batch; Concurrent requests said honestly, memory-aware, auto-tuned |
| [0022](0022-thinking-effort.md) | Thinking effort: Off / Low / Medium / High, one setting for every chat, from the model's chat template; Low and Medium as a server-side thinking budget |
| [0023](0023-spoken-messages.md) | Spoken messages for models that hear: click for a clip, hold to talk; WAV to the runtime's `input_audio` |
| [0024](0024-memory.md) | Memory between chats: notes learned only from the user's own words, reconciled into one note per claim across languages and models, injected within a budget, aging by kind; opt-in, all local |
| [0025](0025-apple-system-model.md) | Apple's on-device model (FoundationModels): memory's reader in-process, then a chat model served by the proxy itself; app only, no cloud, nothing to download |
| [0027](0027-mcp-client.md) | MCP servers the user adds (command, URL, .mcpb, pasted config, the official registry) as on-demand tool groups; every call asked unless allowed per tool, all asked after outside text; own small client |
| [0028](0028-mcp-oauth.md) | Web MCP servers signed in with OAuth (MCP Authorization spec): metadata discovery, client metadata document or DCR, PKCE + loopback redirect, tokens in the Keychain with refresh |
| [0029](0029-responses-api.md) | The OpenAI Responses API at /v1/responses (Codex CLI): converted to a chat request in the runtime, stateless, function + custom tools |
| [0030](0030-show-screen-and-tab.md) | Showing the model a window, the screen (system picker, one still; OCR text for models that don't see) or the front browser tab (standalone only); opt-in, outside text |

New ADR: next number, one topic, the decision first, then why.
