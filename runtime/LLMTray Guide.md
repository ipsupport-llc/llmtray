# LLMTray Guide

LLMTray runs AI models on your Mac: chat, images, music and voice, plus an
OpenAI-compatible server for your coding agents and apps. Everything runs
locally; nothing you type, attach or generate is sent to a cloud.

## Getting started

1. Pick a chat model. The setup assistant suggests the ones that fit your
   Mac's memory; you can download others from Hugging Face later.
2. Start chatting. The model loads the first time you send a message.
3. Turn on the extras you want in Settings: image generation, music, voice,
   project files. Each one downloads what it needs only when you turn it on.

LLMTray lives in the menu bar. Click its icon for the chat; Open Chat (or
New Chat) opens it in its own window.

## Models

### Which model should I use?

- **Gemma 4 E2B / E2B Phone** (8 GB Macs): quick, simple answers; reads
  images and hears audio.
- **Gemma 4 E4B** (16 GB): a good everyday model; reads images, hears audio,
  calls tools.
- **Gemma 4 12B** (16 GB and up): better answers than E4B, slower; images and
  audio too.
- **Gemma 4 26B-A4B** (24 GB and up): the strongest everyday model for its
  speed: a mixture of experts with 4B parameters active per token.
- **Gemma 4 31B** (32 GB and up): the strongest on hard questions, the slowest.
- **Nemotron coding models**: made for tool calling in coding agents.

Smaller models are faster and leave memory for other apps; bigger ones answer
better. Settings › Models shows each model's size and what it can do (reads
images, hears audio, calls tools, reasons, writes code). Audio goes to a
model through the API (below); the chat takes images.

### Downloading and removing models

- **Download:** Settings › Models › Browse Hugging Face… (in the version
  from our website also from the terminal: `llmtray pull org/name`). Models
  are MLX models (one folder per model, `org/name`).
- **Remove:** the trash button next to a model in Settings › Models. It goes
  to the Trash, so you can still restore it.
- **Models folder:** Settings › Models › Models folder. Image, music and voice
  models live there too, under their Hugging Face names.

### Profiles: per-model settings

Settings › Profiles holds a model's settings: temperature and sampling, the
system prompt, which tools it may use, image and music generation, context
and performance. Each model uses a profile (Default unless you pick another
in Settings › Models).

## Chat

- **Attach images** with the paperclip or by dragging them into the chat (with
  a model that reads images). Documents dragged into a project's chat are
  added to the project's files.
- **Thinking:** models that reason show a "Thought process" you can open.
- **Temporary chats** aren't saved and can't change files.
- **Compact** shortens a long chat into a summary so it fits the model's
  context; it can also happen automatically (Settings › General › Compaction).
- **Regenerate** asks for the last answer again.

## Projects

A project groups chats with their own instructions and files.

- **Instructions:** the project's system prompt, used in every chat in it.
- **Files:** add documents (PDF, text, Markdown, Office files…) in the
  project's Files window. The model searches them and cites the pages it
  used; click a citation to open the page.
- **Searching files needs Project files turned on:** Settings › Files ›
  Project files. Without an embedding model the search matches words; with
  one (downloaded there, about 1 GB) it also finds passages by meaning.
- **Pinned files** go into every request of the project's chats as a whole
  (good for a short reference the model must always see).

## Tools

Models that call tools can use LLMTray's built-in tools when you ask for
something they can't know:

- On your Mac: date and time, calculator.
- On the web (off until you turn them on in the profile): web search, news,
  Hacker News, Wikipedia, country facts, public holidays, currency rates,
  weather, hourly forecast, air quality, sunrise and sunset, the time in a
  city.

Turn tools on or off per profile: Settings › Profiles › Prompt & tools.

## Working with your folders

A chat can look at and tidy a folder you allow (for example Downloads):
list it, find duplicates, and propose new folders, moves, renames and moves
to the Trash.

- Allow a folder from the chat's folder menu (Allow Folder…). Nothing outside
  the folders you allow is touched.
- **Nothing changes until you approve:** the proposed changes appear as a plan
  card; tick what you want and press Approve. Undo takes the changes back.
- Changes proposed right after the model read your files are marked so; any
  move to the Trash among them starts unticked.

## Images

Turn on image generation in Settings › Profiles › Image generation and pick a
model (Z-Image Turbo, or FLUX.2 klein, which can also edit an image). Then
ask in the chat: "draw a fox in the snow". To change an image, attach it and
say what to change.

**Creator mode** shows a draft of the request first, so you can adjust the
prompt, size and model before the image is made.

## Music

Turn on music generation in Settings › Profiles › Music generation. Ask for a
song with a style and lyrics: "a calm piano song about the sea". Songs play
in the chat and can be saved or shared.

## Voice

Voice Lab (Settings › Voice) lets you talk with a voice model in real time.
It uses the microphone only while you use it; the audio stays on your Mac.

## Connect your coding agents and apps

LLMTray serves an OpenAI-compatible API on your Mac.

- **Address:** `http://127.0.0.1:8765/v1` (Settings › Server shows it; the
  port can be changed there).
- **Model name:** each model's alias in Settings › Models (by default its
  folder name). `GET /v1/models` lists them.
- **API key:** any value; the server runs on your Mac only.
- Point any app or coding agent that speaks the OpenAI API at that address:
  set the base URL to `http://127.0.0.1:8765/v1` and the model to an alias.
- **Other devices** on your network can use it after you turn on network
  access in Settings › Server › Network.
- **Switching models:** a request for another model can load it; Settings ›
  Server › Model switching decides whether apps may switch it.

From the terminal, in the version downloaded from our website (the Mac App
Store version has no command-line tool): `llmtray`, installed in Settings ›
General.

- `llmtray status` — the server's state and address
- `llmtray models` — your chat models
- `llmtray start [model]`, `llmtray stop`
- `llmtray chat "prompt"` — ask the model in the terminal
- `llmtray pull org/name` — download a model
- `llmtray image "prompt"` — make an image, saved as a PNG
- `llmtray api` — the endpoint for other apps

## Speed and memory

- A model must fit in your Mac's memory; the setup assistant and Settings ›
  Models warn when one barely fits.
- Smaller models answer faster. Long chats and big documents take more memory
  and time; Compact helps.
- Settings › Benchmark measures your Mac's speed with a model and can tune the
  profile's performance settings.

## Privacy

Your chats, files, images and audio stay on your Mac. LLMTray has no account
and no ads. Web tools, model downloads and anonymous usage statistics (which
you can turn off in Settings › General) are the only things that use the
network; the privacy policy lists exactly what is sent.

## Getting help

- Settings › General › Report a Bug… prepares a report you can read before
  sending it.
- Email: bugreport@ipsupport.us
