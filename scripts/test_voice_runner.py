#!/usr/bin/env python3
"""The Voice Lab runner's framing (runtime/llmtray_voice_runner.py --selftest)
and its walkie-talkie reply tracking: no model, any Python 3, no packages.
Frames split across writes and several in one write, an unknown type, D/Z,
Q, EOF, a bad length.

    python3 scripts/test_voice_runner.py
"""
import importlib.util
import json
import struct
import subprocess
import sys
from pathlib import Path

RUNNER = Path(__file__).resolve().parent.parent / "runtime" / "llmtray_voice_runner.py"


def frame(kind, payload=b""):
    return kind.encode() + struct.pack(">I", len(payload)) + payload


def parse(data):
    frames = []
    while data:
        assert len(data) >= 5, "truncated header: %r" % data
        kind = chr(data[0])
        (n,) = struct.unpack(">I", data[1:5])
        assert len(data) >= 5 + n, "truncated payload"
        frames.append((kind, data[5 : 5 + n]))
        data = data[5 + n :]
    return frames


def run(stdin_chunks):
    p = subprocess.Popen([sys.executable, str(RUNNER), "--selftest"],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        for chunk in stdin_chunks:
            p.stdin.write(chunk)
            p.stdin.flush()
        p.stdin.close()
    except BrokenPipeError:
        pass   # it quit (Q, a bad length) before the rest
    out = p.stdout.read()
    code = p.wait(timeout=10)
    return code, parse(out)


def load_runner():
    spec = importlib.util.spec_from_file_location("llmtray_voice_runner", str(RUNNER))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)   # no side effects before main()
    return module


def test_reply_tracker(runner):
    quiet, loud = 0.001, 0.2
    t = runner.ReplyTracker(frame_seconds=0.08, threshold=0.01, quiet_end=0.24, zero_end=0.4, no_onset=0.4, limit=10)
    # Leading quiet is dropped.
    assert t.step(b"q0", quiet) == ([], None)
    assert t.step(b"q1", 0.0) == ([], None)
    # Speech from the first voiced frame (text counts as voiced).
    assert t.step(b"s0", loud) == ([b"s0"], None)
    assert t.step(b"s1", quiet, "Hel") == ([b"s1"], None)
    # A pause is held, then sent when the model speaks again.
    assert t.step(b"p0", quiet) == ([], None)
    assert t.step(b"p1", quiet, " ") == ([], None)   # whitespace isn't speech
    assert t.step(b"s2", loud) == ([b"p0", b"p1", b"s2"], None)
    # 3 quiet frames (0.24 s) end it; they're never sent.
    assert t.step(b"e0", quiet) == ([], None)
    assert t.step(b"e1", quiet) == ([], None)
    assert t.step(b"e2", quiet) == ([], "done")
    assert abs(t.sent_seconds - 5 * 0.08) < 1e-9, t.sent_seconds

    # The codec's exact silence ends it after 5 frames (0.4 s), text quiet;
    # a text token in between starts the count over.
    t = runner.ReplyTracker(frame_seconds=0.08, threshold=0.01, quiet_end=5, zero_end=0.4, no_onset=1, limit=10)
    assert t.step(b"s", loud) == ([b"s"], None)
    assert [t.step(b"z", 0.0)[1] for _ in range(3)] == [None] * 3
    assert t.step(b"t", 0.0, "Hi")[0] == [b"z", b"z", b"z", b"t"]   # text: voiced
    assert [t.step(b"z", 0.0)[1] for _ in range(5)] == [None] * 4 + ["done"]
    # Quiet but not exactly silent doesn't count as the codec's silence.
    t = runner.ReplyTracker(frame_seconds=0.08, threshold=0.01, quiet_end=5, zero_end=0.4, no_onset=1, limit=10)
    t.step(b"s", loud)
    assert [t.step(b"q", 0.0005)[1] for _ in range(8)] == [None] * 8

    # No reply within no_onset (5 frames).
    t = runner.ReplyTracker(frame_seconds=0.08, threshold=0.01, quiet_end=1, no_onset=0.4, limit=10)
    results = [t.step(b"q", quiet) for _ in range(5)]
    assert results[-1] == ([], "no_reply") and all(r == ([], None) for r in results[:-1]), results

    # The cap.
    t = runner.ReplyTracker(frame_seconds=0.08, threshold=0.01, quiet_end=1, no_onset=1, limit=0.24)
    assert [t.step(b"s", loud) for _ in range(3)][-1] == ([b"s"], "limit")


