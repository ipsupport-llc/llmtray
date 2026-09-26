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
| [0012](0012-project-files-rag.md) | **Proposed**: project files, a local micro-RAG (SQLite FTS5 + vectors, Qwen3-Embedding, tiered OCR) |

New ADR: next number, one topic, the decision first, then why.
