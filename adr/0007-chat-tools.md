# 0007 — The chat's tools

## Decision

- **Native Swift tools, no MCP client.** Every tool is a `ChatTool`
  (`ChatTools.swift`) running in the app: declaration, when it's offered,
  `run(arguments, context:)`. Tool descriptions were ported from an MCP
  server tuned for small local models (`rromenskyi/mcp-weather-simple`,
  see `WebTools.swift`), the protocol was not. What the tools rely on
  wouldn't pass through it: the chat's images (`ToolContext`), per-turn
  counters, the app-wide `GenerationQueue` and unloading the chat model,
  results that are an image or a song for the chat, not text.
- **One registry.** `ChatToolbox` holds generate_image, edit_image,
  view_image, generate_music and `ToolCatalog.makeTools()`; `ToolCatalog`
  lists the selectable ones for Settings and the popover (title, globe =
  network, data credit). Per profile: `tools.enabledTools`, default the
  local ones only (`get_current_date`, `calculate`). Logic worth testing
  lives in LLMTrayCore: `Calculator` (recursive descent — no `eval`, no
  NSExpression, which can call arbitrary selectors), `WebParsing`,
  `SolarCalculator` / `OpenMeteoFormat` (`Weather.swift`).
- **Schemas by hand.** OpenAI function JSON built with
  `SelectableTool.function(...)`. The selectable utility and web tools
  answer compact JSON, failures `{"error": ...}`, never a throw; the
  generators, `view_image` and unknown or switched-off tools answer
  plain text. `--dump-tool-definitions` prints every
  declaration plus the tool-use rule (for evals), `--run-tool <name>
  '<json>'` runs one (`ToolRunnerCLI.swift`).
- **Keyless public APIs only**, one ephemeral `WebFetch.session` and an
  honest User-Agent (`LLMTray/<version>` + repo). A result's `"source"` is
  collected per answer (`ChatMessage.sourcesByAnswer`), shown under it and
  saved with the chat, where tool messages aren't.

## The loop (ChatClient.executeToolCalls)

A response with tool calls runs them and sends the results back. Per
turn: at most `maxToolRoundsPerTurn` = 4 rounds, `maxToolCallsPerRound` =
8 calls per response, one image (generate or edit) and one song. The
last allowed round is requested without tools; calls in that answer are
refused and the turn ends — an error only if the turn produced nothing.
`ToolResult`: `.text`, `.refused`, `.generatedImage`, `.generatedAudio`,
`.imageForModel` (view_image; a hidden user message, next request only).
With tools declared, the profile's `toolUsePolicy` joins the system
prompt (`ChatRequestBuilder`).

## Lessons

- **Small models loop on tool results.** A 4B model treated a successful
  image as "not done yet" and called again (241e4f3): runs are capped,
  and the refusal says plainly not to retry without a new user message.
- **Refusals read back cause loops.** Read in later turns, "one was
  already generated" made the model think no image was made; it called
  generate_image until the round limit (81e7f20). Now `.refused` messages
  are dropped from earlier turns (`withoutEarlierRefusals`) and a spent
  generator isn't declared (`ChatToolbox.definitions`).
- **Undeclared isn't uncalled.** A model that saw generate_image earlier
  kept calling it after it was switched off, and the server still parses
  the call (c967eb2). The generators get to run anyway and explain why
  not; other tools answer "isn't available".
- **The rule says when not to call.** Chat templates only say *how*: the
  ipsupport-code Nemotron LoRA called generate_image on a plain "привет"
  10 times in 20 (`Profile.defaultToolUsePolicy`). An unedited former
  rule is upgraded in Default (`ProfileStore.ensureDefault`).
- **Descriptions steer.** convert_currency's "rates change daily, never
  assume one" took Nemotron 3 Nano 4B from calculate with an invented rate
  to the tool 9/9 (9dcdcfc).
- **Model-supplied numbers are hostile**: indices compared, never
  subtracted from (`Int.min - 1` traps); image sides clamped before any
  arithmetic (2a503de).
- **Nothing on disk**: the shared URLCache held tool queries and answers;
  hence the ephemeral session, old cache and cookies purged (2a503de).
- **Protocol-valid history**: every tool call gets a result — Stop answers
  open ones "Cancelled by the user." (`closeDanglingToolCalls`).
- **Service quirks**: Wikimedia answers 429 without a descriptive
  User-Agent; restcountries' keyless API is gone, so country facts come
  from Wikidata (5bce133); `+` in a query is percent-encoded ("C++" came
  through as "C  "); `47.4`, not `47.399999999999999`
  (`SelectableTool.shortestNumbers`).
- **Regenerate re-runs the same edit.** edit_image without `index` means
  "the latest", which is its own result afterwards: the saved call gets
  the index it meant (`ChatClient.pinnedArguments`), moved when images are
  inserted or removed before it (`shiftPinnedEditIndices`).

Per-turn caps and the unload for generation: also
[0003](0003-field-lessons.md).
