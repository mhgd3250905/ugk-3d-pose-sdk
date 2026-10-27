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
  python3 eval/tools/validate.py --profile profiles/hiplab.json reply.json [--request '{"scene":"office"}'] [--catalog <catalog.json>]
  python3 eval/tools/validate.py --selftest
（--catalog 默认用仓库内快照 test/fixtures/pose-hub-catalog.json）
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # eval/
REPO = os.path.dirname(ROOT)          # 仓库根：profiles/、prompts/kernel.md、目录快照都以仓库为唯一来源
PROFILES_DIR = os.path.join(REPO, "profiles")

LIMITS = {"sets": (1, 6), "reps": (1, 30), "workSeconds": (10, 120), "restSeconds": (0, 180), "rounds": (1, 6), "restBetweenRoundsSeconds": (0, 300)}
BLOCK_TYPES = {"warmup", "main", "circuit", "cooldown"}
GOALS = {"relax", "mobility", "strength", "core", "fullbody", "warmup", "cooldown"}
SCENES = {"home", "office", "gym"}
SWITCH_SIDE_S, TRANSITION_S, PREP_S = 5, 15, 10
DEFAULT_SCENE_RULES = {
    "home": {"acceptDrillScenes": ["home"]},
    "office": {"acceptDrillScenes": ["office"], "forbidFloor": True},
    "gym": {"acceptDrillScenes": ["gym", "home"]},
}


