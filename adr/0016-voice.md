# 0016 — Voice

**Status: accepted** (2026-09-27, by the user). Steps 1–2 (the base, Voice Lab with VoiceChat 11B) are built.
**Amended** 2026-11-06 (the user: "да, вноси в ADR и поехали"): the neural
voice is Chatterbox Multilingual V3, not Qwen3-TTS; spoken answers and the
neural voice ship together as step 4 — see "Spoken answers with
Chatterbox" below.

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
| TTS | ~~Qwen3-TTS 0.6B / 1.7B~~ | replaced 2026-11-06, see below |
| TTS | **Chatterbox Multilingual V3** 0.5B | MIT, 23 languages incl. Russian, voice cloning from ~10 s; in our mlx-audio fork |
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
- **Walkie-talkie fallback** (added while building it, 2026-09-27): on the
  base M5 an 80 ms frame takes ~160 ms (RTF ≈ 2.0, peak footprint ~12.5 GB,
  first reply audio 0.56 s after speech end), too slow for live duplex. The
  runner measures the RTF at load (warmup frames of silence); above 1.0,
  "Automatic" switches to walkie-talkie: the user presses Talk, speaks,
  presses Done; the runner then steps the model on silence as fast as it
  can until its reply ends (1.2 s quiet), and the app plays the whole reply.
  Full duplex stays selectable.
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
  premium voices are the user's to install in macOS Settings); Chatterbox
  Multilingual V3 as the opt-in neural voice (below).
- **Barge-in** (step 5): speaking while an answer is read stops the
  playback (VAD on the mic, only while speaking an answer).
- **Hands-free conversation** (later step): VAD ends the turn after silence,
  no button; the mic reopens after the spoken answer. Off by default.
- Reasoning is never spoken. In hands-free mode (step 5) a tool call that
  takes longer than two seconds says "one moment"; in step 4 tool calls
  aren't spoken.

### Out of scope

- A system-wide dictation hotkey (a separate feature later).
- ~~Voice cloning~~: now in, for Chatterbox (below), with the consent
  line there.
- Telephony, wake words.

## Spoken answers with Chatterbox (2026-11-06)

### Why Chatterbox, not Qwen3-TTS

- **Licence**: MIT (code and weights, Resemble AI). 23 languages, Russian
  among them. A voice is cloned from a ~10 s clip; a built-in voice comes
  with the weights.
- **Version**: Multilingual **V3** (`t3_mtl23ls_v3`, Resemble 2026-06-10):
  same 0.5B size as V2, better speaker similarity, fewer hallucinated
  tails and repeats.
- **Already in our runtime**: our mlx-audio fork, at the commit LLMTray
  pins (0.5.6), has `chatterbox` with multilingual v2/v3 and `lang_code`.
  MLX weights: `mlx-community/chatterbox-multilingual-v3` (2.71 GB, MIT)
  plus `mlx-community/S3TokenizerV2` (0.49 GB). The tokenizer is converted
  from FunAudioLLM/CosyVoice2-0.5B, so it is **Apache-2.0**, not MIT.
- **Built-in voice**: the multilingual MLX repo has no `conds.safetensors`.
  The built-in voice comes from `mlx-community/chatterbox-fp16`'s (105 KB,
  MIT), converted from Resemble's own `conds.pt`, which their multilingual
  model loads too.
- Chatterbox **Turbo** (350M) and **Nano** (110M) are faster but
  English-only. They're not offered now; Turbo is in the fork if an
  English-only fast voice is wanted later.
- Not used: **Chatterbox-Flash** (English, CUDA and FlashInfer only);
  **Dramabox** (LTX-2 Community License, not MIT).

### Russian stress

- Chatterbox reads Russian without stress marks badly. mlx-audio's
  chatterbox stresses Russian with `russian_text_stresser`
  (Vuizur/add-stress-to-epub), and without it it only logs a warning.
  That package is **AGPL-3.0**. It is never installed or bundled, and the
  runner checks at start that it can't be imported.
- **We stress the text ourselves**, before it reaches the model, with
  **ruaccent** (MIT, code and models) in **tiny mode only**. The full mode
  imports rupostagger, which is GPL-3.0, so ruaccent is installed with
  `--no-deps`. The scheme is already in use in IPSupport's own speech service:
  - its accents dictionary (3.19M words) is kept as a sorted array of
    64-bit word hashes plus the stress position: about 28 MB instead of
    ~1.8 GB as a Python dict;
  - the ONNX models run only where the dictionary can't answer: tiny2.1
    for homographs, the е/ё resolver only when a ё-homograph is present,
    nn_accent for unknown words;
  - a few context rules (замок, плачу, положите, оплатите);
  - a rule fallback for words nobody stresses (ё stressed; -ация,
    -ировать, -изм, -ист; otherwise the next-to-last syllable).
- **Measured**: 5 errors in 30 assistant-style sentences, against 23 for
  StressRNN; about 3 ms a sentence, ~200 MB resident.
- **Files**: from HF `ruaccent/accentuator`, pinned to revision
  `b78ae5ea1e62beaf138bed1865cd8c3b0b5ca855` (MIT), about 84 MB once
  built. They're downloaded with the voice and the dictionary is built
  once on the Mac. ruaccent's own `load()` is never called, because it
  fetches the whole repository; the pieces are wired by hand.
