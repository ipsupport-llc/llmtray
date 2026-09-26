# Generates one piece of music with ACE-Step 1.5 (MIT) through mlx-audio,
# for LLMTray's generate_music tool. The request arrives as JSON on stdin;
# progress and the result go to stdout as "@@LLMTRAY <KIND> <data>" lines:
#   STAGE <text>        what it's doing now
#   STEP <n> <total>    overall progress, 0...100
#   AUDIO <base64 wav>  the result (16-bit stereo, 48 kHz)
# Nothing is written to disk: the audio stays in memory, as a temporary
# chat requires.
#
#   python llmtray_music_runner.py --dit <dir> --lm <dir> < request.json
#   request: {"caption": ..., "lyrics": "", "duration": 30, "language": "en", "seed": 0, "steps": 8}
#
# The LM planner is prompted the way the official ACE-Step pipeline does
# (and the LM was trained on): mlx-audio's own prompt layout makes the LM
# ignore the duration and the lyrics, so vocals come out unintelligible.
# Measured in quant-ternary/acestep-quant/docs/FINDINGS.md (vocal WER 0.94
# with mlx-audio's planner, 0.56 with this one, 0.66 for the official
# pipeline).
import base64
import glob
import io
import json
import os
import re
import struct
import sys


OUT = sys.stdout   # protocol lines only; mlx-audio's own prints are muted below


def emit(kind, data=""):
    OUT.write(f"@@LLMTRAY {kind} {data}\n")
    OUT.flush()


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


request = json.loads(sys.stdin.read())
caption = str(request.get("caption", "")).strip()
lyrics = str(request.get("lyrics", "")).strip()
duration = float(min(max(float(request.get("duration", 30)), 10), 180))
language = str(request.get("language") or "unknown")
steps = int(request.get("steps", 8))
seed = int(request.get("seed") or 0) or int.from_bytes(os.urandom(4), "big")

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
import yaml  # noqa: E402

INSTRUCTION = "Generate audio semantic tokens based on the given conditions:"
SAMPLES_PER_FRAME = 1920  # 48 kHz / 25 Hz latents


def load_lm(path):
    """The official LM checkpoints store their keys without the "model."
    prefix mlx-lm's Qwen3 expects: remapped, as the official loader does."""
    import mlx_lm
    from pathlib import Path
    from mlx_lm.utils import _get_classes, load_config, load_tokenizer

    try:
        return mlx_lm.load(path)
    except ValueError:
        local = Path(path)
        config = load_config(local)
        weights = {}
        for f in glob.glob(str(local / "model*.safetensors")):
            weights.update(mx.load(f))
        if not next(iter(weights)).startswith("model."):
            weights = {f"model.{k}": v for k, v in weights.items()}
        model_class, args_class = _get_classes(config=config)
        model = model_class(args_class.from_dict(config))
        if hasattr(model, "sanitize"):
            weights = model.sanitize(weights)
        model.load_weights(list(weights.items()), strict=True)
        mx.eval(model.parameters())
        model.eval()
        return model, load_tokenizer(local)


def sample(logits, temperature=0.85, top_p=0.9):
    probs = mx.softmax(logits.astype(mx.float32) / temperature, axis=-1)
    order = mx.argsort(-probs)
    sorted_p = probs[order]
    sorted_p = mx.where((mx.cumsum(sorted_p) - sorted_p) < top_p, sorted_p, 0)
    return int(order[mx.random.categorical(mx.log(sorted_p + 1e-20))].item())


class Stream:
    """One prompt's KV cache, fed a token at a time."""

    def __init__(self, model, tokens):
        from mlx_lm.models.cache import make_prompt_cache

        self.model, self.cache = model, make_prompt_cache(model)
        self.logits = self.feed(tokens)

    def feed(self, tokens):
        return self.model(mx.array(tokens)[None], cache=self.cache)[0, -1]

    def push(self, token):
        self.logits = self.feed([token])


def parse_cot(body):
    """The LM's <think> YAML; when that doesn't parse (a caption with an
    unquoted colon, say), the known "key: value" lines one by one -- the
    official constrained decoder never lets it be malformed."""
    keys = ("bpm", "caption", "duration", "keyscale", "language", "timesignature")
    try:
        meta = yaml.safe_load(body)
        if isinstance(meta, dict):
            return {k: v for k, v in meta.items() if k in keys}
    except yaml.YAMLError:
        pass
    meta, current = {}, None
    for line in body.splitlines():
        m = re.match(r"^(\w+):\s*(.*)$", line)
        if m and m.group(1) in keys:
            current = m.group(1)
            value = m.group(2).strip()
            meta[current] = int(value) if value.isdigit() else value
        elif current == "caption" and line.startswith(" "):
            meta["caption"] = f"{meta['caption']} {line.strip()}".strip()   # a wrapped caption
    return meta


