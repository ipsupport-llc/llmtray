# Voice Lab (adr/0016): speech-to-speech with NVIDIA NemotronLabs VoiceChat
# through mlx-audio's duplex session, for LLMTray. Run with the audio venv's
# python (music_venv: our mlx-audio fork + its sts extras) and
# HF_HUB_OFFLINE=1: the model is a local folder, nothing is fetched.
#
#   python llmtray_voice_runner.py --model <dir> [--system-prompt <text>] [--seed N]
#                                  [--warmup-frames N] [--voiced-rms X] [--reply-quiet-seconds S]
#   python3 llmtray_voice_runner.py --selftest [--selftest-rtf X]   # no model
#
# Binary frames both ways: 1 type byte, a 4-byte big-endian payload length,
# the payload. Flushed per frame.
#   app -> runner   A  int16 PCM, 16 kHz mono, any length
#                   D  the user's turn ended (walkie-talkie), payload: its number
#                   Q  quit (also: stdin EOF)
#   runner -> app   R  ready, JSON {"sample_rate", "input_sample_rate",
#                      "frame_samples", "model", "rtf"}
#                   T  the model's text channel, a UTF-8 delta
#                   S  its speech, int16 PCM mono at "sample_rate" (22 050 Hz)
#                   Z  the reply to a D is complete, JSON {"reason", "turn", "seconds"}
#                   E  an error (UTF-8); the runner exits after a fatal one
#                   L  a log line (UTF-8): the user's transcript, backlog notices
#
# Two ways to talk, the app's choice:
# - full duplex: A frames stream all the time, S frames come back as the
#   model steps (in real time only if the Mac keeps up: "rtf" <= 1);
# - walkie-talkie, for a Mac that doesn't: A frames while the user talks,
#   then D. The runner then steps the model on silence as fast as it can
#   (not paced to the clock) until its reply ends -- sending the speech from
#   its first voiced frame, holding back the quiet at the end -- and sends Z.
#   New audio (the user talking again) or Q ends the reply early.
# "rtf" is measured at load: warmup frames of silence, the first few (Metal's
# kernel compiles) not counted; their output is dropped.
#
# Nothing is written to disk. It exits at stdin EOF -- which its parent's
# death is -- and when its parent changes (reparented after a crash).
#
# --selftest: ready at once ("rtf" from --selftest-rtf), each A answered with
# an S of the same bytes and an L, each D with a T, two S and a Z, an unknown
# type with an E, Q with a clean exit: for the framing tests, with any
# Python 3 and no packages (so no 3.10+ syntax in this file).
import collections
import json
import os
import struct
import sys
import threading
import time

MAX_PAYLOAD = 16 << 20   # the app's VoiceFrameDecoder.defaultMaxPayload
INPUT_RATE = 16000

PROTO = None             # the protocol's stdout, set up by main()
_write_lock = threading.Lock()


def send(kind, payload=b""):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    frame = kind.encode("ascii") + struct.pack(">I", len(payload)) + payload
    with _write_lock:
        try:
            PROTO.write(frame)
            PROTO.flush()
        except BrokenPipeError:
            os._exit(0)   # the app is gone


def log(text):
    send("L", text)


def read_exact(stream, n):
    """n bytes, or None at EOF (a partial read at EOF is EOF too)."""
    chunks = []
    while n > 0:
        chunk = stream.read(n)
        if not chunk:
            return None
        chunks.append(chunk)
        n -= len(chunk)
    return b"".join(chunks)


def read_frame(stream):
    """(type, payload); None at EOF. Raises ValueError on a bad length."""
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
    """What the stdin reader thread received, in order: ("A", pcm), ("D", turn),
    ("Q", None). The model loop can look at what's next without taking it."""

    def __init__(self):
        self._items = collections.deque()
        self._cv = threading.Condition()

    def put(self, kind, data=None):
        with self._cv:
            self._items.append((kind, data))
            self._cv.notify()

    def get(self):
        with self._cv:
            while not self._items:
                self._cv.wait()
            return self._items.popleft()

    def take_audio(self):
        """The audio queued right behind (behind real time: one push)."""
        out = []
        with self._cv:
            while self._items and self._items[0][0] == "A":
                out.append(self._items.popleft()[1])
        return b"".join(out)

    def next_kind(self):
        with self._cv:
            return self._items[0][0] if self._items else None


