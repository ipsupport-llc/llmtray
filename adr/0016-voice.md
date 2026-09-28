# 0016 — Voice

**Status: accepted** (2026-09-27, by the user). Nothing here is built yet.

## Why

LLMTray is typed-only. Two things are asked for, in this order:

1. **A voice-to-voice toy** — talk to a speech-to-speech model that hears
   audio and answers in audio, full duplex, no text in between. Known to be
   a toy (English only, no tools, small brains), wanted to play with.
2. **A real voice chat** — speak to the chat model you already use (its
   profile, tools, projects, pinned files) and hear its answers, in
   Russian as well as English.

They share the plumbing (the microphone, playback, a runner, the opt-in
downloads) and nothing else, so they're two features on one base.

## What exists to build on

- **mlx-audio** (MIT) already runs in LLMTray: the music generator uses it
  in its own venv (`MusicManager`, `music_venv`,
  [0010](0010-music-ace-step.md)). It carries STT, TTS, VAD and
  speech-to-speech models on MLX, and an OpenAI-compatible
  `/v1/audio/transcriptions` and `/v1/audio/speech` server.
- The runner pattern of [0009](0009-media-generators.md): a Python child
  in its own venv, requests on stdin, results streamed back, killed with
  the app; every model opt-in with its size shown; nothing downloaded
  before the user turns it on.
- The generator policy (unload the chat model while a heavy generator
  runs, `GenerationQueue`).

Candidates, as of 2026-09 (sizes are the published MLX quantizations,
to be measured on a 26 GB M5 before we commit):

| Role | Model | Notes |
|---|---|---|
| Speech-to-speech | **NVIDIA VoiceChat 11B** 4-bit | full duplex via mlx-audio `create_duplex_session`, text + function channels, English; OpenMDW 1.1, not gated |
| Speech-to-speech | PersonaPlex 7B (NVIDIA, Moshi architecture) | full duplex, 18 voices, English; gated upstream, MLX conversions tagged non-commercial, not in mlx-audio |
| Speech-to-speech | Moshi (Kyutai) | the original full-duplex model; CC-BY 4.0; moshi_mlx pins mlx < 0.27 |
| STT | **Parakeet TDT 0.6B v3** | 25 European languages incl. Russian, fast |
| STT | Whisper large-v3-turbo | 99 languages, the safe fallback |
| STT | Qwen3-ASR | strongest on accents and noise, larger |
| TTS | **macOS system voices** (AVSpeechSynthesizer) | free, no download, Russian included |
| TTS | **Qwen3-TTS** 0.6B / 1.7B | natural, streaming, Russian among its languages |
| TTS | Kokoro 82M | tiny and fast, no Russian |
| VAD | **Silero VAD** | end of speech, barge-in |

Bold is the proposed default of each row.

## Decision

### Shared base

- **Settings > Voice**, off by default. Turning on a mode lists its models
  with sizes and downloads only those (as Project files does its embedder).
  A wizard step can come later.
- **Microphone**: `NSMicrophoneUsageDescription` in Info.plist; capture with
  `AVAudioEngine` at 16 kHz mono in the app; nothing is recorded to disk
  unless the user saves it. The permission is asked the first time a voice
  control is used, not at launch.
- **Runner**: `llmtray_voice_runner.py` in the **music venv**, which since
  PR #155 installs mlx-audio from our fork's `llmtray` branch
  (ipsupport-llc/mlx-audio: current upstream main + ACE-Step, bit-identical
  music checked on real weights). One audio runtime for music and voice; the
  voice models need mlx-audio's `sts` extras added to its requirements. The app streams PCM frames
  to it over stdin as length-prefixed binary chunks (new: the embed runner's
  JSON lines would base64 every frame) and reads events back the same way
  (JSON events — partial and final transcripts, errors — and audio chunks).
  One process per active mode, killed on stop and with the app.
- **Playback** in the app (`AVAudioEngine` player node), so barge-in can
  cut it instantly without waiting on the runner.
- **Memory**: the runner's models count against the GPU limit like the chat
  model's ([GPUFit](../Sources/LLMTrayCore/GPUFit.swift)); the Voice pane
  shows what fits next to the loaded chat model.

### Mode 1: Voice Lab (the toy) — first

