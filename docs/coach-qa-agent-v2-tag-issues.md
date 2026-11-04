# v2 评测里发现的 ai-tags 标签问题（只列出，没改 Pose-Hub）

来源：Pose-Hub `codex/ai-action-tags` @5d17c24 `catalog/ai-tags/actions/*.json`，第二轮 40 场景真实模型评测。

| # | 动作 id | 名称 | 字段 | 现在 | 建议改成 | 影响 |
|---|---|---|---|---|---|---|
| 1 | h-forward-lunge | 前跨步弓步蹲 | impact | low | none（没有腾空落地） | 「不能出声」时被过滤；文字说「不跳」时被当成矛盾 |
| 2 | h-lateral-step-lunge | 侧跨步弓步蹲 | impact | low | none | 同上 |
| 3 | h-chair-step-up | 椅子上步 | impact | low | none | 同上 |
| 4 | h-band-stepout | 弹力带侧向步出抗旋转 | impact | low | none | 同上 |
| 5 | obliques-A | 熊爬穿腿 | impact | low | none（膝盖离地爬行，不跳） | 同上 |
| 6 | forearms-C | 壶铃倒握行走 | impact / space | low / in-place | none / walking | 走动类应标 walking，场地小时才能排除 |
| 7 | n-pelvis-circle | 站姿骨盆画圈 | primaryMuscles | abs, obliques, erectors | 清空（或移到 secondaryMuscles）；它是 mobility 活动度动作 | 被当成练腹、练背的主力动作推荐 |
| 8 | lats-A | 坐姿撑地抬臀 | primaryMuscles | lats | scapular（肩带下压）、triceps；lats 放 secondary | 严格徒手练背时成了唯一的「主练背」动作，说服力弱 |
| 9 | h-sleeper-stretch | — | 缺标签 | 无 ai-tags 文件 | 补标签 | 走目录回退，字段粗 |
| 10 | scapular-C | — | 缺标签 | 无 ai-tags 文件 | 补标签 | 同上 |

另外（不是 ai-tags 字段）：`h-step-jack` 中文名「低冲击开合跳」含「跳」，实际是踏步开合，容易和「不跳」的说法打架，可以考虑改名「踏步开合」。

## 2026-11-04：肩痛仍推荐上斜俯卧撑

SF `ugk_trainer-v0.7.1` 实测原话为「肩痛练胸」，安全追问后选择「抬手或发力时刺痛、有卡住感」。当轮已正确填入 `intent=safety`、`avoid_joints=[shoulder]`，仍推荐了 `h-incline-pushup`（扶凳上斜俯卧撑）。

固定来源 `5d17c24af859d905dbbdee4b1d623b99881ac618` 的原始标签把该动作标为 `jointStress.shoulder=low`、`jointStress.wrist=low`、`movementPattern=[push-horizontal]`、`difficulty=1`，并标为 beginner suitable，没有提供“肩部出现发力刺痛/卡住时适用”的依据。`QaFinder` 的既有规则只排除受限关节负担 moderate 以上，因此这个 low 动作仍在候选，结构化范围检查通过不是伤痛安全验收。

这不是漏填避开肩部。原 SOP 却写了“候选已避开受伤部位”，同时鼓励安全题附动作，模型据此把“low / 入门”误当作可试练。本批改 SOP：确认刺痛/卡住等危险信号后停止诱发症状的训练，不以 low 作为可练依据，允许只回答停训和专业评估建议、不附卡片；不添加按语言匹配的脚本，也不改变 jointStress 阈值。

标签侧仅记待人工复核：正常关节的负担分级不能直接表达伤痛禁忌，需 Pose-Hub 维护者确认是否及如何补充肩痛适用/禁忌信息；本批不把 shoulder 擅自改成 moderate，不修改任何标签或 Pose-Hub 文件。测试中的最小标签样本仅重现上述原字段，不是修订标签，也不进入 SDK 动作包。

证据：`E:/AII-3D/3D-Sport-AI/deliveries/sdk-pin-v0.7.1-9dd9316-plus18-20261104/REPORT.md` 及该交付目录的 `live-chat/conversations.md`（`shoulder-pain-chest`）。离线回归验证完整 SOP 会传给模型、风险答案保持安全流程且可不交动作卡；模型实际遵守程度以本批真实模型复测为准。
