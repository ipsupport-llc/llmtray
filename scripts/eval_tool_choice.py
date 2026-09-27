#!/usr/bin/env python3
"""Tool-choice eval: does a model still pick the right chat tool?

Sends LLMTray's real tool declarations and tool-use rule (from
`LLMTray --dump-tool-definitions`, or a saved dump) with one user prompt at a
time to an OpenAI-compatible server -- LLMTray's own proxy by default -- and
scores
  - reflex: no tool call on a prompt that needs none, and
  - choice: the expected tool (and mode) when one is needed;
  - args:   with --binary, whether each call's arguments are understood by
            the app (`LLMTray --check-tool-call`), and which repairs it took.

    scripts/eval_tool_choice.py --model n4 [--runs 2] [--url http://127.0.0.1:8765]
                                [--tools dump.json | --binary .build/debug/LLMTray]
                                [--temp 0.6] [--out results.json]

Offline (no server, or --offline): checks only that every declared tool is
covered by a case and every case's tool is declared, then exits 0 -- so it can
run anywhere. Former tool names (before tools were merged) are mapped to the
current tool and mode, so a dump from an older build can be scored alike.
"""
import argparse, json, subprocess, sys, urllib.error, urllib.request

# (prompt, expected tool or None, arguments the call must have)
CASES = [
    ("привет", None, {}), ("hi there!", None, {}), ("как дела?", None, {}), ("расскажи анекдот", None, {}),
    ("что такое фотосинтез в двух словах?", None, {}), ("напиши функцию на python, которая переворачивает строку", None, {}),
    ("спасибо, всё понятно", None, {}), ("who wrote War and Peace?", None, {}),
    ("сколько будет 3847 * 29?", "calculate", {}), ("what is 15% of 2450?", "calculate", {}),
    ("какое сегодня число?", "get_current_time", {}), ("what day of the week is it today?", "get_current_time", {}),
    ("который час в Токио?", "get_current_time", {"city": "*"}),
    ("найди в интернете, что нового в Swift 6", "web_search", {"source": ["web", None]}),
    ("search the web for the mlx-lm GitHub repository", "web_search", {"source": ["web", None]}),
    ("какие последние новости про Apple?", "web_search", {"source": "news"}),
    ("what are today's top headlines?", "web_search", {"source": "news"}),
    ("что сейчас обсуждают на Hacker News?", "web_search", {"source": "hackernews"}),
    ("что википедия говорит про Киев?", "web_search", {"source": "wikipedia"}),
    ("look up Alan Turing on Wikipedia", "web_search", {"source": "wikipedia"}),
    ("какое население и столица у Японии?", "get_country_info", {"about": ["facts", None]}),
    ("какие государственные праздники в Украине в 2026 году?", "get_country_info", {"about": "holidays"}),
    ("сколько будет 100 долларов в евро по сегодняшнему курсу?", "convert_currency", {}),
    ("convert 250 GBP to JPY", "convert_currency", {}),
    ("какая погода в Львове?", "get_weather", {"kind": ["forecast", None]}),
    ("will it rain in London this weekend?", "get_weather", {"kind": ["forecast", "hourly", None]}),
    ("будет ли дождь сегодня вечером в Киеве, по часам?", "get_weather", {"kind": "hourly"}),
    ("is the air quality ok in Delhi right now?", "get_weather", {"kind": "air"}),
    ("во сколько закат в Риме?", "get_weather", {"kind": "sun"}),
    ("нарисуй кота в шляпе", "generate_image", {}),
    ("compose a short upbeat synth-pop jingle", "generate_music", {}),
    # Folder tools (adr/0014): looking is files; a change the user asked for
    # outright is change_files (it only proposes a plan the user approves).
    ("что лежит у меня в папке Загрузки?", "files", {"path": "*"}),
    ("what's taking the space in ~/Downloads? any duplicate files?", "files", {"path": "*"}),
    ("how big is ~/Documents/report.pdf and is it really a PDF?", "files", {"path": "*"}),
    ("перемести ~/Downloads/invoice.pdf в папку ~/Documents/Invoices", "change_files", {"ops": "*"}),
    ("put ~/Desktop/old-notes.txt in the Trash", "change_files", {"ops": "*"}),
    ("create a folder Screenshots in ~/Desktop", "change_files", {"ops": "*"}),
    ("what does 'ls' mean in a terminal?", None, {}),
]

# Former names -> (tool, arguments they imply): scores a dump from before
# the merge by the same cases.
FORMER = {
    "get_current_date": ("get_current_time", {}), "get_current_time_in_city": ("get_current_time", {}),
    "news": ("web_search", {"source": "news"}), "hackernews": ("web_search", {"source": "hackernews"}),
    "get_wikipedia_summary": ("web_search", {"source": "wikipedia"}),
    "get_hourly_forecast": ("get_weather", {"kind": "hourly"}), "get_air_quality": ("get_weather", {"kind": "air"}),
    "get_sunrise_sunset": ("get_weather", {"kind": "sun"}),
    "get_public_holidays": ("get_country_info", {"about": "holidays"}),
}
# Tools no single prompt can call without chat state (an image to edit or
# look at, a project with files).
NEEDS_STATE = {"edit_image", "view_image", "project_files"}
# Former names a model may use for the folder tools (before they were two).
FORMER.update({"list_dir": ("files", {}), "file_info": ("files", {}), "list_files": ("files", {})})