class ReplyTracker:
    """A walkie-talkie reply, frame by frame: leading quiet is dropped (the
    model's thinking), speech is sent from the first voiced frame, a quiet
    stretch is held back until the model speaks again -- or, `quiet_end`
    seconds of it, ends the reply (and is never sent). `step` returns
    (audio chunks to send now, None or why it ended)."""

    def __init__(self, frame_seconds=0.08, threshold=0.01, quiet_end=1.2, no_onset=5.0, limit=60.0):
        self.threshold = threshold
        self.quiet_end = max(1, int(round(quiet_end / frame_seconds)))
        self.no_onset = max(1, int(round(no_onset / frame_seconds)))
        self.limit = max(1, int(round(limit / frame_seconds)))
        self.frame_seconds = frame_seconds
        self.started = False
        self.frames = 0
        self.sent_frames = 0
        self._held = []

    @property
    def sent_seconds(self):
        return self.sent_frames * self.frame_seconds

    def step(self, audio, rms, text=""):
        self.frames += 1
        voiced = rms >= self.threshold or bool(text.strip())
        out = []
        if not self.started:
            if voiced:
                self.started = True
                out = [audio]
            elif self.frames >= self.no_onset:
                return [], "no_reply"
        elif voiced:
            out = self._held + [audio]
            self._held = []
        else:
            self._held.append(audio)
            if len(self._held) >= self.quiet_end:
                self._held = []
                return [], "done"
        self.sent_frames += len(out)
        if self.frames >= self.limit:
            return out, "limit"
        return out, None


def arg(name, default=None):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def watch_parent():
    """A parent that died holding our stdin open (it can't, but a grandparent
    could): exit rather than keep ~9 GB loaded. OrphanScan is the backstop."""
    parent = os.getppid()
    while True:
        time.sleep(0.5)
        if os.getppid() != parent:
            os._exit(0)


def start_reader(inbox):
    """stdin on its own thread, so the model's steps never hold up the pipe
    (a full pipe would block the app's writes)."""

    def reader():
        stream = sys.stdin.buffer
        try:
            while True:
                frame = read_frame(stream)
                if frame is None or frame[0] == "Q":
                    break
                kind, payload = frame
                if kind == "A":
                    if payload:
                        inbox.put("A", payload)
                elif kind == "D":
                    inbox.put("D", payload.decode("utf-8", "replace"))
                else:
                    send("E", "unknown frame type %r" % kind)
        except ValueError as e:
            send("E", str(e))
            inbox.put("Q")
            return 2
        inbox.put("Q")
        return 0

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    return thread


def turn_number(text):
    try:
        return int(text)
    except (TypeError, ValueError):
        return None


