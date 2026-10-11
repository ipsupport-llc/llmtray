# 0023 — Spoken messages for models that hear

**Status: accepted** (2026-10-11, asked for by the user: "models that have
audio should be able to hear us").

## Decision

A model that hears (Gemma 4 E2B/E4B with their audio tower, the 12B
unified model with its audio embedder -- `ModelDiscovery.supportsAudio`,
the setup's "hears audio") gets a microphone in the composer, next to
Send.

- **Recording**: click to record, click again to stop; the clip waits by
  the field (its length, a remove button) until the message is sent, and
  Send stops one still going and sends it too. Voice Lab's capture
  (`MicrophoneCapture`, adr/0016): 16 kHz mono PCM16 collected in memory
  and wrapped as a WAV in memory (`WAVFile`, `ChatRecorder`) -- nothing
  touches the disk, a temporary chat included. At most 30 s a clip (the
  server's limit: Gemma 4's extractor cuts longer ones); it stops itself
  there. The microphone permission is asked the first time it's used,
  as Voice Lab's.
- **The message**: the recordings are the user message's `audios`
  (the field generated music uses), played back in its bubble by the
  same player, saved with the chat as the music is (WAV files beside the
  images); a recording has no Regenerate / Tweak / Remove. A message may
  be only a recording.
- **The request**: OpenAI `input_audio` parts (base64 WAV) after the
  text and images. A model that doesn't hear gets the text, or "(audio)"
  for a message that was only a recording -- as "(image)" for a model
  that doesn't see. The size estimate counts a clip by its length (one
  soft token per 40 ms), never its base64, and a request with audio
  isn't a calibration (as images aren't).
- **The server** (fork ipsupport-llc/mlx-lm#40): `input_audio` parts
  decoded (WAV PCM 8-32 bit, 8-192 kHz, up to 8 channels, 20 MB, 30 s a
  clip, 8 clips), resampled to 16 kHz mono, rendered by the template as
  `<|audio|>`, expanded to begin + soft tokens + end as HF's processor
  counts them, featurized by HF's own feature extractor and fused
  through the model's audio path. Like images: no batch, no speculation,
  no warm next turn, no thinking budget.

Not in this step: attaching an audio file through +, longer clips
(segmenting), other models that hear (they need their own processors).

## Verification

- LLMTrayCore: the WAV header, the audio token estimate, no calibration
  with audio.
- Fork: extraction (48 kHz stereo to 16 kHz mono), every malformed clip
  a 400, the expansion count equal to HF's (3 s = 75 tokens), pad at
  audio positions, audio keys apart from image spans, the unified count.
- By hand, with the user's go-ahead (a model run on the Mac): Gemma 4 E4B
  answers a question spoken into the composer; a text model gets
  "(audio)"; a temporary chat writes no file.
