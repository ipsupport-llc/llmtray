# Voice conversation's ears (adr/0031): the microphone stream in, the user's
# turns out. Silero VAD finds speech, the recognizer (Parakeet or Whisper
# through mlx-audio) re-reads the growing utterance for live captions, and
# Smart Turn decides from the audio whether a pause ends the turn. Runs in
# the audio venv with HF_HUB_OFFLINE=1; every model is a local folder.
#
#   python llmtray_listen_runner.py --vad <dir> --turn <dir> --stt parakeet|whisper --stt-model <dir>
#   python llmtray_listen_runner.py --selftest      # energy VAD, fake recognizer, no packages
#
# Frames as Voice Lab's (VoiceFrame in the app): a type byte, a 4-byte
# big-endian length, the payload.
#   app -> runner:  A  int16 PCM, 16 kHz mono, any length
#                   M  {"language": "ru" | null, "speaking": bool}   (speaking: the
#                      model's voice is playing; turns then end on silence only)
#                   C  drop the utterance in progress
#                   Q  quit
#   runner -> app:  R  ready {"sample_rate": 16000, "stt": ..., "endpoint": "smart-turn" | "silence"}
#                   V  speech started {"at": seconds}
#                   U  partial transcript {"text": ..., "seconds": utterance length}
#                   Z  turn ended {"text": ..., "seconds": ..., "reason": "turn" | "silence" | "length"}
#                   E  error {"message": ..., "fatal": bool}
#                   L  log line
import collections
import json
import os
import struct
import sys
import threading
import time

RATE = 16000
FRAME = 512                     # Silero's window: 32 ms at 16 kHz
FRAME_S = FRAME / float(RATE)
MAX_PAYLOAD = 16 << 20

# Endpointing, in frames of 32 ms (tuned on the user's voice later; adr/0031).
START_FRAMES = 3                # speech this long starts an utterance (~96 ms)
PREFIX_FRAMES = 10              # kept from before the start (~320 ms)
SPEECH_P, SILENCE_P = 0.5, 0.35
# A pause ends the turn when Smart Turn is sure at ~320 ms, or fairly sure at
# ~510 ms; 60 test phrases: a 190 ms wait at p >= 0.5 ended 25 turns inside
# phrases, 500 ms ended 4 (adr/0031). Silence alone ends it at ~1.6 s.
TURN_STEPS = ((10, 0.85), (16, 0.5))
LONG_SILENCE_FRAMES = 50
PLAIN_SILENCE_FRAMES = 22       # ends a turn without Smart Turn (~700 ms)
MAX_UTTERANCE_S = 30.0          # adr/0023's clip limit
PARTIAL_EVERY_S = 0.3

PROTO = None
_write_lock = threading.Lock()


def send(kind, payload=b""):
    if isinstance(payload, dict):
        payload = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    elif isinstance(payload, str):
        payload = payload.encode("utf-8")
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
        raise ValueError("bad frame length %d" % length)
    payload = read_exact(stream, length) if length else b""
    return None if payload is None else (kind, payload)


def samples_from_pcm16(data):
    """Floats in -1..1 (a list without numpy, an array with it)."""
    try:
        import numpy as np
        return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
    except ImportError:
        import array
        a = array.array("h")
        a.frombytes(data[: len(data) - len(data) % 2])
        if sys.byteorder != "little":
            a.byteswap()
        return [x / 32768.0 for x in a]


class Inbox:
    def __init__(self):
        self.cond = threading.Condition()
        self.items = collections.deque()
        self.closed = False

    def put(self, item):
        with self.cond:
            self.items.append(item)
            self.cond.notify()

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify()

    def take(self):
        with self.cond:
            while not self.items and not self.closed:
                self.cond.wait()
            return self.items.popleft() if self.items else None


