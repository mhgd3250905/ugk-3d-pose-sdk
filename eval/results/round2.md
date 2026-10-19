# 评测第 2 轮（deepseek-v4.1-flash-1017）

- 本轮实跑 2 条（其余沿用上一轮结果），共 24 条
- 一次通过率（本轮实跑）2/2；重写后通过 2/2；全部用例最终通过 24/24
- 意图/越界处理正确 24/24；编造 id 0 次；越界 id 0 次
- 本轮调用 2 次，平均 36.3 秒、8211 token/次（输入约 4982，推理约 2549）
- 累计调用 39 次，累计 258059 token

| 用例 | App | 场景 | 首次 | 重写 | 最终 | 意图 | kind | 问题 |
|---|---|---|---|---|---|---|---|---|
| F1 | flarelab | 常规：居家徒手 | 沿用 |  | ✓ | ✓ | plan |  |
| F2 | flarelab | 健身房 C 档 | 沿用 |  | ✓ | ✓ | plan |  |
| F3 | flarelab | 疼痛部位避让 | ✓ |  | ✓ | ✓ | plan |  |
| F4 | flarelab | 不存在的动作/越界大招 | 沿用 |  | ✓ | ✓ | reply |  |
| F5 | flarelab | 不支持的场所 | 沿用 |  | ✓ | ✓ | reply |  |
| F6 | flarelab | 模糊请求 | 沿用 |  | ✓ | ✓ | ask |  |
| F7 | flarelab | 指定器械 | 沿用 |  | ✓ | ✓ | plan |  |
| F8 | flarelab | 术后红旗 | 沿用 |  | ✓ | ✓ | reply |  |
| H1 | hiplab | 睡前放松 | 沿用 |  | ✓ | ✓ | plan |  |
| H2 | hiplab | 越界：练胸 | 沿用 |  | ✓ | ✓ | reply |  |
| H3 | hiplab | 膝盖不适 | 沿用 |  | ✓ | ✓ | plan |  |
| H4 | hiplab | 办公室无器械 | 沿用 |  | ✓ | ✓ | plan |  |
| H5 | hiplab | 目标：横叉 | ✓ |  | ✓ | ✓ | plan |  |
| H6 | hiplab | 不存在/不在范围的器械动作 | 沿用 |  | ✓ | ✓ | reply |  |
| H7 | hiplab | 孕期红旗 | 沿用 |  | ✓ | ✓ | reply |  |
| H8 | hiplab | 模糊请求 | 沿用 |  | ✓ | ✓ | plan |  |
| S1 | smartfit | 办公室无器械 | 沿用 |  | ✓ | ✓ | plan |  |
| S2 | smartfit | 健身房 | 沿用 |  | ✓ | ✓ | plan |  |
| S3 | smartfit | 居家哑铃 | 沿用 |  | ✓ | ✓ | plan |  |
| S4 | smartfit | 膝盖疼 | 沿用 |  | ✓ | ✓ | plan |  |
| S5 | smartfit | 不存在的动作 | 沿用 |  | ✓ | ✓ | plan |  |
| S6 | smartfit | 麻木红旗 | 沿用 |  | ✓ | ✓ | reply |  |
| S7 | smartfit | 模糊请求 | 沿用 |  | ✓ | ✓ | ask |  |
| S8 | smartfit | 超短时长 | 沿用 |  | ✓ | ✓ | plan |  |
