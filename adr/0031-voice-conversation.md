# 0031 — Voice conversation

**Status: proposed** (2026-11-07). Discussed with the user and recorded so
nothing gets lost. The user's words: "сделать войс ту войс режим...
полноценный", "максимально как разговор", "сразу все". Steps 3 and 5 of
[0016](0016-voice.md) become this one feature. Nothing here is built yet;
Settings > Voice today has only Spoken answers and Voice Lab.

## Why

LLMTray can speak answers ([0016](0016-voice.md) step 4: system voices and
Chatterbox). Since v0.9.3-beta.6, Chatterbox makes a whole sentence in
0.24–0.31 s per second of speech on the base M5. That is synthesis speed
only: each sentence is made whole before its audio is sent, so the first
sound still waits for one full sentence.

What's missing is talking to the chat model the way people talk to each
other: you speak, it answers aloud, you can cut in, and there are no
buttons in between.

It is not Voice Lab. Voice Lab stays as it is: a separate,
experimental speech-to-speech model, English only, with no tools. Here the
model is the one you already chat with, with the chat's profile, tools,
project files and memory, in Russian as well as English.

## The chain

microphone → end of turn (VAD, and meaning where partial transcripts
exist) → speech recognition → chat model (streaming) → sentences → voice
(Chatterbox or system) → speakers. While the model speaks, the microphone
stays open for barge-in.

### Speech recognition: the user picks

Settings > Voice will offer every option, each with its size and
languages, and download only the one picked (opt-in, as everywhere).
**Nothing is ever sent off the Mac.**

| option | download | languages | partial transcripts while you speak |
|---|---|---|---|
| macOS (`SFSpeechRecognizer`, `requiresOnDeviceRecognition`) | none | only languages with on-device support on that Mac | yes (streaming) |
| **Parakeet TDT 0.6B v3** | ~0.6 GB | 25 European, Russian included | by re-running on the growing buffer |
| Whisper large-v3-turbo | ~1.6 GB | 99 | by re-running (slower) |
| The model hears it | the recognizer's | the model's | — (see below) |

- **macOS is checked per language at run time.** On this Mac (macOS 27.2)
  `ru-RU` has no on-device recognition (`supportsOnDeviceRecognition` is
  false; `en-US` is true). Apple's server recognizer is never used, so for
  Russian macOS isn't an option there. The newer `SpeechAnalyzer` needs
  macOS 26, and the app supports macOS 14 and later.
  `SFSpeechRecognizer` also needs its own permission prompt and a restart
  per recognition task in a long session.
- **Default, provisionally:**
  - Parakeet v3, since it covers Russian on every Mac;
  - macOS where the conversation's language has on-device support and the
    user prefers no download.
  - Decided after measuring both on the user's voice.
- **The user wants to compare them** ("люблю эксперименты"). Accuracy and
  latency on the user's own voice go into the findings.
- **The model hears it** (Gemma 4 E2B/E4B/12B):
  - the turn's audio goes to the model as an `input_audio` clip
    ([0023](0023-spoken-messages.md));
  - a picked recognizer still runs, for the text the history and captions
    show; the model answers what it heard.
  - Limits are 0023's: 30 s a clip and 8 clips a request. A longer turn
    is sent as text from the recognizer.
  - Whether the history keeps the recognizer's text or the model's own
    reading of the clip is open.

### Turn-taking

- **End of turn.**
  - **With partial transcripts** (macOS streaming, or Parakeet re-run on
    the buffer every few hundred ms), by meaning: a finished phrase
    ("…как думаешь?") is answered after 0.3–0.4 s of silence. A phrase cut
    off on a conjunction or an "э-э" waits longer, so the model doesn't
    jump in while the user is thinking.
  - **Without them**, by silence alone (~0.7 s).
  - Thresholds are tuned on the user's voice.
- **Barge-in and backchannels, in two stages.** "Stop at once" and "don't
  stop for 'угу'" can't both hold on the first sound, so:
  1. When speech starts while the model talks, its voice ducks at once
     (volume down to ~20%). The generation keeps going.
  2. After ~0.3–0.5 s, or once the recognizer has words:
     - a short, quiet "ага", "угу" or "да-да" that ends is a backchannel:
       the volume comes back and the answer goes on;
     - more than a couple of words is an interruption: playback stops,
       the generation is cancelled, and the user's turn begins.
  - Thresholds are tuned on the user's voice. Voice Lab's echo gate (mic
    chunks under RMS 0.01 count as silence while speech plays) would hide
    quiet backchannels, so its level is part of that tuning.
- **What the history keeps.**
  - Interrupted: the sentences that finished playing, plus the cut one
    marked as interrupted. Nothing after it is kept, so the model doesn't
    "remember" saying what nobody heard.
  - Sentence granularity, because the voice gives no word timings:
    Chatterbox makes whole sentences, and the next one is being made
    while the current one plays.
