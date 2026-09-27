"""Client-side test of runner.py: cold start, concurrent requests, limits, timeout,
cancel, kill -9 + restart, graceful EOF, orphan exit.

usage: python client_test.py <registry.json> <entry> <model_dir> <data_dir> <ref.npz> [--json out]
"""
import argparse
import base64
import itertools
import json
import os
import random
import signal
import subprocess
import sys
import threading
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ap = argparse.ArgumentParser()
ap.add_argument("registry"); ap.add_argument("entry"); ap.add_argument("model_dir"); ap.add_argument("data"); ap.add_argument("ref")
ap.add_argument("--json"); ap.add_argument("--verify", action="store_true")
a = ap.parse_args()
corpus = json.load(open(os.path.join(a.data, "corpus.json")))
ref = np.load(a.ref)


class RunnerDied(Exception):
    pass


class Client:
    """What the Swift side must do: one writer lock, one reader thread, pending map by id."""

    def __init__(self):
        self.t_spawn = time.perf_counter()
        cmd = [sys.executable, os.path.join(HERE, "runner.py"), "--registry", a.registry, "--entry", a.entry,
               "--model-dir", a.model_dir] + (["--verify"] if a.verify else [])
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.pending, self.lock, self.wlock = {}, threading.Lock(), threading.Lock()
        self.ids = itertools.count()
        self.ready = threading.Event()
        self.info = None
        self.orphan_errors = []
        threading.Thread(target=self._read, daemon=True).start()
        if not self.ready.wait(120):
            raise RuntimeError("runner not ready")
        self.t_ready = time.perf_counter()

    def _read(self):
        for line in self.p.stdout:
            m = json.loads(line)
            if m.get("event") in ("ready", "fatal"):
                self.info = m
                self.ready.set()
                continue
            with self.lock:
                slot = self.pending.pop(m.get("id"), None)
            if slot is None:
                self.orphan_errors.append(m)
                continue
            slot["resp"] = m
            slot["ev"].set()
        # EOF: the process is gone -- fail everything in flight.
        with self.lock:
            for slot in self.pending.values():
                slot["resp"] = None
                slot["ev"].set()
            self.pending.clear()
        self.ready.set()

    def send_raw(self, b: bytes):
        with self.wlock:
            self.p.stdin.write(b)
            self.p.stdin.flush()

    def request(self, texts, kind="document", timeout_ms=30000, rid=None, wait=True):
        rid = rid or f"r{next(self.ids)}"
        slot = {"ev": threading.Event(), "resp": None}
        with self.lock:
            self.pending[rid] = slot
        self.send_raw((json.dumps({"id": rid, "op": "embed", "kind": kind, "texts": texts, "timeout_ms": timeout_ms}) + "\n").encode())
        if not wait:
            return rid, slot
        return self.wait(slot, timeout_ms)

    def wait(self, slot, timeout_ms):
        # Client-side deadline = runner timeout + grace; past it the client would kill the runner.
        if not slot["ev"].wait(timeout_ms / 1000 + 10):
            raise TimeoutError("runner unresponsive")
        if slot["resp"] is None:
            raise RunnerDied()
        return slot["resp"]


def vectors(resp):
    return np.frombuffer(base64.b64decode(resp["vectors"]), dtype="<f2").reshape(resp["count"], resp["dim"]).astype(np.float32)


R = {}
# 1. cold start
c = Client()
r = c.request(["как сбросить пароль?"], "query")
t_first = time.perf_counter()
R["cold_start"] = {"spawn_to_ready_ms": round((c.t_ready - c.t_spawn) * 1000), "runner_load_ms": c.info["load_ms"],
                   "spawn_to_first_vector_ms": round((t_first - c.t_spawn) * 1000), "first_request_ms": r["ms"],
                   "verify_min_cos": c.info.get("verify_min_cos")}
print("cold", R["cold_start"], flush=True)

# 2. concurrency: 8 threads x 6 requests, random subsets of the corpus, answers matched by id
errs, worst, lat = [], [1.0], []
short = [x for x in corpus if x["tokens"] < 1500]


def worker(seed):
    rnd = random.Random(seed)
    for _ in range(6):
        pick = rnd.sample(short, rnd.randint(1, 12))
        t0 = time.perf_counter()
        resp = c.request([x["text"] for x in pick], "document")
        lat.append(time.perf_counter() - t0)
        if not resp.get("ok"):
            errs.append(resp); continue
        v = vectors(resp)
        for x, row in zip(pick, v):
            rr = ref["doc"][x["id"]]
            worst[0] = min(worst[0], float(row @ rr / np.linalg.norm(row) / np.linalg.norm(rr)))


