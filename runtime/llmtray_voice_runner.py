# Voice Lab (adr/0016): speech-to-speech with NVIDIA NemotronLabs VoiceChat
# through mlx-audio's duplex session, for LLMTray. Run with the audio venv's
# python (music_venv: our mlx-audio fork + its sts extras) and
# HF_HUB_OFFLINE=1: the model is a local folder, nothing is fetched.
#
#   python llmtray_voice_runner.py --model <dir> [--system-prompt <text>] [--seed N]
#                                  [--warmup-frames N] [--max-session-seconds S]
#                                  [--voiced-rms X] [--reply-quiet-seconds S] [--reply-zero-seconds S]
#                                  [--tts-idle-frames N] [--tts-idle-rms X]
#   python3 llmtray_voice_runner.py --selftest [--selftest-rtf X]   # no model
#
# Binary frames both ways: 1 type byte, a 4-byte big-endian payload length,
# the payload. Flushed per frame.
#   app -> runner   A  int16 PCM, 16 kHz mono, any length
#                   M  the mode, "duplex" or "walkie" (walkie-talkie)
#                   D  the user's turn ended (walkie-talkie), payload: its number
#                   C  cancel the reply in progress
#                   Q  quit (also: stdin EOF)
#   runner -> app   R  ready, JSON {"sample_rate", "input_sample_rate",
#                      "frame_samples", "model", "rtf"}
#                   T  the model's text channel, a UTF-8 delta
#                   U  the user's transcript, a UTF-8 delta
#                   S  its speech, int16 PCM mono at "sample_rate" (22 050 Hz)
#                   Z  the reply to a D is complete, JSON {"reason", "turn", "seconds"};
#                      reason: done, no_reply, limit, interrupted, reset
#                   N  a note for the user (UTF-8): the conversation started over
#                   E  an error (UTF-8); the runner exits after a fatal one
#                   L  a log line (UTF-8): one per turn, backlog notices
#
# Two ways to talk, the app's choice (M):
# - full duplex: A frames stream all the time, S frames come back as the
#   model steps (in real time only if the Mac keeps up: "rtf" <= 1); at most
#   2 s of audio waits, the oldest is dropped past that;
# - walkie-talkie, for a Mac that doesn't: A frames while the user talks
#   (at most 30 s a turn; the model's audio meanwhile is dropped), then D.
#   The runner then steps the model on silence as fast as it can (not paced
#   to the clock) until its reply ends -- sending the speech from its first
#   voiced frame, holding back pauses, ending at 0.4 s of the codec's exact
#   silence (or 1.2 s of quiet) -- and sends Z. New audio, C or Q end it early.
# "rtf" is measured at load: warmup frames of silence, the first few (Metal's
# kernel compiles) not counted; their output is dropped. It is the cost of a
# frame the model speaks on (the warm-up session never pauses its TTS):
# speech plays as it's made, so that decides whether duplex keeps up.
# --tts-idle-frames N (default 5, 0: off): after N quiet frames (no token,
# silent speech) the session pauses its TTS and codec until the next token
# -- listening frames then cost only perception and the language model. The context is
# bounded (--max-session-seconds, 300): at the limit the session starts over.
#
# Nothing is written to disk. It exits at stdin EOF -- which its parent's
# death is -- and when its parent changes (reparented after a crash).
#
# --selftest: ready at once ("rtf" from --selftest-rtf), each A answered with
# an S of the same bytes and an L, each D with a T, two S and a Z, M with an
# L, C with nothing, an unknown type with an E, Q with a clean exit: for the framing tests, with any
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
    ("C", None), ("M", mode), ("Q", None). The model loop can look at what's
    next without taking it.

    Bounded, since the model may step slower than real time: in full duplex
    at most `duplex_backlog` seconds of audio wait (the oldest is dropped --
    stale speech is worth less than current); in walkie-talkie a turn takes
    at most `turn_limit` seconds of the user's audio (the rest is dropped).
    `dropped` counts the seconds dropped since the caller last reset it."""

    def __init__(self, duplex_backlog=2.0, turn_limit=30.0, rate=INPUT_RATE):
        self._items = collections.deque()
        self._cv = threading.Condition()
        self.walkie = False
        self._max_backlog = int(duplex_backlog * rate) * 2
        self._max_turn = int(turn_limit * rate) * 2
        self._queued = 0       # audio bytes waiting
        self._turn = 0         # audio bytes this walkie-talkie turn
        self.dropped = 0.0
        self._rate = rate

    def put(self, kind, data=None):
        with self._cv:
            if kind == "M":
                self.walkie = data == "walkie"
            if kind in ("D", "M"):
                self._turn = 0
            self._items.append((kind, data))
            self._cv.notify()

    def put_audio(self, pcm):
        with self._cv:
            if self.walkie:
                room = self._max_turn - self._turn
                if room <= 0:
                    self.dropped += len(pcm) / 2.0 / self._rate
                    return
                if len(pcm) > room:
                    self.dropped += (len(pcm) - room) / 2.0 / self._rate
                    pcm = pcm[: room - room % 2]
                self._turn += len(pcm)
            else:
                # The oldest audio goes first; D/C/M/Q stay where they are.
                while self._queued + len(pcm) > self._max_backlog and self._queued > 0:
                    for index, (kind, data) in enumerate(self._items):
                        if kind == "A":
                            del self._items[index]
                            self._queued -= len(data)
                            self.dropped += len(data) / 2.0 / self._rate
                            break
                    else:
                        break
            self._queued += len(pcm)
            self._items.append(("A", pcm))
            self._cv.notify()

    def get(self):
        with self._cv:
            while not self._items:
                self._cv.wait()
            kind, data = self._items.popleft()
            if kind == "A":
                self._queued -= len(data)
            return kind, data

    def take_audio(self, max_bytes=INPUT_RATE * 2):
        """More audio queued right behind, up to `max_bytes` (one push, bounded)."""
        out, size = [], 0
        with self._cv:
            while self._items and self._items[0][0] == "A" and size < max_bytes:
                data = self._items.popleft()[1]
                self._queued -= len(data)
                out.append(data)
                size += len(data)
        return b"".join(out)

    def queued_seconds(self):
        with self._cv:
            return self._queued / 2.0 / self._rate

    def next_kind(self):
        with self._cv:
            return self._items[0][0] if self._items else None


class ReplyTracker:
    """A walkie-talkie reply, frame by frame: leading quiet is dropped (the
    model's thinking), speech is sent from the first voiced frame, a quiet
    stretch is held back until the model speaks again. The reply ends at
    `zero_end` seconds of the codec's exact silence (RMS 0) with the text
    channel quiet, or `quiet_end` seconds of merely quiet frames; what ended
    it is never sent. `step` returns (audio chunks to send now, None or why
    it ended)."""

    def __init__(self, frame_seconds=0.08, threshold=0.01, quiet_end=1.2, zero_end=0.4, no_onset=5.0, limit=60.0):
        self.threshold = threshold
        self.quiet_end = max(1, int(round(quiet_end / frame_seconds)))
        self.zero_end = max(1, int(round(zero_end / frame_seconds)))
        self.no_onset = max(1, int(round(no_onset / frame_seconds)))
        self.limit = max(1, int(round(limit / frame_seconds)))
        self.frame_seconds = frame_seconds
        self.started = False
        self.frames = 0
        self.sent_frames = 0
        self._held = []
        self._zeros = 0

    @property
    def sent_seconds(self):
        return self.sent_frames * self.frame_seconds

    def step(self, audio, rms, text=""):
        self.frames += 1
        has_text = bool(text.strip())
        voiced = rms >= self.threshold or has_text
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
            self._zeros = 0
        else:
            self._held.append(audio)
            self._zeros = self._zeros + 1 if rms == 0.0 and not has_text else 0
            if len(self._held) >= self.quiet_end or self._zeros >= self.zero_end:
                self._held = []
                return [], "done"
        self.sent_frames += len(out)
        if self.frames >= self.limit:
            return out, "limit"
        return out, None


class TurnLog:
    """The transcript for the log: one line per turn (who spoke, all of it),
    not one per token."""

    def __init__(self):
        self.who = None
        self.text = ""

    def add(self, who, delta):
        if who != self.who:
            self.flush()
            self.who = who
        self.text += delta

    def flush(self):
        if self.who and self.text.strip():
            log("%s: %s" % (self.who, " ".join(self.text.split())))
        self.who, self.text = None, ""


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
                        inbox.put_audio(payload)
                elif kind in ("D", "M"):
                    inbox.put(kind, payload.decode("utf-8", "replace"))
                elif kind == "C":
                    inbox.put("C")
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
        elif kind == "M":
            log("mode %s" % payload.decode("utf-8", "replace"))
        elif kind == "C":
            pass   # no reply in progress here
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
    # Bounds the context (the language model's cache grows every 80 ms);
    # at the limit the conversation starts over, with a note to the app.
    max_seconds = float(arg("--max-session-seconds", "300"))
    idle_frames = max(0, int(arg("--tts-idle-frames", "5")))
    idle_rms = float(arg("--tts-idle-rms", "0.001"))
    started = time.time()
    try:
        model = load(model_dir)

        def new_session(idle=idle_frames):
            extra = {"tts_idle_frames": idle, "tts_idle_rms": idle_rms} if idle else {}
            try:
                return model.create_duplex_session(system_prompt=system_prompt, seed=seed,
                                                   max_streaming_seconds=max_seconds, **extra)
            except TypeError as e:
                # An mlx-audio without the TTS pause: run every frame.
                if not extra or "tts_idle" not in str(e):
                    raise
                log("this mlx-audio has no TTS pause (%s); running without it" % e)
                return model.create_duplex_session(system_prompt=system_prompt, seed=seed,
                                                   max_streaming_seconds=max_seconds)

        session = new_session(0) if idle_frames and warmup_frames else new_session()
    except Exception as e:  # noqa: BLE001 -- whatever failed, the app says so
        send("E", "loading the voice model failed: %s: %s" % (type(e).__name__, e))
        return 1
    try:
        from mlx_audio.sts.models.nemotron_voicechat.streaming import VoiceChatContextLimitError
    except Exception:  # noqa: BLE001
        VoiceChatContextLimitError = None
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
        if idle_frames and warmup_frames:
            session = new_session()   # the warm-up one never paused; this one may
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
    turns = TurnLog()
    state = {"session": session, "reset": False}

    def push(samples):
        """One push; at the context limit a fresh session (state["reset"])."""
        try:
            return state["session"].push_audio(samples, sample_rate=INPUT_RATE)
        except Exception as e:  # noqa: BLE001
            if VoiceChatContextLimitError is None or not isinstance(e, VoiceChatContextLimitError):
                raise
            turns.flush()
            log("context limit (%d s): starting a new conversation" % max_seconds)
            send("N", "The conversation reached %d minutes and starts over: the model has forgotten it." % (max_seconds // 60))
            state["session"] = new_session()
            state["reset"] = True
            return []

    walkie = False
    last_drop_log = 0.0
    while True:
        kind, data = inbox.get()
        if kind == "Q":
            turns.flush()
            try:
                state["session"].cancel()
            except Exception:  # noqa: BLE001 -- quitting anyway
                pass
            return 0
        try:
            if kind == "M":
                walkie = data == "walkie"
            elif kind == "A":
                pcm = data + inbox.take_audio()
                if inbox.dropped and time.time() - last_drop_log > 5:
                    last_drop_log = time.time()
                    log("behind real time: dropped %.1f s of audio" % inbox.dropped)
                    inbox.dropped = 0.0
                samples = np.frombuffer(pcm[: len(pcm) // 2 * 2], dtype="<i2").astype(np.float32) / 32768.0
                for event in push(samples):
                    # Walkie-talkie: what the model says while the user talks
                    # isn't the reply (it would play as junk before it).
                    if walkie and event.kind == "audio":
                        continue
                    emit(event, np, turns)
            elif kind == "D":
                turns.flush()
                reply(turn_number(data), inbox, push, state, silence, frame_seconds, np, turns)
            # "C" outside a reply: nothing to cancel.
        except Exception as e:  # noqa: BLE001
            send("E", "the voice model failed: %s: %s" % (type(e).__name__, e))
            return 1


def reply(turn, inbox, push, state, silence, frame_seconds, np, turns):
    """Walkie-talkie: the model answers on silence, as fast as it steps."""
    tracker = ReplyTracker(frame_seconds=frame_seconds,
                           threshold=float(arg("--voiced-rms", "0.01")),
                           quiet_end=float(arg("--reply-quiet-seconds", "1.2")),
                           zero_end=float(arg("--reply-zero-seconds", "0.4")))
    started = time.time()
    state["reset"] = False
    while True:
        if inbox.next_kind() in ("A", "Q", "C"):
            if inbox.next_kind() == "C":
                inbox.get()
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
                emit(event, np, turns)
        if state["reset"]:
            reason = "reset"
            break
        if audio is None:
            continue
        out, reason = tracker.step(audio, rms, text)
        for chunk in out:
            send("S", chunk)
        if reason:
            break
    turns.flush()
    log("reply %s: %s, %.1f s of speech in %.1f s" % (turn, reason, tracker.sent_seconds, time.time() - started))
    send("Z", json.dumps({"reason": reason, "turn": turn, "seconds": round(tracker.sent_seconds, 2)}))


def emit(event, np, turns):
    kind = event.kind
    if kind == "audio" and event.samples is not None:
        samples = np.clip(np.asarray(event.samples, dtype=np.float32), -1.0, 1.0)
        send("S", (samples * 32767.0).round().astype("<i2").tobytes())
    elif kind == "assistant_text_delta" and event.delta:
        send("T", event.delta)
        turns.add("model", event.delta)
    elif kind == "user_transcript_delta" and event.delta:
        send("U", event.delta)
        turns.add("you", event.delta)
    elif kind == "function_delta" and event.delta:
        turns.add("function", event.delta)


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