- **Echo cancellation.**
  - Voice Lab's Voice Processing I/O cancels echo only for audio played
    through that same unit. Today spoken answers play through their own
    `AVAudioEngine` (Chatterbox) or `AVSpeechSynthesizer` (system voices),
    which the unit never hears.
  - So in voice mode all playback goes through the voice-processing unit:
    Chatterbox's PCM, and the system voice rendered to buffers
    (`AVSpeechSynthesizer.write`) instead of spoken directly.
  - Even then a trace remains (~0.001 RMS in Voice Lab), so the echo gate
    stays.
- **Hands-free.** The microphone reopens by itself after each answer. Esc
  or a click stops the conversation. A long silence lets the mode go to
  sleep.

### Speed

- **First words as soon as possible.** The first phrase goes to the voice
  at the first comma, not the first full stop.
- **Everything stays warm for the whole conversation**: the voice runner
  (no 5-minute idle quit while voice mode is on), the recognizer and the
  chat model. A cold voice runner costs a warm-up of up to ~9 s.
- **Target**: under 1.5 s from the end of the user's speech to sound.
  Today's estimate is 2–3 s.
- **To measure**: the voice speaking while the chat model is still
  generating share one GPU, so both get slower; and the memory of model,
  voice and recognizer together on 26 GB.

### How the model talks

- **Voice-mode prompt** (decided): one extra instruction on top of the
  model's profile, used only in voice mode.
  - Short and conversational, no lists, headings or code; it may ask back.
    Longer answers only on request.
  - The model is encouraged, not required, to open with a short, varied
    reaction in its own words ("Хм, смотри…", "Ага, понял"). That's the
    model talking, not a canned filler, and it gets the first word out
    sooner.
- **Reasoning is never spoken.** Proposed, not yet confirmed: thinking
  models get a low reasoning effort in voice mode, so they don't sit
  silent for 10 s.

### Fillers: "хм…", "секунду, сейчас гляну"

Fillers can't ship as audio: everyone's voice differs (built-in, a clip,
the system voice), and so does the language. So they're made on the fly,
once the voice and language are known.

- **Made in the silences.**
  - One phrase at a time, while the GPU is free: while the user speaks
    (only the recognizer runs then), or after the model finishes and
    waits.
  - An answer always goes first: a filler being made waits.
  - The pool fills itself over the first few turns, with no burst at
    start.
- **Same voice and language as the answers.** A pool exists per voice and
  language.
  - A new language mid-conversation gets its own pool on its first turn.
  - Until a pool has a phrase, only the visual "thinking" state shows.
- **Cached on disk**, keyed by voice + language + voice-model version. The
  same voice next time has its pool ready at once.
- **Played on silence.**
  - A filler plays only when more than ~1.2 s passes after the user's turn
    with no sound: the model is thinking, or a tool is running.
  - If the answer starts first, no filler plays.
  - If the answer is ready while a filler plays, the filler fades out
    within ~0.1 s: the answer never waits for it.
  - At most one filler per turn, and never the same one twice in a row.
- **Tool calls** (the stream shows them at once).
  - Built-in tools get a phrase by kind: "гляну в почте", "поищу в файлах
    проекта", "сейчас нарисую".
  - MCP tools get a general one ("секунду, сейчас посмотрю"). Their name
    and description are known, so one could be made from them later.
- **Texts.**
  - Our own lists for each language: predictable, and we control the tone.
  - As an experiment behind a switch: the model writes its pool once in
    its own style.
- **Switch**: fillers on or off. The visual "thinking" state is always
  there.

### How it looks

- **Inside the chat, taking over the chat area** while the conversation
  runs:
  - a large orb or wave that reacts to both voices;
  - live captions under it.
- **Caption timing.**
  - The user's words appear as the recognizer gives them.
  - The model's text is shown a sentence at a time, as each starts to
    play. Words are lit by time spread over the sentence, not by true
    word timing, which the voice doesn't provide.
- **The turns stay in the chat** as ordinary messages, saved with it, and
  the conversation can continue in text.

## Scope

**Everything goes in the first version** ("сразу все"): hands-free, barge-in
with backchannels, end of turn by meaning (where partial transcripts
exist), the voice prompt, fillers, and the recognizer choice.

## Open questions

- Low reasoning effort by default in voice mode: yes or no?
- The default recognizer: Parakeet, or macOS where it works on-device.
  Measure both on the user's voice.
- With "the model hears it": does the history keep the recognizer's text
  or the model's own reading of the clip?
- The exact filler lists, per language and per built-in tool kind.
- How the orb and captions look: draft them and look at the render before
  building.