def load(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def default_catalog_path():
    for p in (os.path.join(REPO, "test", "fixtures", "pose-hub-catalog.json"),
              os.path.join(REPO, "..", "gh-3D-Pose-Hub", "catalog", "catalog.json")):
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
        self.errors, self.warnings, self.issues = [], [], []
        self.unknown_ids, self.scope_ids = [], []
        self.reply = None
        self.est_minutes = None

    def err(self, code, msg, path=None, expected=None, actual=None):
        self.errors.append(f"{code} {msg}")
        self.issues.append({"path": path or "arguments", "code": code, "expected": expected or "", "actual": actual or "", "message": msg})

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


def _whole_int(v):
    """与 Dart PlanCodec 同口径：int 或整值 float（3.0）→ int；bool、非整值、非数字 → None。"""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return None


def validate_plan(plan, catalog, profile, request, R, tool=False):
    """tool=True（工具版 show_plan）：同一动作在整个计划里重复 = E_DUP 错误（同块、跨块都算）。"""
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
    if _whole_int(plan.get("level")) not in (1, 2, 3):
        S("level 必须是 1/2/3")
    if tool:
        # 与 Dart ToolGate 同口径：本轮明确给出的水平 / 时长为准，冲突打回重交（只判不修）。
        for key, rk, what in (("level", "level", "水平"), ("targetMinutes", "minutes", "时长")):
            v, want = _whole_int(plan.get(key)), request.get(rk)
            if want is not None and v is not None and v != want:
                R.err("E_CONTEXT", f"计划{what}与本轮条件不符", key, f"{want}（本轮条件）", str(v))
    tm = _whole_int(plan.get("targetMinutes"))
    lo, hi = (profile.get("limits") or {}).get("minutes", [3, 60])
    if tm is None:
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
    # Unknown equipment means bodyweight. Neither the model's plan declaration
    # nor the venue provides evidence that the user owns any equipment.
    have = set(request.get("equipment") or [])
    accept = set(rule.get("acceptDrillScenes") or [scene])
    blocks = plan.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        S("计划没有任何训练块")
        return
    used_equipment = set()
    saw_cool = False
    n_items = 0
    first_at = {}
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
        for ii, it in enumerate(items):
            P = f"blocks[{bi}].items[{ii}]"
            n_items += 1
            if not isinstance(it, dict):
                S(f"「{name}」里有非对象条目")
                continue
            i = it.get("exerciseId")
            d = drills.get(i)
            if d is None:
                R.err("E_UNKNOWN", f"未知动作 ID：{i}", P + ".exerciseId", "本 App 动作目录里的 id", str(i))
                R.unknown_ids.append(str(i))
                continue
            nm = f"{d['name']['zh']}（{i}）"
            if not in_scope(d, profile):
                R.err("E_SCOPE", f"{nm} 不在本 App 的动作范围", P + ".exerciseId", "本 App 动作目录里的 id", i)
                R.scope_ids.append(i)
            if tool:
                if i in first_at:
                    R.err("E_DUP", "同一动作在计划里重复出现", P + ".exerciseId", "每个动作只出现一次（多做请加 sets）", f"{i}（与 {first_at[i]} 重复）")
                else:
                    first_at[i] = P
            elif i in seen:
                R.warn(f"「{name}」里重复了 {nm}")
            seen.add(i)
            mode = it.get("mode")
            if mode not in ("reps", "time"):
                S(f"{nm}：mode 必须是 reps/time")
            elif mode != d["defaultDose"]["mode"]:
                R.err("E_DOSE", f"{nm}：mode 应为 {d['defaultDose']['mode']}（目录剂量单位）", P + ".mode", d['defaultDose']['mode'], mode)
            sets = it.get("sets")
            if not isinstance(sets, int) or not (1 <= sets <= 6):
                R.err("E_DOSE", f"{nm}：组数 {sets} 超出 1–6", P + ".sets", "1–6", str(sets))
            rng = d["doseRange"]
            if mode == "reps":
                v = it.get("reps")
                if not isinstance(v, int) or not (1 <= v <= 30):
                    R.err("E_DOSE", f"{nm}：次数 {v} 超出 1–30", P + ".reps", "1–30", str(v))
                elif "reps" in rng and not (rng["reps"][0] <= v <= rng["reps"][1]):
                    R.warn(f"{nm}：次数 {v} 超出推荐 {rng['reps']}")
            elif mode == "time":
                v = it.get("workSeconds", it.get("seconds"))
                if "workSeconds" not in it and "seconds" in it:
                    R.warn(f"{nm}：用了 seconds，应为 workSeconds")
                if not isinstance(v, int) or not (10 <= v <= 120):
                    R.err("E_DOSE", f"{nm}：时长 {v} 秒超出 10–120", P + ".workSeconds", "10–120", str(v))
                elif "seconds" in rng and not (rng["seconds"][0] <= v <= rng["seconds"][1]):
                    R.warn(f"{nm}：时长 {v} 秒超出推荐 {rng['seconds']}")
            if isinstance(sets, int) and not (rng["sets"][0] <= sets <= rng["sets"][1]) and b.get("type") != "circuit":
                R.warn(f"{nm}：组数 {sets} 超出推荐 {rng['sets']}")
            rest = it.get("restSeconds")
            if not isinstance(rest, int) or not (0 <= rest <= 180):
                R.err("E_DOSE", f"{nm}：休息 {rest} 秒超出 0–180", P + ".restSeconds", "0–180", str(rest))
            if it.get("perSide") is not d["unilateral"]:
                R.err("E_SIDE", f"{nm}：perSide 应为 {str(d['unilateral']).lower()}", P + ".perSide", str(d['unilateral']).lower(), json.dumps(it.get("perSide")))
            for c in d["cautions"]:
                if c in avoid:
                    R.err("E_AVOID", f"{nm} 会加重{c}部负担", P + ".exerciseId", f"注意列不含「{c}」的动作", i)
            used_equipment |= set(d["equipment"])
            if have is not None:
                for q in d["equipment"]:
                    if q not in have:
                        R.err("E_EQUIP", f"{nm} 需要{tax['equipment'][q]['zh']}", P + ".exerciseId")
            if scene in SCENES:
                if rule.get("forbidFloor") and tax["positions"][d["position"]].get("floor"):
                    R.err("E_SCENE", f"{nm} 需要趴/躺/跪在地上，不适合{rule.get('label', scene)}", P + ".exerciseId")
                if not set(d["scenes"]) & accept:
                    R.err("E_SCENE", f"{nm} 不适合场所 {scene}（动作场所 {d['scenes']}）", P + ".exerciseId")
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
    if any("不完整" in e or "没有 JSON" in e for e in R.errors):
        lines.append("（上次输出被截断了：少想一点，直接输出紧凑的 JSON，不要换行缩进。）")
    lines.append("请只改正这些问题后重新输出完整的 JSON（同样的信封格式，不要解释）。未知动作必须换成目录里的 id；不在范围的动作必须删掉或换成本 App 目录里的动作。")
    return "\n".join(lines)


# ---------------- 工具版门禁（与 SDK lib/src/tools/tool_gate.dart 同口径；只判不修） ----------------
TOOL_NAMES = ("show_actions", "show_plan")
MAX_ACTIONS = 6
DEFAULT_CANARY = "UGK-CANARY-7F3K9Q"
FIX = {
    "E_CONTEXT": "level / targetMinutes 改成本轮条件给出的值（expected），并按新时长调整动作与组数",
    "E_JSON": "参数必须是合法 JSON（检查引号、逗号、括号是否成对），重新提交完整参数",
    "E_TOOL": "每次只用一个工具（show_actions 看动作 / show_plan 开练），或只写文字",
    "E_SCHEMA": "按工具参数 schema 补齐 / 删除 / 改正该字段（show_plan 参数顶层就是计划，不要包在 plan 里）",
    "E_UNKNOWN": "换成参数 enum 白名单里的动作 id，逐字拷贝",
    "E_SCOPE": "换成参数 enum 白名单里的动作 id，逐字拷贝",
    "E_DOSE": "按目录「默认」列单位与范围改剂量：次 → mode=reps 填 reps；秒 → mode=time 填 workSeconds",
    "E_SIDE": "单侧动作 perSide=true，其余 false",
    "E_AVOID": "换成「注意」列不含该部位的动作，或删掉这一项",
    "E_DUP": "删掉重复项；同一动作要多做就加 sets",
    "E_EQUIP": "换成用户已有器械或徒手的动作",
    "E_SCENE": "换成适合该场所的动作，scene 填用户场所",
    "E_ORDER": "热身块放在最前，放松块放在最后",
}


class ToolResult(Result):
    def __init__(self):
        super().__init__()
        self.tool = None
        self.text = ""
        self.leaked = False

    @property
    def ok(self):
        return not self.leaked and not self.errors

    def feedback(self, remaining=None):
        if self.ok:
            return json.dumps({"ok": True, "shown": True}, ensure_ascii=False)
        d = {"ok": False}
        if remaining is not None:
            d["remainingAttempts"] = remaining
        d["errors"] = [{**i, "fix": FIX.get(i["code"], "按期望改正")} for i in self.issues]
        d["instruction"] = "逐条改完后重新调用同一个工具，提交完整参数；不要向用户解释这些错误。"
        return json.dumps(d, ensure_ascii=False)

    def to_dict(self):
        return {"ok": self.ok, "tool": self.tool, "leaked": self.leaked, "errors": self.errors, "issues": self.issues,
                "warnings": self.warnings, "unknownIds": self.unknown_ids, "scopeIds": self.scope_ids, "estMinutes": self.est_minutes}


def _type(v):
    return "缺失" if v is None else {str: "string", bool: "boolean", int: "number", float: "number", list: "array", dict: "object"}.get(type(v), type(v).__name__)


def _decoded_has(raw, needle):
    """参数 JSON 解码后的任一字符串（键或值）含 needle：防 \\u0055GK-… 转义绕过暗号检测。"""
    try:
        v = json.loads(raw)
    except Exception:
        return False

    def walk(x):
        if isinstance(x, str):
            return needle in x
        if isinstance(x, list):
            return any(walk(i) for i in x)
        if isinstance(x, dict):
            return any(walk(k) or walk(i) for k, i in x.items())
        return False
    return walk(v)


def validate_tool_turn(text, tool_calls, catalog, profile, request=None, canary=DEFAULT_CANARY):
    """text：模型文字；tool_calls：[{"name":..., "arguments": "<json 字符串>"}]（OpenAI function 格式也可）。"""
    R = ToolResult()
    request = request or {}
    text = text or ""
    calls = [{"name": (c.get("function") or c).get("name") or "", "arguments": (c.get("function") or c).get("arguments") or ""} for c in (tool_calls or [])]
    if canary and (canary in text or any(canary in c["arguments"] or canary in c["name"] or _decoded_has(c["arguments"], canary) for c in calls)):
        R.leaked = True
        return R
    R.text = text.strip()
    if not calls:
        if not R.text:
            R.err("E_TOOL", "回复为空", "content", "一句文字，或文字 + 一个工具", "空")
        return R
    R.tool = calls[0]["name"]
    if len(calls) > 1:
        R.err("E_TOOL", "一次回复只能调用一个工具", "tool_calls", "0 或 1 个工具调用", f"{len(calls)} 个：{', '.join(c['name'] for c in calls)}")
    drills = {d["id"]: d for d in catalog["drills"]}
    white = {d["id"] for d in scope(catalog, profile)}
    for k, c in enumerate(calls):
        n0 = len(R.issues)
        if c["name"] not in TOOL_NAMES:
            R.err("E_TOOL", f"没有工具「{c['name']}」", f"tool_calls[{k}].name", "show_actions / show_plan", c["name"])
        else:
            try:
                args = json.loads(c["arguments"])
            except Exception as e:
                R.err("E_JSON", f"参数不是合法 JSON：{e}", "arguments", "合法 JSON 对象", c["arguments"][:80])
                args = None
            if args is not None and not isinstance(args, dict):
                R.err("E_SCHEMA", "参数必须是 JSON 对象", "arguments", "object", _type(args))
            elif isinstance(args, dict) and c["name"] == "show_actions":
                _check_actions(args, drills, white, request, R)
            elif isinstance(args, dict) and len(args) == 1 and isinstance(args.get("plan"), dict):
                R.err("E_SCHEMA", "参数多包了一层 plan", "plan", "顶层直接是 TrainingPlan 字段（schemaVersion、title、blocks…）", '{"plan": {...}}')
            elif isinstance(args, dict):
                R.reply = {"kind": "plan", "plan": args}
                validate_plan(args, catalog, profile, request, R, tool=True)
        if len(calls) > 1:
            for i in R.issues[n0:]:
                i["path"] = f"tool_calls[{k}].{i['path']}" if not i["path"].startswith("tool_calls") else i["path"]
    return R


def _check_actions(args, drills, white, request, R):
    for k in args:
        if k != "items":
            R.err("E_SCHEMA", f"多余字段 {k}", k, "只有 items", k)
    items = args.get("items")
    if not isinstance(items, list):
        R.err("E_SCHEMA", "缺少 items" if items is None else "items 必须是数组", "items", "array", _type(items))
        return
    if not (1 <= len(items) <= MAX_ACTIONS):
        R.err("E_SCHEMA", "items 数量不对", "items", f"1–{MAX_ACTIONS} 个", f"{len(items)} 个")
    avoid = set(request.get("avoid") or [])
    first = {}
    for i, it in enumerate(items):
        p = f"items[{i}]"
        if not isinstance(it, dict):
            R.err("E_SCHEMA", "动作项必须是对象", p, "object", _type(it))
            continue
        for k in it:
            if k not in ("actionId", "note"):
                R.err("E_SCHEMA", f"看动作不带剂量或其他字段：{k}", f"{p}.{k}", "actionId 与可选 note", k)
        if it.get("note") is not None and not isinstance(it.get("note"), str):
            R.err("E_SCHEMA", "note 必须是字符串", f"{p}.note", "string", _type(it.get("note")))
        a = it.get("actionId")
        if not isinstance(a, str) or not a:
            R.err("E_SCHEMA", "缺少 actionId" if a is None else "actionId 必须是字符串", f"{p}.actionId", "白名单动作 id", _type(a))
            continue
        d = drills.get(a)
        if d is None:
            R.err("E_UNKNOWN", f"未知动作 ID：{a}", f"{p}.actionId", "本 App 动作目录里的 id", a)
            R.unknown_ids.append(a)
            continue
        if a not in white:
            R.err("E_SCOPE", f"{d['name']['zh']}（{a}）不在本 App 的动作范围", f"{p}.actionId", "本 App 动作目录里的 id", a)
            R.scope_ids.append(a)
        if a in first:
            R.err("E_DUP", "动作重复", f"{p}.actionId", "每个 id 只出现一次", f"{a}（与 items[{first[a]}] 重复）")
        else:
            first[a] = i
        for c in d["cautions"]:
            if c in avoid:
                R.err("E_AVOID", f"{d['name']['zh']}（{a}）会加重{c}部负担（用户要保护）", f"{p}.actionId", f"注意列不含「{c}」的动作", a)


# ---------------- 自测：手写样例 ----------------
def load_profiles():
    return {k: load(os.path.join(PROFILES_DIR, f"{k}.json")) for k in ("flarelab", "hiplab", "smartfit")}


def selftest_cases():
    """25 个手写样例：(名称, profile, 回复, 请求, 期望错误分类)。export_parity.py 也用它导出给 Dart 对照。"""
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
        ("缺器械：居家只有瑜伽垫没有哑铃", "smartfit", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "h-db-curl", "mode": "reps", "sets": 2, "reps": 10, "perSide": False, "restSeconds": 30})), {"equipment": ["mat"]}, {"E_EQUIP"}),
        ("健身房可用器械与居家动作", "smartfit", mut(lambda p: (p.update(scene="gym"), p["blocks"][1]["items"].append({"exerciseId": "quadriceps-C", "mode": "reps", "sets": 3, "reps": 10, "perSide": False, "restSeconds": 45}))), {"equipment": ["mat", "leg-extension-machine"]}, set()),
        ("居家用健身房器械", "smartfit", mut(lambda p: p["blocks"][1]["items"].append({"exerciseId": "quadriceps-C", "mode": "reps", "sets": 3, "reps": 10, "perSide": False, "restSeconds": 45})), {}, {"E_EQUIP", "E_SCENE"}),
        ("托马斯 App 不支持办公室", "flarelab", {"kind": "plan", "text": "x", "plan": {**ok_plan["plan"], "scene": "office", "blocks": [{"id": "b", "name": "主", "type": "main", "rounds": 1, "restBetweenRoundsSeconds": 0, "items": [{"exerciseId": "hamstrings-A", "mode": "reps", "sets": 2, "reps": 8, "perSide": True, "restSeconds": 30}]}]}}, {}, {"E_SCENE"}),
        ("缺 title / 错 goal", "hiplab", mut(lambda p: (p.pop("title"), p.update(goal="fun"))), {}, {"E_SCHEMA"}),
        ("targetMinutes 超出 profile", "hiplab", mut(lambda p: p.update(targetMinutes=90)), {}, {"E_DOSE"}),
    ]
    # These historical cases deliberately use the same mat-based plan. The mat
    # is an explicit test precondition, never inferred from the model's plan.
    cases = [(name, profile, reply, {"equipment": ["mat"], **request}, expect)
             for name, profile, reply, request, expect in cases]
    # A separate case retains truly unknown availability even though the plan
    # itself declares a mat; the declaration must not prove ownership.
    cases.append(("器械未知：计划声明垫子不能证明拥有", "hiplab", ok_plan, {}, {"E_EQUIP"}))
    return cases


def selftest(catalog):
    import copy
    profiles = load_profiles()
    cases = selftest_cases()
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