def selftest():
    rtf = float(arg("--selftest-rtf", "0.5"))
    send("R", json.dumps({"sample_rate": INPUT_RATE, "input_sample_rate": INPUT_RATE,
                          "frame_samples": 1280, "model": "selftest", "rtf": rtf}))
    stream = sys.stdin.buffer
    count = 0
    while True:
        try:
            frame = read_frame(stream)
        except ValueError as e:
            send("E", str(e))
            return 2
        if frame is None:
            return 0
        kind, payload = frame
        if kind == "Q":
            return 0
        if kind == "A":
            count += 1
            send("S", payload)
            log("frame %d: %d samples" % (count, len(payload) // 2))
        elif kind == "D":
            turn = turn_number(payload.decode("utf-8", "replace"))
            send("T", "reply %s" % turn)
            send("S", b"\x01\x00" * 4)
            send("S", b"\x02\x00" * 4)
            send("Z", json.dumps({"reason": "done", "turn": turn, "seconds": 0.0}))
        else:
            send("E", "unknown frame type %r" % kind)


def default_system_prompt():
    """The model's own prompt (mlx-audio's DEFAULT_SYSTEM_PROMPT) without its
    "greet the user": in walkie-talkie the model only runs while it answers,
    so a greeting would stop half-way until the user talks."""
    try:
        from mlx_audio.sts.models.nemotron_voicechat.model import DEFAULT_SYSTEM_PROMPT
    except Exception:  # noqa: BLE001 -- the session's own default then
        return None
    return DEFAULT_SYSTEM_PROMPT.replace("Start the conversation by greeting the user.", "").strip()


def run_model():
    model_dir = arg("--model")
    if not model_dir or not os.path.isdir(model_dir):
        send("E", "no model folder: %s" % model_dir)
        return 1
    seed = int(arg("--seed", "0"))
    warmup_frames = max(0, int(arg("--warmup-frames", "25")))

    import numpy as np
    from mlx_audio.sts import load

    system_prompt = arg("--system-prompt") or default_system_prompt()
    started = time.time()
    try:
        model = load(model_dir)
        session = model.create_duplex_session(system_prompt=system_prompt, seed=seed)
    except Exception as e:  # noqa: BLE001 -- whatever failed, the app says so
        send("E", "loading the voice model failed: %s: %s" % (type(e).__name__, e))
        return 1
    name = os.path.basename(model_dir.rstrip("/"))
    log("loaded %s in %.1f s" % (name, time.time() - started))

    frame_samples = int(session.frame_samples)
    frame_seconds = frame_samples / float(session.input_sample_rate)
    silence = np.zeros(frame_samples, dtype=np.float32)

    # The real-time factor, on silence; the first frames (kernel compiles)
    # aren't counted, the output is dropped.
    rtf = None
    try:
        times = []
        for _ in range(warmup_frames):
            t0 = time.perf_counter()
            session.push_audio(silence, sample_rate=INPUT_RATE)
            times.append(time.perf_counter() - t0)
        measured = times[5:] if len(times) > 8 else times
        if measured:
            rtf = sum(measured) / len(measured) / frame_seconds
            log("warmup: %d frames, %.0f ms per 80 ms frame (rtf %.2f)" % (len(times), 1000 * rtf * frame_seconds, rtf))
    except Exception as e:  # noqa: BLE001
        send("E", "the voice model failed at warmup: %s: %s" % (type(e).__name__, e))
        return 1

    send("R", json.dumps({
        "sample_rate": int(session.output_sample_rate),
        "input_sample_rate": int(session.input_sample_rate),
        "frame_samples": frame_samples,
        "model": name,
        "rtf": rtf,
    }))

    inbox = Inbox()
    start_reader(inbox)

    def push(samples):
        return session.push_audio(samples, sample_rate=INPUT_RATE)

    backlog_warned = 0.0
    while True:
        kind, data = inbox.get()
        if kind == "Q":
            try:
                session.cancel()
            except Exception:  # noqa: BLE001 -- quitting anyway
                pass
            return 0
        try:
            if kind == "A":
                pcm = data + inbox.take_audio()
                seconds = len(pcm) / 2.0 / INPUT_RATE
                if seconds > 1.0 and time.time() - backlog_warned > 10:
                    backlog_warned = time.time()
                    log("behind real time by %.1f s of audio" % seconds)
                samples = np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
                for event in push(samples):
                    emit(event, np)
            elif kind == "D":
                reply(turn_number(data), inbox, push, silence, frame_seconds, np)
        except Exception as e:  # noqa: BLE001
            send("E", "the voice model failed: %s: %s" % (type(e).__name__, e))
            return 1


def reply(turn, inbox, push, silence, frame_seconds, np):
    """Walkie-talkie: the model answers on silence, as fast as it steps."""
    tracker = ReplyTracker(frame_seconds=frame_seconds,
                           threshold=float(arg("--voiced-rms", "0.01")),
                           quiet_end=float(arg("--reply-quiet-seconds", "1.2")))
    started = time.time()
    while True:
        if inbox.next_kind() in ("A", "Q"):
            reason = "interrupted"
            break
        audio, rms, text = None, 0.0, ""
        for event in push(silence):
            if event.kind == "audio" and event.samples is not None:
                samples = np.clip(np.asarray(event.samples, dtype=np.float32), -1.0, 1.0)
                rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
                audio = (samples * 32767.0).round().astype("<i2").tobytes()
            else:
                if event.kind == "assistant_text_delta" and event.delta:
                    text += event.delta
                emit(event, np)
        if audio is None:
            continue
        out, reason = tracker.step(audio, rms, text)
        for chunk in out:
            send("S", chunk)
        if reason:
            break
    elapsed = time.time() - started
    log("reply %s: %s, %.1f s of speech in %.1f s" % (turn, reason, tracker.sent_seconds, elapsed))
    send("Z", json.dumps({"reason": reason, "turn": turn, "seconds": round(tracker.sent_seconds, 2)}))


def emit(event, np):
    kind = event.kind
    if kind == "audio" and event.samples is not None:
        samples = np.clip(np.asarray(event.samples, dtype=np.float32), -1.0, 1.0)
        send("S", (samples * 32767.0).round().astype("<i2").tobytes())
    elif kind == "assistant_text_delta" and event.delta:
        send("T", event.delta)
    elif kind == "user_transcript_delta" and event.delta:
        log("user: " + event.delta)
    elif kind == "function_delta" and event.delta:
        log("function: " + event.delta)


def main():
    global PROTO
    # The protocol keeps the real stdout; fd 1 then goes to stderr, so
    # whatever the libraries print lands in the log instead of in the frames.
    PROTO = os.fdopen(os.dup(1), "wb", buffering=0)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    threading.Thread(target=watch_parent, daemon=True).start()
    if "--selftest" in sys.argv:
        return selftest()
    return run_model()


if __name__ == "__main__":
    code = main()
    try:
        PROTO.flush()
    except Exception:  # noqa: BLE001
        pass
    # os._exit: no interpreter teardown of a 9 GB model (seconds) at quit.
    os._exit(code or 0)
