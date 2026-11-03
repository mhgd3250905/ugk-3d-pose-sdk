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
