# 0032. Kaggle as a second model source: search and download there, and our mirror when Hugging Face can't be reached

Status: accepted (2026-11-09)

## Decision

LLMTray downloads models from Kaggle Models as well as Hugging Face.

1. **The model browser searches either.** A Hugging Face / Kaggle switch
   sits at the top. Kaggle results are MLX variations only:
   - Kaggle has no MLX framework, so a variation counts when its framework
     is "other" or "transformers" and its name or its model's name says MLX;
   - our mirror's variations always count.

   Each variation is one row, with its size, license and Kaggle page. A
   download goes into the models folder, through the same downloader as a
   Hugging Face one: parallel byte ranges for big files, pause and resume,
   size checks, the completion marker.
2. **Our mirror stands in for Hugging Face.** Every MLX release we publish
   on Hugging Face (roman220220) has a copy with the same files on Kaggle
   (romanromenskyi), one variation per repo. `Kaggle.Mirror` lists them.

   A download of one of those repos comes from Kaggle when:
   - **Settings › Models › Download from** is "Kaggle first"; or
   - it is "Hugging Face, Kaggle if it can't be reached" (the default) and
     Hugging Face doesn't answer its API with JSON. That covers a failed
     connection, a proxy's block page and a 403.

   This applies everywhere a model is fetched:
   - the browser and the first-run wizard's queue (chat models);
   - image models (mflux), music, spoken answers and the voice
     conversation's models (through `AudioRuntime.snapshotDownload`), the
     Russian stress files and the project-files embedder (see below);
   - an MTP drafter. That one goes into the Hugging Face cache's own layout
     (`snapshots/kaggle-v<N>`, `refs/main`), where the runtime looks for it.
3. **A mirrored model is the same model.** It is saved under its Hugging
   Face name (`roman220220/...`), so profiles, drafters, media entries and
   "installed" checks don't care where it came from. Other Kaggle models go
   to `<owner>/<model>-<variation>`.
4. **No account is needed for public models.** The API lists and serves
   them anonymously. Gated or private models need the user's Kaggle token
   (Settings › Models, kept in the Keychain), and gated ones also need
   their terms accepted on kaggle.com. The token is sent only to
   www.kaggle.com, never to the storage links it redirects to. It can be a
   new-style access token (Bearer) or kaggle.json's `username:key` (Basic).
5. **When Hugging Face is blocked and there is no Kaggle copy**, the error
   says exactly that, instead of a Python traceback.

## Why

Some networks block huggingface.co: company devices, some countries. On
those, LLMTray could install nothing: no chat model, no image or music
model. Kaggle is commonly reachable where Hugging Face isn't, and we
already publish every release there. Making the app use that copy turns a
dead end into a working install.

### The API, as measured (2026-11-09)

- `GET /api/v1/models/list?search=&sortBy=&pageSize=&pageToken=`: models,
  each with its variations (`instances`). Each variation has its framework,
  slug, current `versionNumber`, `totalUncompressedBytes`, `licenseName` and
  overview (Markdown). Sort values: hotness, downloadCount, voteCount,
  notebookCount, createTime, publishTime. Anything else is a 400.
- `GET /api/v1/models/{owner}/{model}/{framework}/{variation}/get`: one
  variation, with its current version.
- `GET .../{version}/files?pageSize=&pageToken=`: names and sizes, paged
  by `nextPageToken`.
- `GET .../{version}/download/{path}`: a 302 to a signed
  storage.googleapis.com link, valid for days, that serves byte ranges
  (206). So the parallel-range downloader works unchanged. Each range
  request goes back through the API URL, so an expired link doesn't
  matter.
- All of these work without a token for public models. A gated model
  answers 403 with `{"message": "User has not consented to terms of
  use."}`, with or without a token, until the user accepts its terms; the
  message is shown.
- A Kaggle version never changes once published. A download pins the
  version it listed, and its files' revision (in the folder's manifest) is
  `kaggle-v<N>`, so an interrupted download resumes against the same files.

### Why the "is Hugging Face reachable" check, not "retry after a failure"

A blocked network doesn't always fail the connection. Some answer 200 with
their own HTML page, or a 403 that looks like a gated repo. So the check
asks the Hub API for JSON (`/api/models?limit=1`, 10 s timeout) and keeps
the answer for 5 minutes, or 1 minute after a failure. That one request
decides every download in that window. A failed Hugging Face download is
checked the same way afterwards, to explain itself.

### The models our features use

The third-party models LLMTray's features download have copies too, on one
Kaggle page, `romanromenskyi/llmtray-components` (`Kaggle.Mirror.components`):
- music turbo: `mlx-community/ACE-Step1.5-MLX-4bit`, and ACE-Step's 1.7B
  planner (only the `acestep-5Hz-lm-1.7B` folder of `ACE-Step/Ace-Step1.5`);
- spoken answers: `mlx-community/S3TokenizerV2` and `ruaccent/accentuator`;
- voice conversation: Parakeet, Whisper (its weights and, as a variation of
  its own, `openai/whisper-large-v3-turbo`'s tokenizer files), silero-vad,
  smart-turn;
- project search: bge-m3.

Each copy is unchanged and holds only the files the app takes, at the
revision it pins where it pins one (ruaccent, bge-m3). The variation's card
names the upstream repo, the revision and files, the authors and the
license. Kaggle's license list has no BSD-2-Clause, so smart-turn is tagged
BSD-3-Clause and its card says the BSD-2-Clause terms apply.

These are found only through the features that use them: the browser
leaves the page out (`Mirror.isComponent`). ruaccent's script fetches its
files by URL, so the app fetches the Kaggle copy into the folder first and
the script only builds (Kaggle unpacks `.gz` files on upload, so the script
gzips the dictionaries back first); the embedder's files are checked against their
sha256 whichever source they came from.

### Keeping the mirror current

The mirror is uploaded by quant-ternary's `tools/kaggle/` (releases.json;
components.json for the components). A new release is added there and to
`Kaggle.Mirror.table` together; a new component, or a new pinned revision of
one, to components.json and `Kaggle.Mirror.components`. A
Hugging Face repo updated after its copy was made (a card, a template) is
behind on Kaggle until the copy is refreshed. The weights are what matter
for a download, and those don't change after release.