SYSTEM = ("You are a helpful assistant running locally on the user's Mac. Answer in the language the user writes in. "
          "Be concise and direct; use Markdown (lists, code blocks) when it helps readability.")


def load_defs(a):
    if a.tools:
        return json.load(open(a.tools))
    out = subprocess.run([a.binary, "--dump-tool-definitions"], capture_output=True, text=True, timeout=60)
    return json.loads(out.stdout)


def canonical(name, args):
    if name in FORMER:
        tool, implied = FORMER[name]
        return tool, {**implied, **args}
    return name, args


def matches(expected_args, args):
    for key, want in expected_args.items():
        got = args.get(key)
        options = want if isinstance(want, list) else [want]
        if want == "*":
            if not got: return False
        elif got not in options and not (isinstance(got, str) and got.lower() in [o for o in options if o]):
            return False
    return True


def check_args(binary, name, raw):
    if not binary:
        return None
    try:
        out = subprocess.run([binary, "--check-tool-call", name, raw], capture_output=True, text=True, timeout=30)
        return json.loads(out.stdout)
    except Exception as e:
        return {"ok": False, "error": f"check failed: {e}"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", help="model name on the server (LLMTray's proxy loads it)")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--url", default="http://127.0.0.1:8765")
    ap.add_argument("--tools", help="a saved --dump-tool-definitions JSON")
    ap.add_argument("--binary", default=".build/debug/LLMTray", help="LLMTray executable (dump and argument checks)")
    ap.add_argument("--temp", type=float, default=0.6)
    ap.add_argument("--max-tokens", type=int, default=600)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()
    defs = load_defs(a)
    declared = {t["function"]["name"] for t in defs["tools"]}
    declared_now = {canonical(n, {})[0] for n in declared}
    expected = {c[1] for c in CASES if c[1]}
    missing_cases = sorted(declared_now - expected - NEEDS_STATE)
    undeclared = sorted(expected - declared_now)
    print(f"{len(declared)} tools declared; {len(CASES)} prompts covering {len(expected)} tools")
    if missing_cases: print("  no case for:", ", ".join(missing_cases))
    if undeclared: print("  cases for undeclared tools:", ", ".join(undeclared))
    if missing_cases or undeclared:
        return 1
    if a.offline or not a.model:
        print("offline: coverage only (pass --model to run against a server)")
        return 0
    try:
        urllib.request.urlopen(f"{a.url}/v1/models", timeout=5).read()
    except (urllib.error.URLError, OSError) as e:
        print(f"skipped: no server at {a.url} ({e})")
        return 0

    system = SYSTEM + "\n\n" + defs["tool_use_policy"]
    binary = a.binary if not a.tools else (a.binary if a.binary and subprocess.run(["test", "-x", a.binary]).returncode == 0 else None)
    reflex = choice_ok = total_none = total_task = args_ok = args_total = 0
    rows = []
    for prompt, want, want_args in CASES:
        got = []
        for _ in range(a.runs):
            body = {"model": a.model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
                    "tools": defs["tools"], "temperature": a.temp, "max_tokens": a.max_tokens, "stream": False}
            req = urllib.request.Request(f"{a.url}/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
            msg = json.load(urllib.request.urlopen(req, timeout=900))["choices"][0]["message"]
            calls = msg.get("tool_calls") or []
            if not calls:
                got.append({"tool": None})
                continue
            fn = calls[0]["function"]
            raw = fn.get("arguments") or "{}"
            raw = raw if isinstance(raw, str) else json.dumps(raw)
            try:
                parsed = json.loads(raw)
            except ValueError:
                parsed = {}
            tool, args = canonical(fn["name"], parsed if isinstance(parsed, dict) else {})
            check = check_args(binary, fn["name"], raw)
            # Scored as the app would run it (its name and argument repairs).
            if check and check.get("tool"):
                tool, args = check["tool"], check.get("arguments") or {}
            got.append({"tool": tool, "called": fn["name"], "args": args, "raw": raw, "check": check})
        for g in got:
            if want is None:
                total_none += 1
                reflex += g["tool"] is not None
            else:
                total_task += 1
                choice_ok += g["tool"] == want and matches(want_args, g.get("args", {}))
            if g.get("check") is not None:
                args_total += 1
                args_ok += bool(g["check"].get("ok"))
        rows.append({"prompt": prompt, "expected": want, "expected_args": want_args, "got": got})
        shown = [f'{g["called"]}{json.dumps(g["args"], ensure_ascii=False)}' if g["tool"] else "-" for g in got]
        print(f"{prompt[:48]:48} expected={want} got={shown}", flush=True)
    summary = (f"{a.model}: reflex {reflex}/{total_none} (lower is better), right tool+mode {choice_ok}/{total_task}"
               + (f", arguments understood {args_ok}/{args_total}" if args_total else "") + f" (temp {a.temp}, runs {a.runs})")
    print("\n" + summary)
    if a.out:
        json.dump({"summary": summary, "rows": rows}, open(a.out, "w"), ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
