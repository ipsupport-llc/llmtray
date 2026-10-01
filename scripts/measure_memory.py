#!/usr/bin/env python3
"""Real memory of every model LLMTray runs, on this Mac: each runner started
the way the app starts it, its phys_footprint (which on Apple Silicon
includes the GPU's memory) sampled with /usr/bin/footprint every half
second, the peak kept. Feeds runtime/feature_memory.json (peak_gb is GiB:
peakBytes = peak_gb * 2**30), which gates the heavy features by RAM, and
the README's Memory table.

  python3 scripts/measure_memory.py --cases all --json /tmp/memory.json
  python3 scripts/measure_memory.py --cases image-zimage-1024,chat-e2b-4k

Uses the app's own venvs and model folders (Application Support/LLMTray,
the models folder). Runs one case at a time, --cool seconds apart.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HOME = os.path.expanduser("~")
APP = f"{HOME}/Library/Application Support/LLMTray"
RUNTIME = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runtime")
MODELS = os.environ.get("LLMTRAY_MODELS_ROOT", f"{HOME}/.lmstudio/models")
SERVER_PY = f"{APP}/mlx_server_venv/bin/python3"
MFLUX_PY = f"{APP}/mflux_venv/bin/python3"
AUDIO_PY = f"{APP}/music_venv/bin/python3"


def footprint_mb(pid: int) -> float | None:
    try:
        # In bytes: the formatted output rounds anything past 10 GB to whole GB.
        out = subprocess.run(["footprint", "-f", "bytes", "-p", str(pid)], capture_output=True, text=True, timeout=10).stdout
    except subprocess.TimeoutExpired:
        return None
    # The kernel's own high-water mark: no peak is missed between samples.
    m = re.search(r"phys_footprint_peak:\s+(\d+)\s*B", out) or re.search(r"phys_footprint:\s+(\d+)\s*B", out)
    return int(m.group(1)) / 2**20 if m else None


def run_case(argv, stdin_bytes, env_extra, timeout) -> dict:
    env = dict(os.environ, HF_HUB_OFFLINE="1", PYTHONDONTWRITEBYTECODE="1", TOKENIZERS_PARALLELISM="false", **env_extra)
    t0 = time.time()
    p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    peak = [0.0]
    stop = threading.Event()

    def tree(pid: int) -> list[int]:
        kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
        return [pid] + [q for k in kids for q in tree(int(k))]

    def sample():
        # The whole process tree: the voice wrapper's runner is a child.
        while not stop.is_set():
            total = sum(mb for q in tree(p.pid) if (mb := footprint_mb(q)))
            peak[0] = max(peak[0], total)
            stop.wait(0.5)

    threading.Thread(target=sample, daemon=True).start()
    try:
        _, err = p.communicate(stdin_bytes, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        _, err = p.communicate()
    stop.set()
    tail = err.decode(errors="replace").strip().splitlines()[-1:] if p.returncode else []
    return {"peak_gb": round(peak[0] / 1024, 2), "seconds": round(time.time() - t0), "rc": p.returncode, "error": tail[0] if tail else ""}


CHAT_SCRIPT = r'''
import sys, mlx.core as mx
from mlx_lm import load, stream_generate
model, tok = load(sys.argv[1])
n = int(sys.argv[2])
text = open(sys.argv[3]).read()
ids = tok.encode(text, add_special_tokens=False)[:n]
prompt = tok.apply_chat_template([{"role": "user", "content": tok.decode(ids) + "\n\nSummarize the above in one paragraph."}],
                                 add_generation_prompt=True, tokenize=False)
for _ in stream_generate(model, tok, prompt, max_tokens=128):
    pass
'''


def chat(repo: str, tokens: int):
    return lambda ctx: ([SERVER_PY, "-c", CHAT_SCRIPT, f"{MODELS}/{repo}", str(tokens), ctx["text"]], None, {})


def image(model: str, base: str, steps: int, size: int, edit: bool = False):
    def build(ctx):
        argv = [MFLUX_PY, f"{RUNTIME}/llmtray_mflux_runner.py", "--width", str(size), "--height", str(size),
                "--steps", str(steps), "--model", f"{APP}/mflux_models/{model}", "--base-model", base]
        if base == "flux2-klein-4b":
            images = [ctx["png_b64"]] if edit else []
            return argv, json.dumps({"prompt": "a lighthouse at dusk", "images": images}).encode(), {}
        return argv, b"a red fox in snow, photo", {}
    return build


def music(dit: str, mode: str, seconds: int, planner: bool):
    def build(ctx):
        argv = [AUDIO_PY, f"{RUNTIME}/llmtray_music_runner.py", "--dit", f"{APP}/music_models/{dit}"]
        if planner:
            argv += ["--lm", f"{APP}/music_models/ace-step-1.5-lm-1.7B"]
        req = {"caption": "calm acoustic guitar", "lyrics": "", "duration": seconds, "language": "en", "mode": mode, "seed": 1}
        return argv, json.dumps(req).encode(), {}
    return build


VOICE_SCRIPT = r'''
import subprocess, sys, struct, json, time
# The runner, fed silence for 20 s after it's ready (a listening session).
p = subprocess.Popen([sys.executable, sys.argv[1], "--model", sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
while True:
    head = p.stdout.read(5)
    if len(head) < 5: sys.exit(1)
    kind, size = chr(head[0]), struct.unpack(">I", head[1:])[0]
    payload = p.stdout.read(size)
    if kind == "R":
        rate = json.loads(payload).get("input_sample_rate", 16000)
        break
frame = b"\x00\x00" * (rate // 10)            # 100 ms of 16-bit silence
end = time.time() + 20
while time.time() < end:
    p.stdin.write(b"A" + struct.pack(">I", len(frame)) + frame); p.stdin.flush()
    time.sleep(0.1)
p.stdin.close()
try:
    p.wait(timeout=30)
except subprocess.TimeoutExpired:
    p.kill()
'''


def voice(model: str):
    return lambda ctx: ([AUDIO_PY, "-c", VOICE_SCRIPT, f"{RUNTIME}/llmtray_voice_runner.py", f"{APP}/voice_models/{model}"], None, {})


CASES = {
    "chat-e2b-4k": chat("roman220220/gemma-4-E2B-it-qat-mlx", 4096),
    "chat-e2b-16k": chat("roman220220/gemma-4-E2B-it-qat-mlx", 16384),
    "chat-e4b-4k": chat("roman220220/gemma-4-E4B-it-qat-mlx", 4096),
    "chat-e4b-16k": chat("roman220220/gemma-4-E4B-it-qat-mlx", 16384),
    "chat-nano4b-4k": chat("roman220220/NVIDIA-Nemotron-3-Nano-4B-JANG-GPTQ-ipsupport-code-lora", 4096),
    "chat-26b-4k": chat("roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang", 4096),
    "chat-26b-16k": chat("roman220220/gemma-4-26B-A4B-it-gptq-mlx-jang", 16384),
    "chat-nemotron30b-4k": chat("roman220220/Nemotron-3.5-Lightning-30B-A3B-JANG-GPTQ-ipsupport-code-lora", 4096),
    "image-zimage-1024": image("gptqMixed", "z-image-turbo", 9, 1024),
    "image-klein-1024": image("klein4b", "flux2-klein-4b", 4, 1024),
    "image-klein-edit-1024": image("klein4b", "flux2-klein-4b", 4, 1024, edit=True),
    "music-turbo-30s": music("ace-step-1.5-4bit", "turbo", 30, True),
    "music-turbo-120s": music("ace-step-1.5-4bit", "turbo", 120, True),
    "music-sft-30s": music("ace-step-1.5-sft-gptq-4bit", "sft", 30, False),
    "voice-gptq3": voice("nemotron-voicechat-11b-gptq3"),
    "voice-mixed": voice("nemotron-voicechat-11b-mixed"),
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default="all")
    ap.add_argument("--cool", type=float, default=10)
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--text", help="a long English text for the chat prompts (default: the repo's README files)")
    ap.add_argument("--json")
    args = ap.parse_args()
    names = list(CASES) if args.cases == "all" else args.cases.split(",")
    tmp = tempfile.mkdtemp()
    text = args.text
    if not text:
        text = os.path.join(tmp, "text.txt")
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        parts = [open(os.path.join(root, f)).read() for f in ("README.md",) if os.path.exists(os.path.join(root, f))]
        parts += [open(os.path.join(root, "adr", f)).read() for f in sorted(os.listdir(os.path.join(root, "adr")))]
        open(text, "w").write("\n\n".join(parts))
    png = os.path.join(tmp, "in.png")
    subprocess.run(["sips", "-s", "format", "png", "-z", "1024", "1024",
                    "/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic", "--out", png],
                   capture_output=True)
    png_b64 = base64.b64encode(open(png, "rb").read()).decode() if os.path.exists(png) else ""
    if not png_b64 and any("edit" in n for n in names):
        # Without a reference the edit case would measure generation.
        sys.exit("no reference image for the edit case (sips couldn't make one)")
    ctx = {"text": text, "png_b64": png_b64}
    results = {}
    for i, name in enumerate(names):
        if i:
            time.sleep(args.cool)
        argv, stdin_bytes, env = CASES[name](ctx)
        r = run_case(argv, stdin_bytes, env, args.timeout)
        print(f"{name:24} peak {r['peak_gb']:6.2f} GB  {r['seconds']:4d} s  rc={r['rc']} {r['error'][:80]}", flush=True)
        # A failed or timed-out run's peak isn't what the feature needs.
        if r["rc"] == 0:
            results[name] = r
    if args.json:
        json.dump(results, open(args.json, "w"), indent=1)


if __name__ == "__main__":
    main()
