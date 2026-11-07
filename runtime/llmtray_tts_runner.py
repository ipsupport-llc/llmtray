# Spoken answers (adr/0016): Chatterbox Multilingual V3 through mlx-audio,
# (--selftest needs no packages: Python 3 only, as the tests run it)
# one sentence at a time, for LLMTray. Runs in the audio venv with
# HF_HUB_OFFLINE=1: every file is a local folder, nothing is fetched.
#
#   python llmtray_tts_runner.py --model <dir> --s3tokenizer <dir> [--stress <dir>]
#   python llmtray_tts_runner.py --selftest      # the protocol, no model
#
# Frames as Voice Lab's (VoiceFrame in the app): a type byte, a 4-byte
# big-endian length, the payload.
#   app -> runner:  P  speak   {"id": n, "text": "...", "lang": "ru"}
#                   V  voice   {"clip": "/path.wav"} or {"clip": null} (built-in)
#                   C  cancel  every queued sentence (the one being made is
#                              finished, then dropped)
#                   Q  quit
#   runner -> app:  R  ready   {"sample_rate": 24000, "model": "..."}
#                   B  begin   {"id": n}           before a sentence's audio
#                   S  speech  int16 PCM, mono, at the ready sample rate
#                   Z  done    {"id": n, "rtf": x} (rtf: compute s per audio s)
#                   E  error   {"id": n or null, "message": "...", "fatal": bool}
#                              (fatal: the runner can't go on; a bad clip isn't)
#                   L  log line
# A sentence's audio comes in one piece (Chatterbox doesn't stream), cut
# into S frames of at most a second.
import collections
import json
import os
import struct
import sys
import threading
import time

MAX_PAYLOAD = 16 << 20
PROTO = None
_write_lock = threading.Lock()

# mlx-audio's chatterbox stresses Russian with russian_text_stresser (AGPL)
# when it's importable. It must never run: the text arrives stressed by
# llmtray_ru_stress (ruaccent, MIT), so the import is blocked outright.
sys.modules["russian_text_stresser"] = None
sys.modules["russian_text_stresser.text_stresser"] = None


def send(kind, payload=b""):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    elif isinstance(payload, dict):
        payload = json.dumps(payload).encode("utf-8")
    frame = kind.encode("ascii") + struct.pack(">I", len(payload)) + payload
    with _write_lock:
        try:
            PROTO.write(frame)
            PROTO.flush()
        except BrokenPipeError:
            os._exit(0)


def log(text):
    send("L", text)


def read_exact(stream, n):
    chunks = []
    while n > 0:
        chunk = stream.read(n)
        if not chunk:
            return None
        chunks.append(chunk)
        n -= len(chunk)
    return b"".join(chunks)


def read_frame(stream):
    header = read_exact(stream, 5)
    if header is None:
        return None
    kind = chr(header[0])
    (length,) = struct.unpack(">I", header[1:])
    if length > MAX_PAYLOAD:
        raise ValueError("bad frame length %d (type %r)" % (length, kind))
    payload = read_exact(stream, length) if length else b""
    if payload is None:
        return None
    return kind, payload


class Inbox:
    """Sentences to speak, in order; a cancel empties it and bumps the
    generation, so a sentence being made when it came is dropped."""

    def __init__(self):
        self.cond = threading.Condition()
        self.queue = collections.deque()
        self.voice = None          # ("clip", path or None), applied before the next sentence
        self.generation = 0
        self.closed = False

    def put(self, item):
        with self.cond:
            self.queue.append((self.generation, item))
            self.cond.notify()

    def set_voice(self, clip):
        with self.cond:
            self.voice = ("clip", clip)
            self.cond.notify()

    def cancel(self):
        with self.cond:
            self.queue.clear()
            self.generation += 1

    def close(self):
        """Q or EOF: quit now, nothing queued is made."""
        with self.cond:
            self.closed = True
            self.queue.clear()
            self.voice = None
            self.generation += 1
            self.cond.notify()

    def take(self):
        """("voice", clip) | ("speak", generation, request) | None when closed."""
        with self.cond:
            while not self.queue and self.voice is None and not self.closed:
                self.cond.wait()
            if self.voice is not None:
                v, self.voice = self.voice, None
                return ("voice", v[1])
            if self.queue:
                gen, item = self.queue.popleft()
                return ("speak", gen, item)
            return None

    def current(self, generation):
        with self.cond:
            return generation == self.generation


def reader(stream, inbox):
    try:
        while True:
            frame = read_frame(stream)
            if frame is None:
                break
            kind, payload = frame
            try:
                if kind == "P":
                    inbox.put(json.loads(payload.decode("utf-8")))
                elif kind == "V":
                    inbox.set_voice(json.loads(payload.decode("utf-8")).get("clip"))
                elif kind == "C":
                    inbox.cancel()
                elif kind == "Q":
                    break
            except ValueError as e:   # one bad frame: said, and skipped
                send("E", {"id": None, "message": "bad %s frame: %s" % (kind, e), "fatal": False})
    except Exception as e:   # a broken pipe or a bad frame: stop
        log("input: %s" % e)
    inbox.close()


def pcm16(samples):
    try:
        import numpy as np
    except ImportError:   # --selftest on a bare Python
        import array
        a = array.array("h", (int(max(-1.0, min(1.0, x)) * 32767.0) for x in samples))
        if sys.byteorder != "little":
            a.byteswap()
        return a.tobytes()
    a = np.clip(np.asarray(samples, dtype=np.float32).reshape(-1), -1.0, 1.0)
    return (a * 32767.0).astype("<i2").tobytes()


