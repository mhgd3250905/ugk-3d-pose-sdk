#!/usr/bin/env python3
"""导出 Python 校验器的判定，给 Dart `test/parity_test.dart` 逐例对照（评测通过率 = 线上通过率）。

内容：validate.py 自测的 24 例 + 补充规则样例（mode 与目录一致、动作 scenes 匹配计划场所），
每例记录回复、profile、请求条件、期望分类，以及 Python 实际给出的错误分类与每类条数。

用法（仓库根）：python3 eval/tools/export_parity.py [--catalog <catalog.json>] [--out test/fixtures/parity.json]
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from validate import REPO, default_catalog_path, load, load_profiles, selftest_cases, validate_reply  # noqa: E402


def rule_cases(ok):
    """补充样例：两条容易漏的错误规则各正反几例。"""
    def mut(f, base=ok):
        p = copy.deepcopy(base)
        f(p["plan"])
        return p

    def single(scene, *items):
        return mut(lambda p: (p.update(scene=scene, blocks=[{"id": "b", "name": "主", "type": "main", "rounds": 1,
                                                             "restBetweenRoundsSeconds": 0, "items": list(items)}])))

    chest_c = {"exerciseId": "chest-C", "mode": "reps", "sets": 3, "reps": 8, "perSide": True, "restSeconds": 45}
    sumo = {"exerciseId": "h-sumo-pry", "mode": "time", "sets": 1, "workSeconds": 30, "perSide": False, "restSeconds": 10}
    return [
        # mode 必须与目录剂量单位一致
        ("mode：计次动作写成计时", "hiplab",
         mut(lambda p: p["blocks"][1]["items"][3].update(mode="time", workSeconds=30)), {}, {"E_DOSE"}),
        ("mode：计时动作写成计次（含合法 reps）", "smartfit",
         mut(lambda p: p["blocks"][2]["items"][0].update(mode="reps", reps=10)), {}, {"E_DOSE"}),
        ("mode：与目录一致的计次 / 计时混排合法", "smartfit", ok, {}, set()),
        # 动作 scenes 必须匹配计划场所（健身房也接受居家动作）
        ("scenes：居家计划用健身房专属动作（器械已声明）", "smartfit", single("home", chest_c), {"equipment": ["cable"]}, {"E_SCENE"}),
        ("scenes：办公室计划用居家专属站姿动作", "smartfit", single("office", sumo), {"scene": "office"}, {"E_SCENE"}),
        ("scenes：健身房计划用健身房专属动作合法", "smartfit", single("gym", chest_c), {}, set()),
        ("scenes：健身房接受居家动作", "smartfit", single("gym", sumo), {}, set()),
        ("scenes：本轮场所为健身房、计划写居家", "smartfit", single("home", sumo), {"scene": "gym"}, {"E_SCENE"}),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=default_catalog_path())
    ap.add_argument("--out", default=os.path.join(REPO, "test", "fixtures", "parity.json"))
    a = ap.parse_args()
    catalog, profiles = load(a.catalog), load_profiles()
    st = selftest_cases()
    ok = st[0][2]
    out, bad = [], 0
    for group, cases in (("selftest", st), ("rules", rule_cases(ok))):
        for name, prof, reply, req, expect in cases:
            R = validate_reply(reply if isinstance(reply, str) else copy.deepcopy(reply), catalog, profiles[prof], req)
            cats = [e.split()[0] for e in R.errors]
            got = set(cats)
            good = (got == expect) if not expect else (expect <= got and (got - expect) <= {"E_SCENE", "E_EQUIP"})
            bad += not good
            out.append({"group": group, "name": name, "profile": prof, "reply": reply, "request": req,
                        "expect": sorted(expect), "python": {"errors": sorted(got), "counts": dict(sorted(Counter(cats).items())),
                                                            "messages": R.errors}})
    doc = {"generatedBy": "eval/tools/export_parity.py", "catalogVersion": catalog.get("version"),
           "selftestCount": len(st), "cases": out}
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print(f"写入 {os.path.relpath(a.out, REPO)}：{len(out)} 例（自测 {len(st)}），Python 与期望不符 {bad} 例")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