- **Runtime**: onnxruntime and razdel join `AudioRuntime.requirements`.
  ruaccent goes in as a second pip step with `--no-deps`. transformers,
  numpy and huggingface_hub are already there.
- **App Store build**: its packages are baked into the bundle by
  `scripts/build_full_app.sh`, which has its own package list (it reads
  only the mlx-audio commit from `AudioRuntime`). onnxruntime and razdel
  go into that list, and ruaccent into a `--no-deps` step. onnxruntime's
  native library is signed with the rest, and its licence (MIT) goes in
  the notices.
- **Where files live**: the bundle is read-only. The stress pack (the
  built dictionary and the ONNX models), the voice model and the
  tokenizer all go in the models folder (the container, in the App Store
  build), downloaded by the app as data. A voice clip goes in the app's
  support folder.
- **Not yet run on macOS**, only on Linux. The first test is on the Mac,
  then in the App Store sandbox.

### What the user sees

- **Speak** on every answer (next to Copy): reads that answer, and
  becomes **Stop** while it reads.
- **Read answers aloud**, a speaker button in the chat's turn actions
  and a toggle in Settings: each new answer is spoken sentence by sentence
  as it streams. One setting for every chat, like the thinking effort
  (built so; per-chat was planned).
  - Reasoning and tool calls are never spoken.
  - Markdown, tables, links and citations are reduced to speakable text
    (Core, tested). A code block becomes "code in the chat".
  - A new answer, Stop, or switching chats stops the speech.
- **Settings > Voice > Spoken answers**:
  - **Voice**: System (default; the macOS voice for the text's language)
    or Chatterbox.
  - **Chatterbox**: download (model, tokenizer and the Russian stress
    pack, about 3.3 GB, size shown before), remove, and the voice:
    **built-in**, or **from a clip**. A clip is a WAV/M4A of 5–30 s;
    10 s or more is best.
  - **Consent line** under the clip picker: "Use your own voice, or a
    voice you have permission to use." The clip is copied into the app's
    support folder and never leaves the Mac.
- **Language**: the answer's first sentences pick its language
  (`NLLanguageRecognizer`); each sentence is then checked again, with the
  answer's language as the fallback when the guess is unsure. Russian is
  stressed first. An answer in a language Chatterbox lacks is read by the
  system voice, whole: two voices taking turns inside one answer would
  sound like two people.
- **The clip** is stored as a 16-bit WAV (its first 30 s), whatever the
  user picked (M4A, MP3...).

### How it runs

- **`llmtray_tts_runner.py`** runs in the audio venv. It speaks Voice
  Lab's binary frame format (a type byte, a 4-byte length, the payload)
  in both directions, with its own frame types:
  - app to runner: `P` speak {id, text, lang}, `V` voice {clip or null
    for built-in}, `C` cancel everything queued, `Q` quit;
  - runner to app: `R` ready {sample_rate}, `B` {id} before a sentence's
    audio, `S` PCM16, `Z` {id, rtf} when the sentence is done, `E` {id,
    message}, `L` log.

  The app starts it on the first sentence and stops it after 5 minutes
  idle or when the app quits.
- **Playback**: a `SpeechPlayer` (Voice Lab's) made at the sample rate
  the `R` frame gives (24 kHz for Chatterbox). While sentence *n* plays,
  sentence *n+1* synthesizes. Stop drops what's queued and playing
  (`cancelPlayback`, not `flush`, which plays the rest) and sends `C`.
- **Memory**: unlike the other generators, spoken answers must run
  **next to** a chat model that is generating, so nothing is unloaded.
  The real footprint is unknown: the download is 3.2 GB, and Voice Lab
  ran well above its weights (a 9.2 GB download used 15.6 GB). It is
  measured on the base M5 before stable. Settings shows the GPUFit
  estimate as a notice, as the other features do; it doesn't block.
- **Speed is not measured yet.** If the runner can't keep up with
  playback, it falls behind sentence by sentence, with gaps; first audio
  comes one sentence's synthesis late. The base M5 numbers go here before
  this ships as stable.

### Later

- Barge-in and hands-free mode go with push-to-talk STT (steps 3 and 5).
  Barge-in needs the microphone open while speaking, and echo
  cancellation with it.

## Order of work

1. Base: Voice pane, mic capture + permission, the runner with framing,
   playback, memory display. Tests: framing, the speakable-text filter
   (for step 3), fits-next-to-model math.
2. Voice Lab with VoiceChat 11B (built; PersonaPlex stays a later
   opt-in) — memory, latency and duplex over the runner's pipes measured.
3. Push-to-talk STT into the composer.
4. Spoken answers: system voices and Chatterbox Multilingual V3 (above).
5. Barge-in and hands-free mode, after step 3.

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
- Chatterbox (all variants used here) and its mlx-community conversions:
  MIT. `mlx-community/S3TokenizerV2`: Apache-2.0 (from CosyVoice2-0.5B).
  ruaccent code and `ruaccent/accentuator` models and dictionaries: MIT.
  onnxruntime: MIT. razdel: MIT. (Checked 2026-11-06.)
- Never shipped: `russian_text_stresser` (AGPL-3.0), and rupostagger
  (GPL-3.0, pulled in by ruaccent's full mode).

## Open questions

- Real-time on the base M5 (published numbers are M5 Pro / M2 Max).
- Echo: the model hears its own voice from the speakers; headphones for the
  Lab, echo cancellation (Voice Processing I/O) before voice chat.
