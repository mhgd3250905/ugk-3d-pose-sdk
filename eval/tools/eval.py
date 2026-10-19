#!/usr/bin/env python3
"""AI 训练助理评测：调用 DeepSeek（OpenAI 兼容），校验 → 失败把错误回传重写一次 → 统计。

为省额度和适配 120 秒的命令时限，按“尝试”分步跑，每次调用的结果立即落盘：
  python3 tools/eval.py call --round 1 --attempt 1 --cases F1,F2,F3   # 首次生成（并行）
  python3 tools/eval.py call --round 1 --attempt 2 --cases F1,F2      # 只对第 1 次校验失败的用例回传错误重写
  python3 tools/eval.py summary --round 1                             # 汇总成 eval/results/round1.md / .json
  python3 tools/eval.py failed --round 1                              # 列出需要下一轮重跑的用例
  python3 tools/eval.py dry                                           # 不调模型，用手写回复走一遍流程
所有调用记在 eval/results/calls.jsonl（用例、轮次、尝试、耗时、token），summary 会给累计调用次数和 token。

环境：EVAL_BASE_URL（默认 https://opencsg.com/aigateway/v1），EVAL_MODEL（默认 deepseek-v4.1-flash-1017）。
不带 Authorization 头（沙盒代理注入 key）；需要自带 key 时设 EVAL_API_KEY。
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from validate import load, validate_reply, format_feedback, default_catalog_path, extract_json  # noqa: E402
from build_prompt import build_system_prompt  # noqa: E402

BASE = os.environ.get("EVAL_BASE_URL", "https://opencsg.com/aigateway/v1")
MODEL = os.environ.get("EVAL_MODEL", "deepseek-v4.1-flash-1017")
MAX_TOKENS = int(os.environ.get("EVAL_MAX_TOKENS", "6000"))
RES = os.path.join(ROOT, "eval", "results")
CASES = os.path.join(ROOT, "eval", "cases", "cases.json")
CALLS = os.path.join(RES, "calls.jsonl")


def chat(messages, timeout=100):
    """429（限流，不计费）时退避重试，总耗时不超过约 110 秒。"""
    t0 = time.time()
    for k in range(4):
        r = _chat(messages, timeout=max(20, timeout - (time.time() - t0)))
        if "error" in r and "429" in r["error"] and time.time() - t0 < 70:
            time.sleep(15 + 10 * k)
            continue
        r["seconds"] = r.get("seconds")
        r["retries429"] = k
        return r
    return r


def _chat(messages, timeout=100):
    body = {"model": MODEL, "messages": messages, "max_tokens": MAX_TOKENS, "temperature": 0.3,
            "response_format": {"type": "json_object"}}
    headers = {"Content-Type": "application/json"}
    if os.environ.get("EVAL_API_KEY"):
        headers["Authorization"] = "Bearer " + os.environ["EVAL_API_KEY"]
    req = urllib.request.Request(BASE.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(), headers=headers)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            if raw[:2] == b"\x1f\x8b":
                import gzip
                raw = gzip.decompress(raw)
            data = json.loads(raw)
    except urllib.error.HTTPError as e:
        raw = e.read()
        if raw[:2] == b"\x1f\x8b":
            import gzip
            raw = gzip.decompress(raw)
        return {"error": f"HTTP {e.code}: {raw[:500].decode(errors='replace')}", "seconds": round(time.time() - t0, 1)}
    except Exception as e:
        return {"error": repr(e), "seconds": round(time.time() - t0, 1)}
    msg = data["choices"][0]["message"]
    u = data.get("usage", {}) or {}
    reasoning = (u.get("completion_tokens_details") or {}).get("reasoning_tokens", u.get("reasoning_tokens"))
    return {"content": msg.get("content") or "", "finish": data["choices"][0].get("finish_reason"),
            "usage": {"prompt": u.get("prompt_tokens"), "completion": u.get("completion_tokens"), "reasoning": reasoning,
                      "total": u.get("total_tokens"), "cached": (u.get("prompt_tokens_details") or {}).get("cached_tokens")},
            "seconds": round(time.time() - t0, 1)}


def path(rnd, cid, attempt):
    d = os.path.join(RES, f"round{rnd}")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"{cid}.a{attempt}.json")


def check_expect(case, reply, R):
    """越界/意图处理是否正确（与校验器无关的期望）。返回问题列表，空 = 正确。"""
    e, probs = case["expect"], []
    if reply is None:
        return ["无法解析回复"]
    kind = reply.get("kind")
    if kind not in e["kinds"]:
        probs.append(f"kind={kind}，期望 {e['kinds']}")
    if e.get("noUnknown") and R.unknown_ids:
        probs.append(f"编造了动作 {R.unknown_ids}")
    plan = reply.get("plan") if kind == "plan" else None
    if plan and isinstance(plan, dict):
        cat = {d["id"]: d for d in CATALOG["drills"]}
        ids = [it.get("exerciseId") for b in plan.get("blocks", []) if isinstance(b, dict) for it in b.get("items", []) if isinstance(it, dict)]
        for a in e.get("avoid", []):
            if a not in (plan.get("avoid") or []):
                probs.append(f"plan.avoid 没写 {a}")
        if e.get("scene") and plan.get("scene") != e["scene"]:
            probs.append(f"scene={plan.get('scene')}，期望 {e['scene']}")
        if e.get("minutes"):
            tm = plan.get("targetMinutes")
            if not isinstance(tm, int) or abs(tm - e["minutes"]) > max(2, e["minutes"] * 0.2):
                probs.append(f"targetMinutes={tm}，用户要 {e['minutes']}")
            if R.est_minutes and abs(R.est_minutes - e["minutes"]) / e["minutes"] > 0.4:
                probs.append(f"估算时长 {R.est_minutes} 分钟，用户要 {e['minutes']}")
        for i in ids:
            d = cat.get(i)
            if not d:
                continue
            if set(d["muscleGroups"]) & set(e.get("forbidGroups", [])) and set(d["muscleGroups"]) <= set(e.get("forbidGroups", [])) | {"deltoids", "abs"}:
                probs.append(f"出现了不该有的部位动作 {i}")
            if d["category"] in e.get("forbidCategories", []):
                probs.append(f"放松计划里有{d['category']}动作 {i}")
    return probs


def run_one(case, rnd, attempt, profiles, system_prompts):
    prof = profiles[case["profile"]]
    msgs = [{"role": "system", "content": system_prompts[case["profile"]]}, {"role": "user", "content": case["user"]}]
    if attempt == 2:
        prev = load(path(rnd, case["id"], 1))
        msgs += [{"role": "assistant", "content": prev["content"]}, {"role": "user", "content": prev["feedback"]}]
    r = chat(msgs)
    rec = {"case": case["id"], "profile": case["profile"], "round": rnd, "attempt": attempt, "seconds": r.get("seconds"),
           "usage": r.get("usage"), "error": r.get("error"), "finish": r.get("finish"), "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    with open(CALLS, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    if r.get("error"):
        out = {**rec, "content": "", "validation": {"ok": False, "errors": ["E_CALL " + r["error"]]}, "expectProblems": ["调用失败"]}
    else:
        R = validate_reply(r["content"], CATALOG, prof, case.get("request"))
        out = {**rec, "content": r["content"], "validation": R.to_dict(), "expectProblems": check_expect(case, R.reply, R),
               "feedback": format_feedback(R) if not R.ok else None}
    json.dump(out, open(path(rnd, case["id"], attempt), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    v = out["validation"]
    return f"{case['id']} a{attempt} {'✓' if v['ok'] else '✗'} {out.get('seconds')}s {(out.get('usage') or {}).get('total')}tok kind={v.get('kind')} err={v['errors'][:3]} expect={out['expectProblems']}"


def summarize(rnd):
    cases = {c["id"]: c for c in load(CASES)}
    rows = []
    for cid, c in cases.items():
        a1p, a2p = path(rnd, cid, 1), path(rnd, cid, 2)
        if not os.path.exists(a1p):
            # 本轮没重跑：沿用上一轮最终结果
            prev = None
            for k in range(rnd - 1, 0, -1):
                for a in (2, 1):
                    p = path(k, cid, a)
                    if os.path.exists(p):
                        prev = (k, a, load(p))
                        break
                if prev:
                    break
            if not prev:
                continue
            k, a, d = prev
            rows.append({"id": cid, "profile": c["profile"], "note": c["note"], "carried": k, "first": None, "final": d["validation"]["ok"],
                         "rewritten": False, "expectOk": not d["expectProblems"], "expectProblems": d["expectProblems"], "kind": d["validation"].get("kind"),
                         "unknown": [], "scope": [], "calls": [], "errors": d["validation"]["errors"]})
            continue
        a1 = load(a1p)
        a2 = load(a2p) if os.path.exists(a2p) else None
        fin = a2 or a1
        calls = [x for x in (a1, a2) if x]
        rows.append({"id": cid, "profile": c["profile"], "note": c["note"], "carried": None,
                     "first": a1["validation"]["ok"], "final": fin["validation"]["ok"], "rewritten": a2 is not None,
                     "expectOk": not fin["expectProblems"], "expectProblems": fin["expectProblems"], "kind": fin["validation"].get("kind"),
                     "unknown": sum((x["validation"].get("unknownIds", []) for x in calls), []),
                     "scope": sum((x["validation"].get("scopeIds", []) for x in calls), []),
                     "calls": [{"seconds": x["seconds"], "usage": x["usage"]} for x in calls],
                     "errors": a1["validation"]["errors"], "finalErrors": fin["validation"]["errors"]})
    ran = [r for r in rows if r["carried"] is None]

    def stats(rs, key):
        return f"{sum(1 for r in rs if r[key])}/{len(rs)}" if rs else "-"

    allcalls = [c for r in ran for c in r["calls"]]
    secs = [c["seconds"] for c in allcalls if c["seconds"]]
    toks = [c["usage"]["total"] for c in allcalls if c.get("usage") and c["usage"].get("total")]
    ledger = [json.loads(l) for l in open(CALLS, encoding="utf-8")] if os.path.exists(CALLS) else []
    tot_tok = sum((x.get("usage") or {}).get("total") or 0 for x in ledger)
    summary = {
        "round": rnd, "model": MODEL, "casesRun": len(ran), "casesTotal": len(rows),
        "firstPass": stats(ran, "first"), "finalPassAfterRewrite": stats(ran, "final"),
        "finalPassAllCases": stats(rows, "final"), "expectOkAllCases": stats(rows, "expectOk"),
        "fabricatedIds": sum(len(r["unknown"]) for r in ran), "outOfScopeIds": sum(len(r["scope"]) for r in ran),
        "callsThisRound": len(allcalls), "avgSeconds": round(sum(secs) / len(secs), 1) if secs else None,
        "avgTokens": round(sum(toks) / len(toks)) if toks else None,
        "avgPromptTokens": round(sum(c["usage"]["prompt"] for c in allcalls if c.get("usage")) / max(1, len(toks))) if toks else None,
        "avgReasoningTokens": round(sum((c["usage"].get("reasoning") or 0) for c in allcalls if c.get("usage")) / max(1, len(toks))) if toks else None,
        "ledgerCalls": len(ledger), "ledgerTokens": tot_tok,
        "byProfile": {p: {"firstPass": stats([r for r in ran if r["profile"] == p], "first"),
                          "finalPass": stats([r for r in rows if r["profile"] == p], "final"),
                          "expectOk": stats([r for r in rows if r["profile"] == p], "expectOk")} for p in ("flarelab", "hiplab", "smartfit")},
        "rows": rows,
    }
    json.dump(summary, open(os.path.join(RES, f"round{rnd}.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    L = [f"# 评测第 {rnd} 轮（{MODEL}）", "",
         f"- 本轮实跑 {len(ran)} 条（其余沿用上一轮结果），共 {len(rows)} 条",
         f"- 一次通过率（本轮实跑）{summary['firstPass']}；重写后通过 {summary['finalPassAfterRewrite']}；全部用例最终通过 {summary['finalPassAllCases']}",
         f"- 意图/越界处理正确 {summary['expectOkAllCases']}；编造 id {summary['fabricatedIds']} 次；越界 id {summary['outOfScopeIds']} 次",
         f"- 本轮调用 {len(allcalls)} 次，平均 {summary['avgSeconds']} 秒、{summary['avgTokens']} token/次（输入约 {summary['avgPromptTokens']}，推理约 {summary['avgReasoningTokens']}）",
         f"- 累计调用 {len(ledger)} 次，累计 {tot_tok} token", "",
         "| 用例 | App | 场景 | 首次 | 重写 | 最终 | 意图 | kind | 问题 |", "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        f = "沿用" if r["carried"] else ("✓" if r["first"] else "✗")
        probs = "；".join((r.get("finalErrors") or r["errors"] or [])[:3] + r["expectProblems"])
        L.append(f"| {r['id']} | {r['profile']} | {r['note']} | {f} | {'是' if r['rewritten'] else ''} | {'✓' if r['final'] else '✗'} | {'✓' if r['expectOk'] else '✗'} | {r['kind']} | {probs.replace('|', '/')} |")
    open(os.path.join(RES, f"round{rnd}.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("\n".join(L[:8]))


def main():
    global CATALOG
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["call", "summary", "failed", "dry", "prompt"])
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("--attempt", type=int, default=1)
    ap.add_argument("--cases", default="")
    ap.add_argument("--catalog", default=default_catalog_path())
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--gap", type=float, default=0, help="串行调用之间等待秒数（网关 TPM 很低时用）")
    a = ap.parse_args()
    CATALOG = load(a.catalog)
    os.makedirs(RES, exist_ok=True)
    cases = load(CASES)
    profiles = {k: load(os.path.join(ROOT, "profiles", f"{k}.json")) for k in ("flarelab", "hiplab", "smartfit")}
    if a.cmd == "summary":
        return summarize(a.round)
    if a.cmd == "failed":
        bad = []
        for c in cases:
            p2, p1 = path(a.round, c["id"], 2), path(a.round, c["id"], 1)
            p = p2 if os.path.exists(p2) else p1
            if os.path.exists(p):
                d = load(p)
                if not d["validation"]["ok"] or d["expectProblems"]:
                    bad.append(c["id"])
        print(",".join(bad))
        return
    if a.cmd == "prompt":
        for k, p in profiles.items():
            print(k, len(build_system_prompt(CATALOG, p)))
        return
    if a.cmd == "dry":
        # 手写回复走一遍：一个合法、一个编造 id、一个 ask
        fake = {"H1": {"kind": "plan", "text": "x", "plan": {"schemaVersion": 1, "title": "睡前放松", "summary": "s", "goal": "relax", "scene": "home", "equipment": ["mat"], "level": 1, "targetMinutes": 15, "avoid": [],
                "blocks": [{"id": "b1", "name": "拉伸", "type": "main", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [{"exerciseId": "s-figure4", "mode": "time", "sets": 2, "workSeconds": 40, "perSide": True, "restSeconds": 15}, {"exerciseId": "s-butterfly", "mode": "time", "sets": 2, "workSeconds": 45, "perSide": False, "restSeconds": 15}, {"exerciseId": "h-knee-hug", "mode": "time", "sets": 2, "workSeconds": 45, "perSide": False, "restSeconds": 15}, {"exerciseId": "n-thomas-test", "mode": "time", "sets": 2, "workSeconds": 40, "perSide": True, "restSeconds": 15}, {"exerciseId": "h-supine-twist", "mode": "time", "sets": 1, "workSeconds": 40, "perSide": True, "restSeconds": 10}]}]}},
                "H2": {"kind": "plan", "text": "x", "plan": {"schemaVersion": 1, "title": "胸", "summary": "s", "goal": "strength", "scene": "home", "equipment": [], "level": 1, "targetMinutes": 10, "blocks": [{"id": "b", "name": "主", "type": "main", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [{"exerciseId": "pushup", "mode": "reps", "sets": 3, "reps": 10, "perSide": False, "restSeconds": 30}]}]}},
                "S7": {"kind": "ask", "text": "想练哪方面？", "options": ["力量", "放松"]}}
        for cid, rep in fake.items():
            c = next(x for x in cases if x["id"] == cid)
            R = validate_reply(rep, CATALOG, profiles[c["profile"]], c.get("request"))
            print(cid, "ok" if R.ok else R.errors, "expect:", check_expect(c, R.reply, R), "est", R.est_minutes)
            if not R.ok:
                print(format_feedback(R))
        return
    sel = [c for c in cases if not a.cases or c["id"] in a.cases.split(",")]
    if a.attempt == 2:
        sel = [c for c in sel if os.path.exists(path(a.round, c["id"], 1)) and not load(path(a.round, c["id"], 1))["validation"]["ok"]
               and load(path(a.round, c["id"], 1)).get("feedback")]
    sp = {k: build_system_prompt(CATALOG, p) for k, p in profiles.items()}
    if a.workers <= 1:
        for n, c in enumerate(sel):
            if n and a.gap:
                time.sleep(a.gap)
            print(run_one(c, a.round, a.attempt, profiles, sp), flush=True)
        return
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        for line in ex.map(lambda c: run_one(c, a.round, a.attempt, profiles, sp), sel):
            print(line, flush=True)


CATALOG = None
if __name__ == "__main__":
    main()