def test_inbox(runner):
    # Order kept; audio behind audio in one bounded take.
    inbox = runner.Inbox(rate=10)   # 10 Hz: 20 bytes a second
    inbox.put_audio(b"12")
    inbox.put_audio(b"34")
    inbox.put("D", "1")
    inbox.put_audio(b"56")
    assert inbox.get() == ("A", b"12")
    assert inbox.take_audio() == b"34"
    assert inbox.next_kind() == "D"
    assert inbox.get() == ("D", "1")
    assert inbox.next_kind() == "A"

    # Full duplex: at most 2 s wait, the oldest goes; D stays.
    inbox = runner.Inbox(duplex_backlog=2.0, rate=10)   # 40 bytes
    for i in range(3):
        inbox.put_audio(bytes([i]) * 20)   # 1 s each
    inbox.put("C")
    inbox.put_audio(b"\x09" * 20)
    assert abs(inbox.dropped - 2.0) < 1e-9, inbox.dropped
    assert abs(inbox.queued_seconds() - 2.0) < 1e-9
    assert [k for k, _ in list(inbox._items)] == ["A", "C", "A"], list(inbox._items)
    assert inbox.get() == ("A", b"\x02" * 20)
    # take_audio stops at its bound.
    inbox = runner.Inbox(rate=10)
    for _ in range(5):
        inbox.put_audio(b"x" * 8)
    assert len(inbox.take_audio(max_bytes=16)) == 16
    assert len(inbox.take_audio(max_bytes=100)) == 24

    # Walkie-talkie: a turn takes at most turn_limit s; D starts the next.
    inbox = runner.Inbox(turn_limit=1.0, rate=10)   # 20 bytes a turn
    inbox.put("M", "walkie")
    inbox.put_audio(b"a" * 16)
    inbox.put_audio(b"b" * 16)   # 4 bytes fit
    inbox.put_audio(b"c" * 4)    # none
    assert abs(inbox.dropped - 0.8) < 1e-9, inbox.dropped   # 12 + 4 bytes
    inbox.put("D", "1")
    inbox.put_audio(b"d" * 20)
    assert [(k, d) for k, d in list(inbox._items)] == [("M", "walkie"), ("A", b"a" * 16), ("A", b"bbbb"), ("D", "1"), ("A", b"d" * 20)]

    # One log line per turn.
    lines = []
    runner.log = lines.append
    turns = runner.TurnLog()
    for d in ["Wh", "at is", " it"]:
        turns.add("you", d)
    turns.add("model", " It's  ")
    turns.add("model", "Paris.")
    turns.flush()
    turns.flush()
    assert lines == ["you: What is it", "model: It's Paris."], lines


def main():
    runner = load_runner()
    test_reply_tracker(runner)
    test_inbox(runner)

    pcm = struct.pack("<4h", 0, 1000, -1000, 32767)
    a1, a2 = frame("A", pcm), frame("A", b"\x01\x00")

    # A split in the middle of its header and its payload, then two at once, then Q.
    code, frames = run([a1[:3], a1[3:7], a1[7:], a2 + frame("X", b"?") + frame("Q"), frame("A", pcm)])
    assert code == 0, code
    kinds = [k for k, _ in frames]
    assert kinds[0] == "R", kinds
    ready = json.loads(frames[0][1])
    assert ready["sample_rate"] == 16000 and ready["input_sample_rate"] == 16000, ready
    speech = [p for k, p in frames if k == "S"]
    assert speech == [pcm, b"\x01\x00"], speech   # nothing after Q
    assert [k for k in kinds if k == "L"] == ["L", "L"], kinds
    assert any(k == "E" and b"'X'" in p for k, p in frames), frames

    # D: a reply (T, S..., Z with the turn), in order, before what follows.
    code, frames = run([frame("M", b"walkie") + frame("C") + frame("D", b"7") + frame("A", pcm) + frame("Q")])
    assert code == 0, code
    kinds = [k for k, _ in frames]
    assert kinds == ["R", "L", "T", "S", "S", "Z", "S", "L"], kinds
    done = json.loads(frames[5][1])
    assert done["reason"] == "done" and done["turn"] == 7, done
    assert json.loads(frames[0][1])["rtf"] == 0.5

    # EOF alone ends it cleanly; so does EOF inside a frame.
    code, frames = run([])
    assert code == 0 and [k for k, _ in frames] == ["R"], (code, frames)
    code, frames = run([a1[:6]])
    assert code == 0 and [k for k, _ in frames] == ["R"], (code, frames)

    # A length past the limit: an error frame, exit 2.
    code, frames = run([b"A" + struct.pack(">I", (16 << 20) + 1)])
    assert code == 2, code
    assert frames[-1][0] == "E" and b"bad frame length" in frames[-1][1], frames

    print("voice runner framing: ok")


if __name__ == "__main__":
    main()
