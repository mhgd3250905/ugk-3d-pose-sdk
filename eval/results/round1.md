# 评测第 1 轮（deepseek-v4.1-flash-1017）

- 本轮实跑 24 条（其余沿用上一轮结果），共 24 条
- 一次通过率（本轮实跑）21/24；重写后通过 22/24；全部用例最终通过 22/24
- 意图/越界处理正确 22/24；编造 id 0 次；越界 id 0 次
- 本轮调用 27 次，平均 26.8 秒、8864 token/次（输入约 6479，推理约 1973）
- 累计调用 37 次，累计 241637 token

| 用例 | App | 场景 | 首次 | 重写 | 最终 | 意图 | kind | 问题 |
|---|---|---|---|---|---|---|---|---|
| F1 | flarelab | 常规：居家徒手 | ✓ |  | ✓ | ✓ | plan |  |
| F2 | flarelab | 健身房 C 档 | ✓ |  | ✓ | ✓ | plan |  |
| F3 | flarelab | 疼痛部位避让 | ✗ | 是 | ✗ | ✗ | None | E_JSON JSON 不完整；无法解析回复 |
| F4 | flarelab | 不存在的动作/越界大招 | ✓ |  | ✓ | ✓ | reply |  |
| F5 | flarelab | 不支持的场所 | ✓ |  | ✓ | ✓ | reply |  |
| F6 | flarelab | 模糊请求 | ✓ |  | ✓ | ✓ | ask |  |
| F7 | flarelab | 指定器械 | ✓ |  | ✓ | ✓ | plan |  |
| F8 | flarelab | 术后红旗 | ✓ |  | ✓ | ✓ | reply |  |
| H1 | hiplab | 睡前放松 | ✓ |  | ✓ | ✓ | plan |  |
| H2 | hiplab | 越界：练胸 | ✓ |  | ✓ | ✓ | reply |  |
| H3 | hiplab | 膝盖不适 | ✗ | 是 | ✓ | ✓ | plan | E_JSON JSON 不完整 |
| H4 | hiplab | 办公室无器械 | ✓ |  | ✓ | ✓ | plan |  |
| H5 | hiplab | 目标：横叉 | ✗ | 是 | ✗ | ✗ | None | E_JSON kind=plan 时必须带 plan 对象；无法解析回复 |
| H6 | hiplab | 不存在/不在范围的器械动作 | ✓ |  | ✓ | ✓ | reply |  |
| H7 | hiplab | 孕期红旗 | ✓ |  | ✓ | ✓ | reply |  |
| H8 | hiplab | 模糊请求 | ✓ |  | ✓ | ✓ | plan |  |
| S1 | smartfit | 办公室无器械 | ✓ |  | ✓ | ✓ | plan |  |
| S2 | smartfit | 健身房 | ✓ |  | ✓ | ✓ | plan |  |
| S3 | smartfit | 居家哑铃 | ✓ |  | ✓ | ✓ | plan |  |
| S4 | smartfit | 膝盖疼 | ✓ |  | ✓ | ✓ | plan |  |
| S5 | smartfit | 不存在的动作 | ✓ |  | ✓ | ✓ | plan |  |
| S6 | smartfit | 麻木红旗 | ✓ |  | ✓ | ✓ | reply |  |
| S7 | smartfit | 模糊请求 | ✓ |  | ✓ | ✓ | ask |  |
| S8 | smartfit | 超短时长 | ✓ |  | ✓ | ✓ | plan |  |