class Speaker:
    """The model, the current voice's conditionals, and the stresser."""

    EXAGGERATION = 0.5   # Resemble's default (the fork's generate() defaults to 0.1)

    def __init__(self, model_dir, s3tokenizer_dir, stress_dir):
        import huggingface_hub
        # mlx-audio fetches the speech tokenizer from the Hub by name; it's a
        # local folder here.
        real = huggingface_hub.snapshot_download

        def local_snapshot(repo_id=None, *a, **k):
            if repo_id == "mlx-community/S3TokenizerV2":
                return s3tokenizer_dir
            return real(repo_id, *a, **k)
        huggingface_hub.snapshot_download = local_snapshot
        from mlx_audio.tts.utils import load_model
        self.model = load_model(model_dir)
        # T3 at 8 bits: 2-3x faster, same audio (quant-ternary
        # chatterbox-quant). LLMTray's download already is; an fp32
        # conversion is quantized here.
        with open(os.path.join(model_dir, "config.json")) as f:
            quantized = "quantization" in json.load(f)
        if not quantized:
            import mlx.nn as nn
            nn.quantize(self.model.t3.tfmr, group_size=64, bits=8)
        self.sample_rate = int(self.model.sample_rate)
        self.builtin = getattr(self.model, "_conds", None)
        self.conds = self.builtin
        self.stress = None
        if stress_dir:
            try:
                sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
                from llmtray_ru_stress import RuStress
                self.stress = RuStress(stress_dir)
            except Exception as e:
                log("Russian stress unavailable: %s" % e)

    def use_clip(self, clip):
        if not clip:
            self.conds = self.builtin
            return
        from mlx_audio.utils import load_audio
        wav = load_audio(clip, sample_rate=self.sample_rate)
        self.conds = self.model.prepare_conditionals(wav, self.sample_rate, self.EXAGGERATION)

    def speak(self, text, lang):
        if lang == "ru" and self.stress is not None:
            text = self.stress.mark(text)
        if self.conds is None:
            raise RuntimeError("no voice: the built-in voice is missing and no clip is set")
        start = time.time()
        audio = []
        for result in self.model.generate(text, conds=self.conds, lang_code=lang,
                                          exaggeration=self.EXAGGERATION, verbose=False):
            audio.append(result.audio)
        import numpy as np
        wav = np.concatenate([np.asarray(a, dtype=np.float32).reshape(-1) for a in audio]) if audio else np.zeros(0, np.float32)
        seconds = len(wav) / float(self.sample_rate)
        rtf = (time.time() - start) / seconds if seconds > 0 else 0.0
        return wav, rtf


def serve(speaker, inbox):
    rate = speaker.sample_rate
    while True:
        item = inbox.take()
        if item is None:
            return
        if item[0] == "voice":
            try:
                speaker.use_clip(item[1])
            except Exception as e:
                send("E", {"id": None, "message": "The voice clip couldn't be used: %s" % e, "fatal": False})
            continue
        _, generation, request = item
        rid = request.get("id")
        text = str(request.get("text") or "").strip()
        if not text:
            send("Z", {"id": rid, "rtf": 0})
            continue
        try:
            wav, rtf = speaker.speak(text, str(request.get("lang") or "en"))
        except Exception as e:
            send("E", {"id": rid, "message": str(e), "fatal": False})
            continue
        if not inbox.current(generation):
            continue   # cancelled while it was being made
        send("B", {"id": rid})
        data = pcm16(wav)
        step = rate * 2   # a second of int16
        for i in range(0, len(data), step):
            if not inbox.current(generation):
                break   # cancelled while being sent
            send("S", data[i:i + step])
        send("Z", {"id": rid, "rtf": round(rtf, 3)})


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


class FakeSpeaker:
    """--selftest: a tone per sentence, so the protocol is tested without a model."""

    def __init__(self):
        self.sample_rate = 24000
        self.clip = None

    def use_clip(self, clip):
        self.clip = clip

    def speak(self, text, lang):
        import math
        n = int(self.sample_rate * 0.05 * max(1, len(text)))
        return [0.2 * math.sin(2 * math.pi * 440 * i / self.sample_rate) for i in range(n)], 0.1


def main():
    global PROTO
    PROTO = sys.stdout.buffer
    # mlx-audio prints progress: keep stdout for frames only.
    sys.stdout = sys.stderr
    inbox = Inbox()
    if "--selftest" in sys.argv:
        speaker = FakeSpeaker()
        name = "selftest"
    else:
        try:
            speaker = Speaker(arg("--model"), arg("--s3tokenizer"), arg("--stress"))
        except Exception as e:
            send("E", {"id": None, "message": "The voice model didn't load: %s" % e, "fatal": True})
            return 1
        name = os.path.basename(os.path.normpath(arg("--model")))
    send("R", {"sample_rate": speaker.sample_rate, "model": name,
               "builtin_voice": getattr(speaker, "builtin", True) is not None,
               "russian_stress": getattr(speaker, "stress", True) is not None})
    threading.Thread(target=reader, args=(sys.stdin.buffer, inbox), daemon=True).start()
    serve(speaker, inbox)
    return 0


if __name__ == "__main__":
    sys.exit(main())