- A separate **Voice Lab** window with one big button: talk / stop, a
  level meter, a voice picker (PersonaPlex's presets), and a transcript
  only if the model emits text.
- **Full duplex**: the mic streams continuously, the model's audio plays as
  it comes; the model decides when to speak and yields when interrupted
  (that's its own behaviour, not ours).
- **The chat model is unloaded** while the Lab runs (a 7–11B S2S model and
  Gemma 26B don't fit together on 26 GB), with the same notice as image
  generation, and reloaded after.
- No tools, no projects, no history kept. English. Labelled "Experimental".
- Default model **VoiceChat 11B 4-bit** (`mlx-community/NemotronLabs-VoiceChat-11B-4bit`,
  9.2 GB download) through mlx-audio's duplex session
  (`mlx_audio.sts.load(...).create_duplex_session()`, `push_audio(chunk,
  16000)`; events: text deltas, function tokens, 22.05 kHz audio on an 80 ms
  clock). Published on an M5 Pro: real-time factor ~0.93, first audio ~75 ms,
  ~15.6 GB physical footprint — tight on 26 GB, so the chat model unloads and
  we measure on the base M5 before shipping.
- PersonaPlex later, opt-in: its upstream is gated (the user's own HF
  token), the MLX conversions carry a non-commercial tag, redistribution needs
  NVIDIA's notice, int4 is reported incoherent, and it needs speech-swift
  (macOS 15, its own metallib) or Moshi-era code with older pins.

### Mode 2: Voice chat (the real one) — second

- **Push to talk** in the composer: hold the mic button (or a shortcut) and
  speak; release → the transcript lands in the composer and is sent (a
  setting: send at once or let me edit first). Works in any chat, with its
  profile, tools, project files and pins.
- **STT**: Parakeet v3 by default (Russian + English), Whisper turbo as the
  fallback for other languages; language auto-detected, overridable.
- **Spoken answers** (a toggle per chat): sentences are spoken as the answer
  streams, not after it ends. Markdown, code blocks, tables and citations
  aren't read out (a speakable-text filter in Core, tested); a code block
  becomes "code in the chat".
- **TTS**: system voices by default (no download, Russian voices exist;
  premium voices are the user's to install in macOS Settings); Qwen3-TTS as
  the opt-in neural voice.
- **Barge-in**: speaking while an answer is read stops the playback (VAD on
  the mic, only while speaking an answer).
- **Hands-free conversation** (later step): VAD ends the turn after silence,
  no button; the mic reopens after the spoken answer. Off by default.
- Reasoning is never spoken; tool calls say only "one moment" if they take
  longer than two seconds.

### Out of scope

- A system-wide dictation hotkey (a separate feature later).
- Voice cloning (models support it; not until there's a reason and a
  consent story).
- Telephony, wake words.

## Order of work

1. Base: Voice pane, mic capture + permission, the runner with framing,
   playback, memory display. Tests: framing, the speakable-text filter
   (for step 3), fits-next-to-model math.
2. Voice Lab with PersonaPlex 7B — measure memory, latency (first audio
   after the user stops), and whether the full duplex works through the
   runner's pipes; if pipes add too much latency, the runner opens a local
   Unix socket instead.
3. Push-to-talk STT into the composer.
4. Spoken answers (system voices), barge-in.
5. Qwen3-TTS, hands-free mode.

Each step ships on its own; step 2 alone is the toy that was asked for.

## Licences (checked 2026-09-27)

- VoiceChat 11B: OpenMDW 1.1 — use, redistribution and commercial use
  allowed; keep the licence and origin notices; rights end on a patent or
  copyright suit over the model. Shown in the Voice pane with the download.
- PersonaPlex: NVIDIA Open Model License (commercial use and distribution
  allowed, NVIDIA notice required, terminates if safety guardrails are
  bypassed) + CC-BY-4.0; gated on Hugging Face.
- Moshi: weights CC-BY 4.0, moshi_mlx MIT.
- speech-swift: Apache-2.0.

## Open questions

- Real-time on the base M5 (published numbers are M5 Pro / M2 Max).
- Echo: the model hears its own voice from the speakers; headphones for the
  Lab, echo cancellation (Voice Processing I/O) before voice chat.
