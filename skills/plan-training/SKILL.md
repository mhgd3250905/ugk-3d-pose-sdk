---
name: plan-training
description: 排一份能直接开练的训练计划，或修改上一份计划
---
# 排课

<!-- fast-path:start -->
## 排计划快路径
理解目标/部位、场所、器械、时长、水平和保护部位；以 App 已知条件为准，其余用系统默认值。直接从紧凑索引筛选，按默认剂量组成完整计划后 show_plan；不必先 read 技能、索引或逐条详情，也不必先 check_plan。复杂组合、需核对时长或提交失败时才可选 check_plan；修改仍提交完整新计划。
- 红旗情况只给就医建议，不排课。普通不适写入 avoid（词表：{{cautions}}），排除注意标签相交或命中禁忌的动作；safetyNotes 写不适加重就停止。
- 结构按 warmup→main/circuit→cooldown；8分钟内可1–2块。动作全计划不重复；难度不高于用户水平，单侧左右都做。
- show_plan 顶层直接填 schemaVersion=1、title（≤12字）、summary、goal（{{goals}}）、scene（{{sceneIds}}）、level、targetMinutes、blocks，按需 equipment/avoid/notes/safetyNotes，不包 plan。块填 type/items；循环块 rounds≥2、items.sets=1。
- 每项填 exerciseId/mode/sets/perSide/restSeconds；mode=reps填reps，mode=time填workSeconds，与索引一致。索引剂量 mode:组×次数或秒@休息秒；每项 perSide 严格拷贝索引：1→true、0→false，不能根据动作名称、单腿或交替做法自行猜测，剂量指每侧。拿不准用默认剂量；硬限：{{limits}}。
- equipment 填所有实际器械id，徒手用空数组；只用用户已有或场所默认器械。场所规则：
{{sceneRules}}
- 时长粗算：每组次数×3秒或workSeconds，单侧×2，加休息，换动作约15秒；按目标调整组数/动作，不靠省休息硬凑。门禁会校验，失败按返回错误修正。
<!-- fast-path:end -->

## 步骤
1. 理解需求：目标/部位、场所、器械、时长、水平、要保护的部位（以用户消息开头括号里的条件为准；没说的用默认值）。
2. 直接从系统紧凑索引选动作；只在信息不足时补查资料。
3. 按下面原则编排完整计划；复杂或被门禁打回时可选 check_plan，按错误和时长差调整。
4. 调 show_plan 交付，文字里先说理解，再说排法和理由。

## 编排原则
- 结构：热身（warmup）→ 主训练（main 或 circuit）→ 放松（cooldown），热身块不能排在放松块之后；8 分钟以内可以只有 1–2 块。
- 配比：热身和放松各约占 15–20%；10 分钟大约 5–7 个动作，20 分钟大约 8–10 个。
- 平衡：力量类兼顾推/拉、上肢/下肢、前侧/后侧；单侧动作左右都做。
- 进阶：难度不超过用户水平；入门先用默认剂量，进阶靠加组、加次数或换更难的动作，不靠缩短休息硬凑。
- 保护部位：用户说某部位疼、不舒服、有旧伤（没有红旗）→ 把部位写进 avoid（只能用：{{cautions}}），所有动作的「注意」都不能含这个部位；safetyNotes 写一句「不适加重就停止」。
- 用户点名的动作库里没有：用最接近的库内动作代替，在 notes 写「X 库里没有，用 Y 代替」；没有合适替代就纯文字说明。

## 参数规则（违反会被打回）
- 参数顶层直接是计划字段：schemaVersion=1、title（≤12 字）、summary、goal（{{goals}}）、scene（{{sceneIds}}）、level、targetMinutes、blocks，可选 equipment、avoid、notes、safetyNotes；不要再包一层 {"plan": …}。
- 每个块：type（warmup/main/circuit/cooldown）、items；循环块 rounds ≥ 2、items 的 sets 写 1。
- 每个动作：exerciseId、mode、sets、perSide、restSeconds，以及 reps（mode=reps）或 workSeconds（mode=time）。
- 剂量单位：mode 必须与动作默认剂量一致：「次」→ mode=reps 填 reps；「秒」→ mode=time 填 workSeconds。数值在动作的剂量范围内调，拿不准就用默认。
- 单侧动作 perSide=true（reps / workSeconds 指每侧），其余 false。
- 不重复：同一动作在整个计划里只出现一次，要多做就加 sets。
- 硬限：{{limits}}。
- 场所与器械：
{{sceneRules}}
  - equipment 列出所有动作用到的器械 id；用户说没器械时只用徒手或场所默认就有的器械。
- 时长估算口径：每组用时 ≈ 次数 × 约 3 秒或计时秒数，单侧 ×2，加组间休息，每换一个动作约 15 秒；check_plan 会给出实际估算。

## 多轮修改
用户在已有计划上提修改（换动作、加减时长、换部位）：在上一份计划基础上改，按需 check_plan 后用 show_plan 提交完整新计划，不要只给差异。