def plan(model, tokenizer, on_progress):
    """Official layout: system instruction, user "# Caption / # Lyric";
    phase 1 the LM's metadata in <think> (the duration and language asked
    for replace its own), phase 2 audio codes only, CFG 2.0 against
    "NO USER INPUT", duration x 5 codes."""
    template = lambda user: tokenizer.apply_chat_template(
        [{"role": "system", "content": f"# Instruction\n{INSTRUCTION}\n\n"}, {"role": "user", "content": user}],
        tokenize=False, add_generation_prompt=True)
    enc = lambda s: tokenizer.encode(s, add_special_tokens=False)
    prompt = template(f"# Caption\n{caption}\n\n# Lyric\n{lyrics}\n")

    stream, text = Stream(model, enc(prompt)), ""
    eos = set(getattr(tokenizer, "eos_token_ids", None) or [tokenizer.eos_token_id])
    for _ in range(512):
        token = sample(stream.logits)
        if token in eos:
            break
        text += tokenizer.decode([token])
        if "</think>" in text:
            break
        stream.push(token)
    meta = parse_cot(text.split("<think>", 1)[-1].split("</think>", 1)[0])
    meta["duration"] = int(round(duration))
    if language != "unknown":
        meta["language"] = language
    cot = "<think>\n" + yaml.dump(meta, allow_unicode=True, sort_keys=True).strip() + "\n</think>"

    cond = Stream(model, enc(prompt + cot + "\n\n"))
    uncond = Stream(model, enc(template("NO USER INPUT") + "<think>\n\n</think>\n\n"))
    vocab = tokenizer.get_vocab()
    mask = [False] * (max(vocab.values()) + 1)
    for token_text, i in vocab.items():
        if (m := re.fullmatch(r"<\|audio_code_(\d+)\|>", token_text)) and int(m.group(1)) < 64000:
            mask[i] = True
    mask = mx.array(mask)
    need, codes = int(round(duration * 5)), []
    for n in range(need):
        logits = uncond.logits + 2.0 * (cond.logits - uncond.logits)
        width = min(logits.shape[-1], mask.shape[0])
        token = sample(mx.where(mask[:width], logits[:width], -mx.inf))
        codes.append(token)
        cond.push(token)
        uncond.push(token)
        if n % 25 == 0:
            on_progress(n / need)
    return "".join(tokenizer.decode([t]) for t in codes), meta


def wav_bytes(audio, rate):
    """16-bit PCM WAV, in memory. audio: [samples, channels] floats."""
    pcm = (np.clip(audio, -1, 1) * 32767).astype("<i2")
    channels = pcm.shape[1]
    body = pcm.tobytes()
    header = b"RIFF" + struct.pack("<I", 36 + len(body)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, channels, rate, rate * channels * 2, channels * 2, 16) + b"data" + struct.pack("<I", len(body))
    return header + body


# mlx keeps freed buffers for reuse: bounded, so the LM freed after planning
# really goes before the DiT loads.
mx.set_cache_limit(1 << 30)
mx.random.seed(seed)
emit("STAGE", "Writing the song")
emit("STEP", "0 100")
lm, tokenizer = load_lm(arg("--lm"))
codes, meta = plan(lm, tokenizer, lambda f: emit("STEP", f"{int(5 + 60 * f)} 100"))
del lm, tokenizer
mx.clear_cache()

emit("STAGE", "Composing")
emit("STEP", "65 100")
from mlx_audio.tts.models.ace_step import lm as lm_module  # noqa: E402
from mlx_audio.tts import load  # noqa: E402   (quantizes the modules a 4-bit checkpoint says are)

# mlx-audio's own planner is skipped: it hands over the codes planned above.
lm_module.ACEStepLM.load = lambda self: setattr(self, "_loaded", True)
lm_module.ACEStepLM.generate_audio_codes = lambda self, *a, **k: (codes, meta)
# mlx-audio picks the model's module from the checkpoint's model_type
# ("acestep") mapped through the parts of its path -- a local folder's
# name doesn't give that away, so it's said here.
import mlx_audio.utils as audio_utils  # noqa: E402

pick_module = audio_utils.get_model_class
audio_utils.get_model_class = lambda model_type, model_name, category, model_remapping: pick_module(
    "ace_step", None, category, model_remapping)
model = load(arg("--dit"))

# The VAE decodes in 10 s windows (16 latent frames of overlap each side,
# cut off again): bit-identical to one whole decode, about half its peak,
# and the peak no longer grows with the length.
whole_decode = model.vae.decode


def decode(latents):
    total, chunk, overlap = latents.shape[1], 250, 16
    emit("STAGE", "Mixing")
    emit("STEP", "85 100")
    if total <= chunk + 2 * overlap:
        return whole_decode(latents)
    pieces = []
    for start in range(0, total, chunk):
        end = min(start + chunk, total)
        lo, hi = max(0, start - overlap), min(total, end + overlap)
        audio = whole_decode(latents[:, lo:hi, :])
        first = (start - lo) * SAMPLES_PER_FRAME
        audio = audio[:, :, first: first + (end - start) * SAMPLES_PER_FRAME]
        mx.eval(audio)
        pieces.append(audio)
        mx.clear_cache()
    return mx.concatenate(pieces, axis=-1)


model.vae.decode = decode
sys.stdout = io.StringIO()   # mlx-audio's prints aren't protocol lines
try:
    results = list(model.generate(text=caption, lyrics=lyrics, duration=duration, seed=seed, num_steps=steps,
                                  vocal_language=language, verbose=False))
finally:
    sys.stdout = OUT
audio = np.array(results[-1].audio.astype(mx.float32))
if audio.ndim == 2 and audio.shape[0] == 2 and audio.shape[1] != 2:
    audio = audio.T
emit("STEP", "100 100")
emit("AUDIO", base64.b64encode(wav_bytes(audio, results[-1].sample_rate)).decode())
