#!/usr/bin/env python3
"""AI 回复校验器（Python 版，规则对齐 SmartFit lib/domain/plan_validator.dart，并加 profile 范围检查）。

回复信封（与 ugk_coach EnvelopeParser 一致）：
  {"kind": "plan",  "text": "…", "plan": {TrainingPlan v1}}
  {"kind": "ask",   "text": "…？", "options": ["…", "…"]}
  {"kind": "reply", "text": "…"}

错误（error，判失败，需重写）：
  E_JSON      不是 JSON / 信封字段缺失或类型错
  E_SCHEMA    TrainingPlan v1 结构问题（缺字段、枚举外的值、类型错）
  E_UNKNOWN   未知动作 id（不在目录 = 编造）
  E_SCOPE     动作在目录里但不在本 App profile 范围
  E_DOSE      组数/次数/时长/休息/轮数超出硬限；mode 与动作剂量单位不一致
  E_SIDE      perSide 与动作 unilateral 不一致
  E_AVOID     动作 cautions 命中用户要保护的部位
  E_EQUIP     动作需要用户没有的器械
  E_SCENE     动作不适合该场所（办公室着地、场所不匹配）
  E_ORDER     热身块排在放松块之后
警告（warning，不判失败）：剂量超出动作 doseRange、估算时长偏离 targetMinutes 超 40%、块内重复动作、ask 带多个问号等。

用法：
  python3 tools/validate.py --catalog <catalog.json> --profile profiles/hiplab.json reply.json [--request '{"scene":"office"}']
  python3 tools/validate.py --selftest
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

LIMITS = {"sets": (1, 6), "reps": (1, 30), "workSeconds": (10, 120), "restSeconds": (0, 180), "rounds": (1, 6), "restBetweenRoundsSeconds": (0, 300)}
BLOCK_TYPES = {"warmup", "main", "circuit", "cooldown"}
GOALS = {"relax", "mobility", "strength", "core", "fullbody", "warmup", "cooldown"}
SCENES = {"home", "office", "gym"}
SWITCH_SIDE_S, TRANSITION_S, PREP_S = 5, 15, 10
DEFAULT_SCENE_RULES = {
    "home": {"assumedEquipment": ["mat", "chair", "wall", "block"], "acceptDrillScenes": ["home"]},
    "office": {"assumedEquipment": ["chair", "wall"], "acceptDrillScenes": ["office"], "forbidFloor": True},
    "gym": {"allEquipment": True, "acceptDrillScenes": ["gym", "home"]},
}


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def default_catalog_path():
    for p in (os.path.join(ROOT, "catalog.json"), os.path.join(ROOT, "..", "gh-3D-Pose-Hub", "catalog", "catalog.json")):
        if os.path.exists(p):
            return p
    return None


def in_scope(drill, profile):
    s = profile.get("select") or {}
    if drill["id"] in set(s.get("exclude", [])) or set(drill.get("tags", [])) & set(s.get("excludeTags", [])):
        return False
    keys = ("ids", "idPrefixes", "apps", "tags", "categories")
    if not any(s.get(k) for k in keys):
        return True
    return (drill["id"] in s.get("ids", []) or any(drill["id"].startswith(p) for p in s.get("idPrefixes", []))
            or bool(set(drill["apps"]) & set(s.get("apps", []))) or bool(set(drill.get("tags", [])) & set(s.get("tags", [])))
            or drill["category"] in s.get("categories", []))


def scope(catalog, profile):
    return [d for d in catalog["drills"] if in_scope(d, profile)]


def rep_seconds(drill):
    for v in drill["assets"]["video"]["sources"]:
        if v.get("repSeconds"):
            return float(v["repSeconds"])
    return 3.0


def estimate_seconds(plan, drills):
    """与 SmartFit SessionBuilder 同口径的粗估：准备 10 秒；每组 = 工作 ×(单侧 2 面) + 换侧 5 秒；组间休息；动作之间 15 秒过渡；轮间休息。"""
    total = PREP_S
    first = True
    for b in plan.get("blocks", []):
        rounds = int(b.get("rounds", 1) or 1)
        for r in range(rounds):
            for it in b.get("items", []):
                d = drills.get(it.get("exerciseId"))
                if not d:
                    continue
                if not first:
                    total += TRANSITION_S
                first = False
                sides = 2 if it.get("perSide") else 1
                work = (it.get("reps") or 10) * rep_seconds(d) if it.get("mode") == "reps" else (it.get("workSeconds") or 30)
                sets = int(it.get("sets", 1) or 1)
                total += sets * (work * sides + (SWITCH_SIDE_S if sides == 2 else 0)) + (sets - 1) * int(it.get("restSeconds", 0) or 0)
            if r < rounds - 1:
                total += max(int(b.get("restBetweenRoundsSeconds", 0) or 0), TRANSITION_S)
    return total


def extract_json(text):
    """容忍 ```json 代码块和前后杂字，取第一个完整 JSON 对象。"""
    t = text.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", t, re.S)
    if m:
        t = m.group(1).strip()
    try:
        return json.loads(t), None
    except Exception:
        pass
    start = t.find("{")
    if start < 0:
        return None, "没有 JSON 对象"
    depth, ins, esc = 0, False, False
    for i in range(start, len(t)):
        c = t[i]
        if ins:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                ins = False
        elif c == '"':
            ins = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(t[start:i + 1]), None
                except Exception as e:
                    return None, f"JSON 解析失败：{e}"
    return None, "JSON 不完整"


class Result:
    def __init__(self):
        self.errors, self.warnings = [], []
        self.unknown_ids, self.scope_ids = [], []
        self.reply = None
        self.est_minutes = None

    def err(self, code, msg):
        self.errors.append(f"{code} {msg}")

    def warn(self, msg):
        self.warnings.append(msg)

    @property
    def ok(self):
        return self.reply is not None and not self.errors

    def to_dict(self):
        return {"ok": self.ok, "errors": self.errors, "warnings": self.warnings, "unknownIds": self.unknown_ids,
                "scopeIds": self.scope_ids, "kind": (self.reply or {}).get("kind"), "estMinutes": self.est_minutes}


def validate_reply(content, catalog, profile, request=None):
    """content：模型原始输出字符串或已解析的 dict。request：App 已知的硬条件 {scene, equipment, avoid}（可选）。"""
    R = Result()
    request = request or {}
    j, e = (content, None) if isinstance(content, dict) else extract_json(content)
    if j is None:
        R.err("E_JSON", e)
        return R
    if "kind" not in j and isinstance(j.get("blocks"), list):
        j = {"kind": "plan", "text": j.get("summary") or j.get("title") or "", "plan": j}
        R.warn("模型直接输出了计划本体，已按 kind=plan 包装")
    kind, text = j.get("kind"), j.get("text")
    if kind not in ("plan", "ask", "reply"):
        R.err("E_JSON", f"kind 必须是 plan/ask/reply，实际 {kind!r}")
    if not isinstance(text, str) or not text.strip():
        R.err("E_JSON", "text 必须是非空字符串")
    elif len(text) > 400:
        R.warn("text 超过 400 字")
    opts = j.get("options")
    if opts is not None and (not isinstance(opts, list) or not all(isinstance(o, str) for o in opts) or len(opts) > 4):
        R.err("E_JSON", "options 必须是 ≤4 个字符串")
    if kind == "ask" and isinstance(text, str) and (text.count("？") + text.count("?")) > 2:
        R.warn("ask 似乎问了不止一个问题")
    if kind != "plan":
        if j.get("plan") is not None:
            R.warn(f"kind={kind} 不应带 plan")
        R.reply = j
        return R
    plan = j.get("plan")
    if not isinstance(plan, dict):
        R.err("E_JSON", "kind=plan 时必须带 plan 对象")
        return R
    R.reply = j
    validate_plan(plan, catalog, profile, request, R)
    return R


def validate_plan(plan, catalog, profile, request, R):
    drills = {d["id"]: d for d in catalog["drills"]}
    tax = catalog["taxonomy"]
    S = lambda m: R.err("E_SCHEMA", m)
    if plan.get("schemaVersion") != 1:
        S("schemaVersion 必须为 1")
    for k in ("title", "summary"):
        if not isinstance(plan.get(k), str) or not plan.get(k).strip():
            S(f"缺少 {k}")
    goal = plan.get("goal")
    goals = set(profile.get("goals") or GOALS)
    if goal not in GOALS:
        S(f"goal {goal!r} 不在 {sorted(GOALS)}")
    elif goal not in goals:
        R.warn(f"goal {goal} 不在本 App 允许的 {sorted(goals)}")
    scene_rules = profile.get("scenes") or DEFAULT_SCENE_RULES
    scene = request.get("scene") or plan.get("scene")
    if plan.get("scene") not in SCENES:
        S(f"scene {plan.get('scene')!r} 不在 home/office/gym")
    elif plan.get("scene") not in scene_rules:
        R.err("E_SCENE", f"本 App 不支持场所 {plan.get('scene')}")
    if request.get("scene") and plan.get("scene") != request["scene"]:
        R.err("E_SCENE", f"计划场所 {plan.get('scene')} 与用户场所 {request['scene']} 不符")
    if not isinstance(plan.get("level"), int) or plan.get("level") not in (1, 2, 3):
        S("level 必须是 1/2/3")
    tm = plan.get("targetMinutes")
    lo, hi = (profile.get("limits") or {}).get("minutes", [3, 60])
    if not isinstance(tm, int):
        S("targetMinutes 必须是整数")
    elif not (lo <= tm <= hi):
        R.err("E_DOSE", f"targetMinutes {tm} 超出 {lo}–{hi}")
    for k in ("equipment", "avoid", "notes", "safetyNotes"):
        if k in plan and not (isinstance(plan[k], list) and all(isinstance(x, str) for x in plan[k])):
            S(f"{k} 必须是字符串数组")
    for q in plan.get("equipment") or []:
        if q not in tax["equipment"]:
            S(f"equipment {q!r} 不是器械 id")
    avoid = set(plan.get("avoid") or []) | set(request.get("avoid") or [])
    for a in avoid:
        if a not in tax["cautions"]:
            R.warn(f"avoid 部位 {a!r} 不在词表 {tax['cautions']}")
    rule = scene_rules.get(scene) or DEFAULT_SCENE_RULES.get(scene) or {}
    if rule.get("allEquipment"):
        have = None
    else:
        base = request.get("equipment") if request.get("equipment") is not None else (plan.get("equipment") or [])
        have = set(base) | set(rule.get("assumedEquipment", []))
    accept = set(rule.get("acceptDrillScenes") or [scene])
    blocks = plan.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        S("计划没有任何训练块")
        return
    used_equipment = set()
    saw_cool = False
    n_items = 0
    for bi, b in enumerate(blocks):
        if not isinstance(b, dict):
            S(f"blocks[{bi}] 不是对象")
            continue
        name = b.get("name") or f"块{bi + 1}"
        if b.get("type") not in BLOCK_TYPES:
            S(f"「{name}」type {b.get('type')!r} 不在 warmup/main/circuit/cooldown")
        rounds = b.get("rounds", 1)
        if not isinstance(rounds, int) or not (1 <= rounds <= 6):
            R.err("E_DOSE", f"「{name}」轮数 {rounds} 超出 1–6")
        rb = b.get("restBetweenRoundsSeconds", 0)
        if not isinstance(rb, int) or not (0 <= rb <= 300):
            R.err("E_DOSE", f"「{name}」轮间休息 {rb} 超出 0–300")
        if b.get("type") == "cooldown":
            saw_cool = True
        if b.get("type") == "warmup" and saw_cool:
            R.err("E_ORDER", "热身块不能排在放松块之后")
        items = b.get("items")
        if not isinstance(items, list) or not items:
            S(f"训练块「{name}」为空")
            continue
        seen = set()
        for it in items:
            n_items += 1
            if not isinstance(it, dict):
                S(f"「{name}」里有非对象条目")
                continue
            i = it.get("exerciseId")
            d = drills.get(i)
            if d is None:
                R.err("E_UNKNOWN", f"未知动作 ID：{i}")
                R.unknown_ids.append(str(i))
                continue
            nm = f"{d['name']['zh']}（{i}）"
            if not in_scope(d, profile):
                R.err("E_SCOPE", f"{nm} 不在本 App 的动作范围")
                R.scope_ids.append(i)
            if i in seen:
                R.warn(f"「{name}」里重复了 {nm}")
            seen.add(i)
            mode = it.get("mode")
            if mode not in ("reps", "time"):
                S(f"{nm}：mode 必须是 reps/time")
            elif mode != d["defaultDose"]["mode"]:
                R.err("E_DOSE", f"{nm}：mode 应为 {d['defaultDose']['mode']}（目录剂量单位）")
            sets = it.get("sets")
            if not isinstance(sets, int) or not (1 <= sets <= 6):
                R.err("E_DOSE", f"{nm}：组数 {sets} 超出 1–6")
            rng = d["doseRange"]
            if mode == "reps":
                v = it.get("reps")
                if not isinstance(v, int) or not (1 <= v <= 30):
                    R.err("E_DOSE", f"{nm}：次数 {v} 超出 1–30")
                elif "reps" in rng and not (rng["reps"][0] <= v <= rng["reps"][1]):
                    R.warn(f"{nm}：次数 {v} 超出推荐 {rng['reps']}")
            elif mode == "time":
                v = it.get("workSeconds", it.get("seconds"))
                if "workSeconds" not in it and "seconds" in it:
                    R.warn(f"{nm}：用了 seconds，应为 workSeconds")
                if not isinstance(v, int) or not (10 <= v <= 120):
                    R.err("E_DOSE", f"{nm}：时长 {v} 秒超出 10–120")
                elif "seconds" in rng and not (rng["seconds"][0] <= v <= rng["seconds"][1]):
                    R.warn(f"{nm}：时长 {v} 秒超出推荐 {rng['seconds']}")
            if isinstance(sets, int) and not (rng["sets"][0] <= sets <= rng["sets"][1]) and b.get("type") != "circuit":
                R.warn(f"{nm}：组数 {sets} 超出推荐 {rng['sets']}")
            rest = it.get("restSeconds")
            if not isinstance(rest, int) or not (0 <= rest <= 180):
                R.err("E_DOSE", f"{nm}：休息 {rest} 秒超出 0–180")
            if it.get("perSide") is not d["unilateral"]:
                R.err("E_SIDE", f"{nm}：perSide 应为 {str(d['unilateral']).lower()}")
            for c in d["cautions"]:
                if c in avoid:
                    R.err("E_AVOID", f"{nm} 会加重{c}部负担")
            used_equipment |= set(d["equipment"])
            if have is not None:
                for q in d["equipment"]:
                    if q not in have:
                        R.err("E_EQUIP", f"{nm} 需要{tax['equipment'][q]['zh']}")
            if scene in SCENES:
                if rule.get("forbidFloor") and tax["positions"][d["position"]].get("floor"):
                    R.err("E_SCENE", f"{nm} 需要趴/躺/跪在地上，不适合{rule.get('label', scene)}")
                if not set(d["scenes"]) & accept:
                    R.err("E_SCENE", f"{nm} 不适合场所 {scene}（动作场所 {d['scenes']}）")
    if n_items > (profile.get("limits") or {}).get("maxItems", 24):
        R.err("E_DOSE", f"动作条目 {n_items} 过多")
    declared = set(plan.get("equipment") or [])
    if used_equipment - declared:
        R.warn(f"plan.equipment 漏写 {sorted(used_equipment - declared)}")
    if isinstance(tm, int) and tm > 0:
        est = estimate_seconds(plan, drills) / 60
        R.est_minutes = round(est, 1)
        if abs(est - tm) / tm > 0.4:
            R.warn(f"估算时长约 {est:.1f} 分钟，偏离目标 {tm} 分钟超过 40%")


def format_feedback(R):
    lines = ["你上一次的输出没有通过 App 校验，问题如下："]
    lines += [f"- {e}" for e in R.errors]
    lines.append("请只改正这些问题后重新输出完整的 JSON（同样的信封格式，不要解释）。未知动作必须换成目录里的 id；不在范围的动作必须删掉或换成本 App 目录里的动作。")
    return "\n".join(lines)


# ---------------- 自测：手写样例 ----------------
def selftest(catalog):
    profiles = {k: load(os.path.join(ROOT, "profiles", f"{k}.json")) for k in ("flarelab", "hiplab", "smartfit")}
    ok_plan = {"kind": "plan", "text": "给你排了 10 分钟开胯。", "plan": {
        "schemaVersion": 1, "source": "ai", "title": "睡前开胯", "summary": "放松髋部", "goal": "relax", "scene": "home",
        "equipment": ["mat"], "level": 1, "targetMinutes": 10, "avoid": [], "notes": [], "safetyNotes": [],
        "blocks": [
            {"id": "b1", "name": "热身", "type": "warmup", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [
                {"exerciseId": "n-windshield", "mode": "reps", "sets": 1, "reps": 8, "perSide": False, "restSeconds": 10}]},
            {"id": "b2", "name": "拉伸", "type": "main", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [
                {"exerciseId": "s-figure4", "mode": "time", "sets": 1, "workSeconds": 40, "perSide": True, "restSeconds": 10},
                {"exerciseId": "s-butterfly", "mode": "time", "sets": 2, "workSeconds": 40, "perSide": False, "restSeconds": 15},
                {"exerciseId": "s-kneel-hipflex", "mode": "time", "sets": 1, "workSeconds": 40, "perSide": True, "restSeconds": 10},
                {"exerciseId": "h-reverse-clam", "mode": "reps", "sets": 2, "reps": 12, "perSide": True, "restSeconds": 20}]},
            {"id": "b3", "name": "放松", "type": "cooldown", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [
                {"exerciseId": "h-knee-hug", "mode": "time", "sets": 1, "workSeconds": 45, "perSide": False, "restSeconds": 0}]}]}}
    import copy

    def mut(f):
        p = copy.deepcopy(ok_plan)
        f(p["plan"])
        return p

    cases = [
        ("合法计划", "hiplab", ok_plan, {}, set()),
        ("代码块包裹也能解析", "hiplab", "```json\n" + json.dumps(ok_plan, ensure_ascii=False) + "\n```", {}, set()),
        ("ask", "hiplab", {"kind": "ask", "text": "在家还是办公室？", "options": ["在家", "办公室"]}, {}, set()),
        ("reply", "hiplab", {"kind": "reply", "text": "建议先就医。"}, {}, set()),
        ("不是 JSON", "hiplab", "好的，给你排一个计划", {}, {"E_JSON"}),
        ("kind 错", "hiplab", {"kind": "chat", "text": "x"}, {}, {"E_JSON"}),
        ("编造 id", "hiplab", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "burpee", "mode": "reps", "sets": 1, "reps": 10, "perSide": False, "restSeconds": 10})), {}, {"E_UNKNOWN"}),
        ("越界：开胯 App 用胸部动作", "hiplab", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "h-incline-pushup", "mode": "reps", "sets": 2, "reps": 10, "perSide": False, "restSeconds": 30})), {}, {"E_SCOPE"}),
        ("perSide 错", "hiplab", mut(lambda p: p["blocks"][1]["items"][0].update(perSide=False)), {}, {"E_SIDE"}),
        ("单腿臀桥 perSide=true 合法", "hiplab", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "glute-max-A", "mode": "reps", "sets": 2, "reps": 8, "perSide": True, "restSeconds": 20})), {}, set()),
        ("次数超限", "hiplab", mut(lambda p: p["blocks"][1]["items"][3].update(reps=40)), {}, {"E_DOSE"}),
        ("时长超限", "hiplab", mut(lambda p: p["blocks"][1]["items"][0].update(workSeconds=150)), {}, {"E_DOSE"}),
        ("mode 不一致", "hiplab", mut(lambda p: p["blocks"][1]["items"][0].update(mode="reps", reps=10)), {}, {"E_DOSE"}),
        ("组数 0", "hiplab", mut(lambda p: p["blocks"][1]["items"][1].update(sets=0)), {}, {"E_DOSE"}),
        ("热身在放松后", "hiplab", mut(lambda p: p["blocks"].append(copy.deepcopy(p["blocks"][0]))), {}, {"E_ORDER"}),
        ("膝要保护却选了含膝动作", "hiplab", mut(lambda p: p.update(avoid=["膝"])), {}, {"E_AVOID"}),
        ("请求侧 avoid 也生效", "hiplab", ok_plan, {"avoid": ["膝"]}, {"E_AVOID"}),
        ("办公室着地动作", "hiplab", mut(lambda p: p.update(scene="office")), {"scene": "office"}, {"E_SCENE"}),
        ("缺器械：居家没有哑铃", "smartfit", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "h-db-curl", "mode": "reps", "sets": 2, "reps": 10, "perSide": False, "restSeconds": 30})), {"equipment": []}, {"E_EQUIP"}),
        ("健身房可用器械与居家动作", "smartfit", mut(lambda p: (p.update(scene="gym"), p["blocks"][1]["items"].append({"exerciseId": "quadriceps-C", "mode": "reps", "sets": 3, "reps": 10, "perSide": False, "restSeconds": 45}))), {}, set()),
        ("居家用健身房器械", "smartfit", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "quadriceps-C", "mode": "reps", "sets": 3, "reps": 10, "perSide": False, "restSeconds": 45})), {}, {"E_EQUIP", "E_SCENE"}),
        ("托马斯 App 不支持办公室", "flarelab", {"kind": "plan", "text": "x", "plan": {**ok_plan["plan"], "scene": "office", "blocks": [{"id": "b", "name": "主", "type": "main", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [{"exerciseId": "hamstrings-A", "mode": "reps", "sets": 2, "reps": 8, "perSide": True, "restSeconds": 30}]}]}}, {}, {"E_SCENE"}),
        ("缺 title / 错 goal", "hiplab", mut(lambda p: (p.pop("title"), p.update(goal="fun"))), {}, {"E_SCHEMA"}),
        ("targetMinutes 超出 profile", "hiplab", mut(lambda p: p.update(targetMinutes=90)), {}, {"E_DOSE"}),
    ]
    fails = 0
    for name, prof, reply, req, expect in cases:
        R = validate_reply(reply if isinstance(reply, str) else copy.deepcopy(reply), catalog, profiles[prof], req)
        got = {e.split()[0] for e in R.errors}
        good = (got == expect) if not expect else (expect <= got and (got - expect) <= {"E_SCENE", "E_EQUIP"})
        fails += not good
        print(f"{'✓' if good else '✗'} {name}：期望 {sorted(expect) or '通过'}，得到 {sorted(got) or '通过'}" + ("" if good else f"  {R.errors}"))
        if name == "合法计划":
            print(f"    估算 {R.est_minutes} 分钟，警告 {R.warnings}")
    print(f"自测 {len(cases) - fails}/{len(cases)} 通过")
    return fails == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=default_catalog_path())
    ap.add_argument("--profile")
    ap.add_argument("--request", default="{}")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("reply", nargs="?")
    a = ap.parse_args()
    catalog = load(a.catalog)
    if a.selftest:
        sys.exit(0 if selftest(catalog) else 1)
    R = validate_reply(open(a.reply, encoding="utf-8").read(), catalog, load(a.profile), json.loads(a.request))
    print(json.dumps(R.to_dict(), ensure_ascii=False, indent=1))
    sys.exit(0 if R.ok else 1)


if __name__ == "__main__":
    main()
