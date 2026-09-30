# adr/0018: the App Store build's image, music and voice runners, run the
# way the app runs them, inside the sandbox (started by runners_spike.swift,
# a sandboxed app with the App Store build's Python and packages). Models are
# read from the standalone LLMTray's folders (the spike's read-only
# exception). One line per check: PASS/FAIL <name> <detail>.
import json, os, struct, subprocess, sys, tempfile, time

RUNTIME = sys.argv[1]
MODELS = sys.argv[2]
PY = sys.executable
ENV = dict(os.environ, HF_HUB_OFFLINE="1", PYTHONDONTWRITEBYTECODE="1", TOKENIZERS_PARALLELISM="false")


def report(ok, name, detail):
    print(("PASS" if ok else "FAIL"), name, detail, flush=True)


def lines_run(name, args, stdin, want, timeout=900):
    t = time.time()
    try:
        p = subprocess.run([PY, os.path.join(RUNTIME, args[0])] + args[1:], input=stdin, env=ENV,
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return report(False, name, "timeout")
    got = [l for l in p.stdout.split(b"\n") if l.startswith(b"@@LLMTRAY " + want + b" ")]
    detail = f"rc={p.returncode} {len(got[0]) if got else 0}B {time.time() - t:.0f}s"
    if not got:
        detail += " | " + p.stderr.decode(errors="replace").strip().splitlines()[-1:][0] if p.stderr.strip() else ""
    report(bool(got) and p.returncode == 0, name, detail)


mflux = os.path.join(MODELS, "mflux_models")
lines_run("image z-image-turbo 512 9 steps",
          ["llmtray_mflux_runner.py", "--width", "512", "--height", "512", "--steps", "9",
           "--model", os.path.join(mflux, "gptqMixed"), "--base-model", "z-image-turbo"],
          b"a red fox in snow, photo", b"IMAGE")
lines_run("image klein generate 512 4 steps",
          ["llmtray_mflux_runner.py", "--width", "512", "--height", "512", "--steps", "4",
           "--model", os.path.join(mflux, "klein4b"), "--base-model", "flux2-klein-4b"],
          json.dumps({"prompt": "a lighthouse at dusk", "images": []}).encode(), b"IMAGE")

music = os.path.join(MODELS, "music_models")
lines_run("music turbo 10 s",
          ["llmtray_music_runner.py", "--dit", os.path.join(music, "ace-step-1.5-4bit"),
           "--lm", os.path.join(music, "ace-step-1.5-lm-1.7B")],
          json.dumps({"caption": "calm acoustic guitar", "lyrics": "", "duration": 10,
                      "language": "en", "mode": "turbo", "seed": 1}).encode(), b"AUDIO")

# Voice: load, warm up, "R" (ready, with the measured rtf), then stdin EOF.
voice = os.path.join(MODELS, "voice_models", "nemotron-voicechat-11b-gptq3")
t = time.time()
# stderr to a file: a pipe nobody reads fills up and hangs the runner.
errlog = tempfile.TemporaryFile()
p = subprocess.Popen([PY, os.path.join(RUNTIME, "llmtray_voice_runner.py"), "--model", voice],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errlog, env=ENV)
ready, error = None, None
while True:
    head = p.stdout.read(5)
    if len(head) < 5:
        break
    kind, size = chr(head[0]), struct.unpack(">I", head[1:])[0]
    payload = p.stdout.read(size)
    if kind == "R":
        ready = json.loads(payload)
        break
    if kind == "E":
        error = payload.decode(errors="replace")
        break
p.stdin.close()
try:
    p.wait(timeout=60)
except subprocess.TimeoutExpired:
    p.kill()
errlog.seek(0)
err = [error] if error else errlog.read().decode(errors="replace").strip().splitlines()
report(ready is not None, "voice gptq3 load + warmup",
       f"rtf={ready.get('rtf') if ready else None} {time.time() - t:.0f}s" + ("" if ready else " | " + (err[-1] if err else "")))
