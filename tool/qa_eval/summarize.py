#!/usr/bin/env python3
"""汇总 tool/sim_user.dart（SIM_AGENT=v2，跑 v3 CoachQaAgent）输出的 JSONL。

用法：python3 tool/qa_eval/summarize.py out.jsonl [scenarios.json]
指标：问/不问、「第 N 个」换动作、分段、正文与卡片一致、平均调用次数、耗时（全部 / 问题轮 / 回答轮）。
原始 JSONL 不提交（含模型原文）。
"""
import json
import sys
from collections import defaultdict


def main():
    rows = [json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
    exp = {}
    if len(sys.argv) > 2:
        for s in json.load(open(sys.argv[2], encoding='utf-8')):
            for i, t in enumerate(s.get('turns_expect', []), 1):
                exp[(s['id'], i)] = {**s.get('expect', {}), **(t or {})}
    n = len(rows)
    errors = [r for r in rows if 'exception' in r or r.get('status') == 'error']
    checks = lambda r: r.get('checks') or []
    ask_bad = [r for r in rows if any(c.startswith('反问') for c in checks(r))]
    rep = [r for r in rows if str(exp.get((r['id'], r['turn']), {}).get('modify', '')).startswith('replace')]
    rep_bad = [r for r in rep if any(c.startswith('修改') for c in checks(r)) or r in errors]
    seg = [r for r in rows if exp.get((r['id'], r['turn']), {}).get('segments')]
    seg_bad = [r for r in seg if any(c.startswith('分段') for c in checks(r)) or r in errors]
    off_bad = [r for r in rows if any(c.startswith('一致') or c.startswith('矛盾') for c in checks(r))]
    ask_rows = [r for r in rows if r.get('status') == 'ask']
    ans_rows = [r for r in rows if r.get('status') not in ('ask', None) and r not in errors]
    avg = lambda xs: sum(xs) / len(xs) if xs else 0
    print(f'轮数 {n}；SDK 错误/异常 {len(errors)}')
    print(f'问/不问 {n - len(ask_bad) - len(errors)}/{n}')
    print(f'「第 N 个」换动作 {len(rep) - len(rep_bad)}/{len(rep)}')
    print(f'分段计划 {len(seg) - len(seg_bad)}/{len(seg)}')
    print(f'正文与卡片一致 {n - len(off_bad)}/{n}')
    print(f'平均调用 {avg([r.get("http", 0) for r in rows]):.2f} 次，最多 {max([r.get("http", 0) for r in rows] or [0])}')
    print(f'平均耗时 {avg([r["ms"] for r in rows]) / 1000:.1f} 秒；问题轮 {avg([r["ms"] for r in ask_rows]) / 1000:.1f}；'
          f'回答轮 {avg([r["ms"] for r in ans_rows]) / 1000:.1f}；最慢 {max([r["ms"] for r in rows] or [0]) / 1000:.1f}')
    fails = defaultdict(list)
    for r in rows:
        for c in checks(r):
            fails[c.split('：')[0]].append(f"{r['id']}#{r['turn']} {c}")
        if r in errors:
            fails['错误'].append(f"{r['id']}#{r['turn']} {r.get('exception') or r.get('issues')}")
    for k, v in fails.items():
        print(f'\n[{k}] {len(v)}')
        for line in v:
            print('  ' + line[:240])


if __name__ == '__main__':
    main()