def reader(stream, inbox):
    try:
        while True:
            frame = read_frame(stream)
            if frame is None or frame[0] == "Q":
                break
            kind, payload = frame
            if kind == "A":
                inbox.put(("audio", payload))
            elif kind == "M":
                try:
                    inbox.put(("mode", json.loads(payload.decode("utf-8"))))
                except ValueError as e:
                    send("E", {"message": "bad M frame: %s" % e, "fatal": False})
            elif kind == "C":
                inbox.put(("cancel", None))
    except Exception as e:
        log("input: %s" % e)
    inbox.close()


# MARK: models

class Models:
    """Silero, Smart Turn and the recognizer."""

    def __init__(self, vad_dir, turn_dir, stt_kind, stt_dir):
        import mlx.core as mx
        import mlx.nn as nn
        import numpy as np
        from mlx_audio.stt.utils import load_model as load_stt
        from mlx_audio.vad.utils import load_model as load_vad
        self.mx, self.np = mx, np
        self.vad = load_vad(vad_dir)
        self.turn = load_vad(turn_dir) if turn_dir else None
        self.stt_kind = stt_kind
        self.stt = load_stt(stt_dir)
        if stt_kind == "parakeet":
            with open(os.path.join(stt_dir, "config.json")) as f:
                quantized = "quantization" in json.load(f)
            if not quantized:
                # 8 bits: 2.5 GB -> 0.96 GB, same words on 60 test phrases (adr/0031).
                nn.quantize(self.stt, group_size=64, bits=8,
                            class_predicate=lambda p, m: isinstance(m, nn.Linear) and m.weight.shape[-1] % 64 == 0)
        self.vad_state = None
        self.language = None

    def speech_probability(self, frame):
        p, self.vad_state = self.vad.feed(frame, self.vad_state, RATE)
        return float(p.reshape(-1)[0].item())

    def reset_vad(self):
        self.vad_state = None

    def turn_probability(self, audio):
        if self.turn is None:
            return None
        return self.turn.predict_endpoint(audio, sample_rate=RATE).probability

    def transcribe(self, audio):
        kwargs = {"language": self.language} if self.stt_kind == "whisper" and self.language else {}
        out = self.stt.generate(self.mx.array(audio), **kwargs)
        return (out.text if hasattr(out, "text") else str(out)).strip()

    def concat(self, chunks):
        return self.np.concatenate(chunks) if chunks else self.np.zeros(0, self.np.float32)

    def warm_up(self):
        silence = self.np.zeros(RATE, self.np.float32)
        self.speech_probability(silence[:FRAME])
        self.reset_vad()
        self.turn_probability(silence)
        self.transcribe(silence)


class FakeModels:
    """--selftest: energy VAD, Smart Turn says "finished" after 0.5 s of
    speech, the recognizer reports the length."""

    def __init__(self):
        self.language = None
        self.stt_kind = "selftest"
        self.turn = True

    def speech_probability(self, frame):
        rms = (sum(x * x for x in frame) / max(1, len(frame))) ** 0.5
        return 0.9 if rms > 0.02 else 0.05

    def reset_vad(self):
        pass

    def turn_probability(self, audio):
        return 0.9 if len(audio) > RATE // 2 else 0.1

    def transcribe(self, audio):
        return "speech %.1f s" % (len(audio) / float(RATE))

    def concat(self, chunks):
        out = []
        for c in chunks:
            out.extend(c)
        return out

    def warm_up(self):
        pass


# MARK: endpointing

