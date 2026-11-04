# QA v3 真实模型评测（问法集重构版）

2026-11-04。旧 v2 评测（docs/coach-qa-agent-v2.md「评测」）用的场景文件没有入库，这里按文档里记下的场景重构了一份：
`qa_v3_scenarios.json`，22 个场景、53 轮，覆盖：

- 问 / 不问（地点、器械、安全追问、记忆已知不问、「直接推荐」不问、酒店/宿舍按居家问器械）；
- 旧场景 S09（在家徒手练背 → 太难了）、S22（肩痛 → 10 分钟 → 居家 → 徒手）、S41/S42/S43、S44（日语）、S45（西语）；
- 「第 N 个」换动作 16 轮（含计划热身位编号）；范围里确实没有合格候选时如实说不换（`noneOk`，由 `qa_checks.dart` 按准入 + 同一处核对）；
- 分段计划「前半坐后半站」（`segments: [seated, standing]`，按主训练各段顺序和动作姿势核对）；
- 正文与卡片一致（`offCardMentions` 与「不跳/不躺/不用器械」矛盾检查）；改时长、再来一套。

旧基线（v2，92 轮）：问/不问 92/92；第 N 个 16/16；S09/S43/S44/S45 无候选时不硬换；S22 重试通过；平均 2.03 次调用、11.9 秒/轮（回答轮 16.7 秒）。
v3 目标：平均 ≤3 次调用、回答轮 ≤20 秒，其余不劣于旧基线。

## 运行（需要评测 key，只按原方式读取：环境变量 UGK_API_KEY）

```bash
# SDK 根目录
SIM_AGENT=v2 AI_TAGS_FILE=<SF>/assets/coach/ai-tags/actions.json \
  dart run tool/sim_user.dart tool/qa_eval/qa_v3_scenarios.json build/qa-v3-eval.jsonl smartfit
python3 tool/qa_eval/summarize.py build/qa-v3-eval.jsonl tool/qa_eval/qa_v3_scenarios.json
```

- 模型 deepseek-v4.1-flash（`SIM_MODEL` 可改），中转 https://ai.uuugk.win/v1；每次请求由 CoachQaAgent 自己带 thinking.enabled + reasoning_effort=max。
- `ONLY=S22-肩痛练胸,G01-工位分段` 只跑受影响的场景；`SIM_STUB=1` 用桩模型只验证流程（不花钱，不评估模型质量）。
- 输出 JSONL 含模型原文，放 build/，不入库。
