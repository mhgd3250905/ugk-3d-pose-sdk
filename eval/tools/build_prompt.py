#!/usr/bin/env python3
"""拼装系统提示词 = 通用内核（仓库 prompts/kernel.md，与 SDK 同一份）+ profile + 按 profile 筛过的紧凑目录表。

用法：python3 eval/tools/build_prompt.py --profile profiles/hiplab.json [--catalog <catalog.json>] [--out test/fixtures/golden/hiplab.md]
产物即 SDK 的金样（test/fixtures/golden/*.md），test/prompt_test.dart 断言 SDK 渲染与之逐字节一致。
也可 import：build_system_prompt(catalog, profile) -> str
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from validate import load, scope, default_catalog_path, REPO  # noqa: E402

CAT_SHORT = {"strength": "力量", "core": "核心", "cardio": "有氧", "mobility": "活动", "stretch": "拉伸"}
MUSCLE_SHORT = {"deltoids": "三角肌", "rotator-cuff": "肩袖", "triceps": "肱三头", "biceps": "肱二头", "forearms": "前臂", "serratus": "前锯肌",
                "scapular": "中下斜方", "chest": "胸", "lats": "背阔", "abs": "腹直", "obliques": "腹斜", "erectors": "竖脊",
                "hip-flexors": "髋屈", "glute-max": "臀大", "hip-abductors": "臀中", "adductors": "内收", "quadriceps": "股四",
                "hamstrings": "腘绳", "calves": "小腿", "tibialis": "胫前"}
POS_SHORT = {"standing": "站", "seated": "坐", "supine": "仰卧*", "prone": "俯*", "quadruped": "四足*", "kneeling": "跪*",
             "side_lying": "侧卧*", "support": "器械撑", "hanging": "悬垂"}
SCENE_SHORT = {"home": "家", "office": "办", "gym": "馆"}


def row(d):
    dd, r = d["defaultDose"], d["doseRange"]
    if dd["mode"] == "reps":
        dose, rng = f"{dd['sets']}×{dd['reps']}次 休{dd['restSeconds']}", f"组{r['sets'][0]}-{r['sets'][1]} 次{r['reps'][0]}-{r['reps'][1]}"
    else:
        dose, rng = f"{dd['sets']}×{dd['seconds']}秒 休{dd['restSeconds']}", f"组{r['sets'][0]}-{r['sets'][1]} 秒{r['seconds'][0]}-{r['seconds'][1]}"
    return "|".join([
        d["id"], d["name"]["zh"], CAT_SHORT[d["category"]], ",".join(MUSCLE_SHORT.get(g, g) for g in d["muscleGroups"]),
        ",".join(d["equipment"]) or "-", POS_SHORT[d["position"]], "单" if d["unilateral"] else "", str(d["level"]),
        ",".join(SCENE_SHORT[s] for s in d["scenes"]), dose, rng, ",".join(d["cautions"]) or "-", d["purpose"],
    ])


def scene_rules_text(catalog, profile, drills):
    tax = catalog["taxonomy"]
    lines = []
    for sid, r in profile["scenes"].items():
        label = r.get("label", sid)
        if r.get("allEquipment"):
            eq = "默认全部器械都有"
        else:
            eq = "默认有 " + "、".join(f"{q}（{tax['equipment'][q]['zh']}）" for q in r.get("assumedEquipment", [])) if r.get("assumedEquipment") else "默认没有器械"
        acc = "、".join(SCENE_SHORT[s] for s in r.get("acceptDrillScenes", [sid]))
        extra = "；不能用着地体位（体位带 * 的：仰卧/俯/四足/跪/侧卧）" if r.get("forbidFloor") else ""
        lines.append(f"   - {sid}（{label}）：只用「场所」列含「{acc}」的动作；{eq}{extra}。")
    missing = [s for s in ("home", "office", "gym") if s not in profile["scenes"]]
    if missing:
        lines.append(f"   - 本 App 不支持场所：{'、'.join({'home': '居家', 'office': '办公室', 'gym': '健身房'}[s] for s in missing)}。用户在这些场所时，说明本 App 不覆盖，不要硬排。")
    used = {q for d in drills for q in d["equipment"]}
    eq_legend = "、".join(f"{k}={v['zh']}" for k, v in tax["equipment"].items() if k in used)
    lines.append(f"   - 器械 id：{eq_legend}。")
    return "\n".join(lines)


def build_system_prompt(catalog, profile, kernel_path=None):
    kernel = open(kernel_path or os.path.join(REPO, "prompts", "kernel.md"), encoding="utf-8").read()
    drills = scope(catalog, profile)
    v = profile.get("vars", {})
    labels = {"home": "居家", "office": "办公室", "gym": "健身房"}
    rules = "\n".join(f"- {r}" for r in profile.get("rules", []))
    subs = {
        "appName": profile["appName"],
        "defaultMinutes": v.get("defaultMinutes", "15"),
        "defaultLevel": v.get("defaultLevel", "1"),
        "defaultSceneLabel": labels.get(profile.get("defaultScene", "home"), "居家"),
        "cautions": "、".join(catalog["taxonomy"]["cautions"]),
        "sceneRules": scene_rules_text(catalog, profile, drills),
        "sceneIds": " / ".join(profile["scenes"].keys()),
        "sceneEnum": "|".join(profile["scenes"].keys()),
        "goalEnum": "|".join(profile.get("goals", [])),
        "focus": "\n".join(f"- {x}" for x in profile.get("focus", "").split("\n") if x.strip()),
        "rules": rules,
        "drillCount": str(len(drills)),
        "table": "\n".join(row(d) for d in drills),
    }
    for k, val in subs.items():
        kernel = kernel.replace("{{" + k + "}}", val)
    assert "{{" not in kernel, "提示词里还有未替换的变量"
    return kernel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=default_catalog_path())
    ap.add_argument("--profile", required=True)
    ap.add_argument("--out")
    a = ap.parse_args()
    p = build_system_prompt(load(a.catalog), load(a.profile))
    if a.out:
        os.makedirs(os.path.dirname(a.out), exist_ok=True)
        open(a.out, "w", encoding="utf-8").write(p)
        print(f"写入 {a.out}：{len(p)} 字")
    else:
        print(p)


if __name__ == "__main__":
    main()