class Listener:
    def __init__(self, models):
        self.m = models
        self.pending = []          # samples not yet a whole frame
        self.prefix = collections.deque(maxlen=PREFIX_FRAMES)
        self.speaking_model = False
        self.reset()

    def reset(self):
        self.utterance = []        # frames of the turn in progress
        self.in_speech = False
        self.speech_run = 0
        self.silence = 0
        self.turn_checked_at = -1
        self.last_partial = 0.0
        self.partial_cost = 0.0    # seconds the last partial took to make
        self.started = None

    def utterance_seconds(self):
        return len(self.utterance) * FRAME_S

    def feed(self, data):
        samples = samples_from_pcm16(data)
        if isinstance(samples, list):          # --selftest without numpy
            self.pending = list(self.pending) + samples
        else:
            import numpy as np
            self.pending = np.concatenate([np.asarray(self.pending, dtype=np.float32), samples])
        while len(self.pending) >= FRAME:
            frame, self.pending = self.pending[:FRAME], self.pending[FRAME:]
            self.frame(frame)

    def frame(self, frame):
        p = self.m.speech_probability(frame)
        if not self.started:
            self.prefix.append(frame)
            self.speech_run = self.speech_run + 1 if p >= SPEECH_P else 0
            if self.speech_run >= START_FRAMES:
                self.started = time.time()
                self.utterance = list(self.prefix)
                self.prefix.clear()
                self.in_speech = True
                send("V", {"at": round(self.utterance_seconds(), 3)})
            return
        self.utterance.append(frame)
        if p >= SPEECH_P:
            self.silence = 0
            self.turn_checked_at = -1
        elif p < SILENCE_P:
            self.silence += 1
        seconds = self.utterance_seconds()
        # Each partial re-reads the whole utterance (0.27 s for 12 s of
        # speech): the next one waits twice that, so the recognizer takes at
        # most half the time and the runner never falls behind the mic.
        if seconds - self.last_partial >= max(PARTIAL_EVERY_S, 2 * self.partial_cost) and self.silence == 0:
            self.last_partial = seconds
            t = time.time()
            text = self.m.transcribe(self.m.concat(self.utterance))
            self.partial_cost = time.time() - t
            if text:
                send("U", {"text": text, "seconds": round(seconds, 2)})
        if seconds >= MAX_UTTERANCE_S:
            return self.end("length")
        use_turn = self.m.turn is not None and not self.speaking_model
        if use_turn:
            for step, (frames, need) in enumerate(TURN_STEPS):
                if self.silence >= frames and self.turn_checked_at < step:
                    self.turn_checked_at = step
                    audio = self.m.concat(self.utterance[-int(8 / FRAME_S):])
                    p_turn = self.m.turn_probability(audio)
                    if p_turn is not None and p_turn >= need:
                        return self.end("turn")
            if self.silence >= LONG_SILENCE_FRAMES:
                return self.end("silence")
        elif self.silence >= PLAIN_SILENCE_FRAMES:
            return self.end("silence")

    def end(self, reason):
        # The trailing silence isn't part of what was said.
        speech = self.utterance[: max(1, len(self.utterance) - max(0, self.silence - 3))]
        text = self.m.transcribe(self.m.concat(speech))
        send("Z", {"text": text, "seconds": round(len(speech) * FRAME_S, 2), "reason": reason})
        self.reset()
        self.m.reset_vad()

    def cancel(self):
        self.reset()
        self.m.reset_vad()


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def main():
    global PROTO
    PROTO = sys.stdout.buffer
    sys.stdout = sys.stderr   # mlx-audio prints; stdout carries frames only
    if "--selftest" in sys.argv:
        models = FakeModels()
    else:
        try:
            models = Models(arg("--vad"), arg("--turn"), arg("--stt", "parakeet"), arg("--stt-model"))
            models.warm_up()
        except Exception as e:
            send("E", {"message": "The speech recognizer didn't load: %s" % e, "fatal": True})
            return 1
    send("R", {"sample_rate": RATE, "stt": models.stt_kind,
               "endpoint": "smart-turn" if models.turn else "silence"})
    inbox = Inbox()
    threading.Thread(target=reader, args=(sys.stdin.buffer, inbox), daemon=True).start()
    listener = Listener(models)
    while True:
        item = inbox.take()
        if item is None:
            return 0
        kind, value = item
        try:
            if kind == "audio":
                listener.feed(value)
            elif kind == "mode":
                models.language = value.get("language") or None
                listener.speaking_model = bool(value.get("speaking"))
            elif kind == "cancel":
                listener.cancel()
        except Exception as e:
            send("E", {"message": str(e), "fatal": False})
            listener.cancel()


if __name__ == "__main__":
    sys.exit(main())