t0 = time.perf_counter()
th = [threading.Thread(target=worker, args=(s,)) for s in range(8)]
[t.start() for t in th]; [t.join() for t in th]
R["concurrent"] = {"requests": 48, "errors": len(errs), "min_cos_vs_reference": round(worst[0], 5),
                   "wall_s": round(time.perf_counter() - t0, 2), "p50_ms": round(1000 * float(np.median(lat))),
                   "max_ms": round(1000 * max(lat)), "unmatched": len(c.orphan_errors)}
print("concurrent", R["concurrent"], flush=True)

# 3. limits: oversize line, bad json, too many texts -> error, runner stays up
c.send_raw(b'{"id":"big","op":"embed","texts":["' + b"a" * (9 * 2**20) + b'"]}\n')
c.send_raw(b"not json\n")
r_many = c.request(["x"] * 300)
r_ok = c.request(["still alive?"], "query")
time.sleep(0.2)
R["limits"] = {"oversize_line": [m["error"]["code"] for m in c.orphan_errors], "too_many_texts": r_many["error"]["code"],
               "after": r_ok["ok"]}
print("limits", R["limits"], flush=True)

longs = [x["text"] for x in corpus if x["tokens"] > 1500] * 3
# 4. timeout
r = c.request(longs, timeout_ms=300)
R["timeout"] = r.get("error")
# 5. cancel
rid, slot = c.request(longs, wait=False)
time.sleep(0.3)
c.send_raw((json.dumps({"id": "c", "op": "cancel", "target": rid}) + "\n").encode())
t0 = time.perf_counter()
r = c.wait(slot, 30000)
R["cancel"] = {"error": r.get("error"), "cancel_to_reply_ms": round((time.perf_counter() - t0) * 1000)}
print("timeout/cancel", R["timeout"], R["cancel"], flush=True)

# 6. kill -9 mid-request, restart, resend
rid, slot = c.request(longs, wait=False)
time.sleep(0.5)
os.kill(c.p.pid, signal.SIGKILL)
try:
    c.wait(slot, 30000)
    died = False
except RunnerDied:
    died = True
c.p.wait()
t0 = time.perf_counter()
c = Client()
r = c.request(["после перезапуска"], "query")
R["kill_restart"] = {"pending_failed_as_died": died, "restart_to_first_vector_ms": round((time.perf_counter() - t0) * 1000),
                     "ok_after": r["ok"]}
print("kill", R["kill_restart"], flush=True)

# 7. graceful EOF during a long request
rid, slot = c.request(longs, wait=False)
time.sleep(0.5)
t0 = time.perf_counter()
c.p.stdin.close()
code = c.p.wait(30)
R["eof"] = {"exit_code": code, "exit_ms": round((time.perf_counter() - t0) * 1000),
            "inflight_reply": (slot["resp"] or {}).get("error", {}).get("code") if slot["ev"].wait(1) else None}
print("eof", R["eof"], flush=True)

# 8. orphan: a middle process spawns the runner, then dies without closing the pipe
mid = subprocess.Popen([sys.executable, "-c", f"""
import subprocess, sys, time
p = subprocess.Popen({[sys.executable, os.path.join(HERE, 'runner.py'), '--registry', a.registry, '--entry', a.entry, '--model-dir', a.model_dir]!r},
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
p.stdout.readline(); print(p.pid, flush=True); time.sleep(600)
"""], stdout=subprocess.PIPE)
rpid = int(mid.stdout.readline())
os.kill(mid.pid, signal.SIGKILL); mid.wait()
t0 = time.perf_counter()
while time.perf_counter() - t0 < 10:
    try:
        os.kill(rpid, 0); time.sleep(0.1)
    except ProcessLookupError:
        break
alive = True
try:
    os.kill(rpid, 0)
except ProcessLookupError:
    alive = False
if alive:
    os.kill(rpid, signal.SIGKILL)
R["orphan"] = {"exited": not alive, "after_ms": round((time.perf_counter() - t0) * 1000)}
print("orphan", R["orphan"], flush=True)
print(json.dumps(R, ensure_ascii=False))
if a.json:
    json.dump(R, open(a.json, "w"), ensure_ascii=False, indent=1)
