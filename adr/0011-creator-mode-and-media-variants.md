# 0011 — Creator mode and media variants

## Decision

- **Creator mode** (profile, off by default;
  `Sources/LLMTray/CreatorMode.swift`): each image, edit or song the chat model asks for is first shown as a
  `GenerationDraft` — the prompt it wrote, lyrics and duration, the model,
  the shape (1:1 … 9:16), the music knobs — which goes ahead by itself
  after a countdown (`creatorCountdown`, default 3 s). Any edit holds it
  (`hold()`, through the `held` bindings) until Generate; Skip tells the
  model the user chose not to make it.
- **Each generated image and song records its `MediaSource`**
  (`ChatModels.swift`): the tool, the call's arguments (as the model or the
  draft wrote them — the runner's clamping and defaults apply again when
  it's re-run), the model a draft chose. It's persisted with the session
  (`imageSources`, `audioSources`, index-aligned with the media). Media
  without one can't be made again: attachments, images in a model's
  response, messages from before sources existed.
- **Regenerate** re-runs that source with a new seed; **Tweak…** opens it
  as a draft first (countdown 0: waits for Generate); **Remove** takes one
  out (`ChatClient.regenerateMedia`, `removeMedia`). No chat-model
  request: only the generator runs, through the queue and the unload of
  [0009](0009-media-generators.md). A variant is inserted right after the
  one it came from instead of replacing it (it replaced it in b0f87b9;
  20c7472): nothing is lost, and Remove picks which to keep.

Most of this landed in PR #83 (20c7472, a65492f, f5d313e) and PR #85
(68836e9).

## Rules

- **Drafts come before the queue and the unload.** The user's editing
  must not hold the generator for other chats, nor keep the chat model
  unloaded.
- **`decide()` resolves nil on cancellation** (Stop, another chat;
  `cancel()` resolves the draft too). A Tweak draft cancelled before it
  was shown used to wait forever (a65492f).
- **Settings are read again after the wait** — a draft may sit for
  minutes — and each call runs with its own draft's models
  (`GenerationDraft.apply(to:)`, `settingsFor` in the tool round). No
  draft for a call that won't run, a model not set up included
  (`willGenerate`, `isReady`).
- **An untouched draft keeps the call's exact size**: only picking another
  shape replaces width/height (`requestedAspect`, a65492f).
- **The model is part of the source**: `GenerationDraft.pinning` runs a
  Regenerate with the model recorded there (when it still exists), so a
  variant of a Tweak made with another model isn't redone with whatever
  the profile has now (a65492f).
- **edit_image's target is pinned.** An omitted `index` means "the
  latest image" at call time; `pinnedArguments` stores the actual index,
  or a Regenerate after more images would edit a different one (b0f87b9).
- **Pinned indexes follow inserts and removes.** `index` counts all the
  chat's images, so a variant inserted or an image removed before a pinned
  one shifts it (`shiftPinnedEditIndices`). When the pinned image itself
  is removed, the index becomes 0 and `canRegenerateMedia` refuses: the
  edit would otherwise be made again from the next image (f5d313e).
- **Filenames are materialized before indexes shift.** A message never
  loaded from disk has no stored names; they're derived from the index
  (`<id>-<n>.png`, `<id>-audio-<n>.wav`). Insert and Remove first write
  the current names out, then give a variant its own UUID name — else the
  next save would pair files with the wrong media.
- **Playback stops before a song variant lands**: a clip's id is its
  index, and one playing would take the variant's.
- **A Tweak draft is anchored under the media it remakes**
  (`GenerationDraft.anchor`). At the chat's end it was below the model's
  text after the song, out of sight (68836e9).
- **A stale result is dropped.** Stop (`turnToken`) or a chat switch
  (`conversationEpoch`) while regenerating drops the result and its
  errors (5f06a89), as for any turn ([0003](0003-field-lessons.md)).
