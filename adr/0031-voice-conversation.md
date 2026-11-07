# 0031 — Voice conversation

**Status: proposed** (2026-11-07). Discussed with the user and recorded so
nothing gets lost. The user's words: "сделать войс ту войс режим...
полноценный", "максимально как разговор", "сразу все". Steps 3 and 5 of
[0016](0016-voice.md) become this one feature.

## Why

LLMTray can speak answers ([0016](0016-voice.md) step 4: system voices and
Chatterbox, about 4x faster than real time since v0.9.3-beta.6). What's
missing is talking to the chat model the way people talk to each other:
you speak, it answers aloud, you can cut in, and there are no buttons in
between.

It is not Voice Lab. Voice Lab stays as it is: a separate,
experimental speech-to-speech model, English only, with no tools. Here the
model is the one you already chat with, with the chat's profile, tools,
project files and memory, in Russian as well as English.

## The chain

microphone → end of turn (VAD and meaning) → speech recognition → chat
model (streaming) → sentences → voice (Chatterbox or system) → speakers.
While the model speaks, the microphone stays open for barge-in.

### Speech recognition: the user picks

Settings > Voice offers every option, each with its size and languages,
and downloads only the one picked (opt-in, as everywhere):

| option | download | languages | notes |
|---|---|---|---|
| **macOS** (on-device Speech) | none | the system's, Russian included | streaming, lightest; **default** |
| Parakeet TDT 0.6B v3 | ~0.6 GB | 25 European | fastest neural one, in mlx-audio |
| Whisper large-v3-turbo | ~1.6 GB | 99 | for rare languages, slower |
| The model hears it | none | the model's | only for models that hear (Gemma 4 E2B/E4B/12B): the audio goes to the model itself; the text for the history comes from one of the above |

The user wants to compare them ("люблю эксперименты"), so the options are
measured on the user's own voice for accuracy and latency, and the results
go into the findings.

### Turn-taking

- **End of turn by meaning, not only by silence.**
  - A finished phrase ("…как думаешь?") is answered after 0.3–0.4 s of
    silence.
  - A phrase cut off on a conjunction or an "э-э" waits longer, so the
    model doesn't jump in while the user is thinking.
  - The thresholds are tuned on the user's voice.
- **Barge-in.** Speaking while the model talks stops it at once,
  mid-word, and cancels the generation.
  - The history keeps only what the user heard. The unspoken rest is cut
    from the message, so the model doesn't "remember" saying what nobody
    heard.
  - Echo cancellation (Voice Processing I/O, already in Voice Lab) keeps
    the model from hearing itself on speakers.
- **Backchannels.** A short, quiet "ага", "угу" or "да-да" while the model
  talks is not an interruption, and the model keeps going. More than a
  couple of words is an interruption.
- **Hands-free.** The microphone reopens by itself after each answer. Esc
  or a click stops the conversation. A long silence lets the mode go to
  sleep.

### Speed

- **First words as soon as possible.** The first phrase goes to the voice
  at the first comma, not the first full stop.
- **Everything stays warm**: the voice runner, the speech recognizer and
  the chat model.
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
  - Start the answer with a short, lively phrase ("Хм, смотри…", "Ага,
    понял"). That sounds more natural than any canned filler, and it gets
    the first word out sooner.
- **Reasoning is never spoken.** Thinking models get a low reasoning
  effort in voice mode, so they don't sit silent for 10 s. *(Proposed, not
  yet confirmed by the user.)*

### Fillers: "хм…", "секунду, сейчас гляну"

Fillers can't ship as audio: everyone's voice differs (built-in, a clip,
the system voice), and so does the language. So they're made on the fly,
once the voice and language are known.

- **Made in the silences.**
  - One phrase at a time, while the GPU is free: while the user speaks
    (only the light recognizer runs then), or after the model finishes
    and waits.
  - An answer always goes first; a filler waits.
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
  - If the answer starts first, no filler plays at all.
  - At most one filler per turn, and never the same one twice in a row.
  - An answer that arrives during a filler waits for it to end; fillers
    are about half a second.
- **Tool calls** (the stream shows them at once).
  - Built-in tools get a phrase by kind: "гляну в почте", "поищу в файлах
    проекта", "сейчас нарисую".
  - MCP tools get a general one ("секунду, сейчас посмотрю"), because only
    their names are known.
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
  - live captions under it, with words lit as they're spoken.
- **The turns stay in the chat** as ordinary messages, saved with it, and
  the conversation can continue in text.

## Scope

**Everything goes in the first version** ("сразу все"): hands-free, barge-in,
end of turn by meaning, backchannels, the voice prompt, fillers, and the
recognizer choice.

## Open questions

- Low reasoning effort by default in voice mode: yes or no?
- The exact phrase lists, per language and per built-in tool kind.
- Whether the macOS recognizer's Russian is good enough to stay the
  default (measure against Parakeet).
- How the orb and captions look: draft them and look at the render before
  building.
- Whether "the model hears it" also uses the model's own transcript or
  always takes the recognizer's.
