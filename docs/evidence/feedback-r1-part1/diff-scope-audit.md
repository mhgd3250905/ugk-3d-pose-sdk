# feedback-r1-part1 合入前差异核验

审计对象为不可变提交 `a451760327fd885465c44773ff0744b2b77f3e31`，不是以工作树目录名称判断来源。审计时间：2026-10-26。

**结论：未发现夹带 trainer-liquid-glass 工作树的液态玻璃改动，无需为此拆分提交。** 此结论针对 `main...a451760` 的差异，不表示仓库历史中从未存在过玻璃实现。

## 比较基线

- 本地 `main`：`ac9b31f1d3f32edaa5c461b95d2eadc71b54e88a`。
- 当前 `origin/main`：`ac9b31f1d3f32edaa5c461b95d2eadc71b54e88a`。
- `git merge-base main a451760`：同上。
- `git log main..a451760`：仅 `a451760 feat: address device feedback r1 part 1` 一个提交。
- 合并执行前仍应由主 Agent 使用其最终 fetch 结果核对远端未改变；本报告不替代该最终 CAS/快进检查。

## 差异范围

总计 278 个文件：219 个原封面资源、10 个核验/截图证据、16 个运行文件、10 个测试、23 个文档/清单/工具。运行文件均可映射到六项反馈：

| 反馈项 | 运行路径 | 实际改动 |
| --- | --- | --- |
| 1 无感媒体 | `pose_hub_media_preparation.dart`、新增 `pose_hub_media_prefetcher.dart`、`pose_hub_pack_media.dart`、`pose_hub_pack_image.dart`、`trainer_player.dart`、`ugk_trainer.dart` | 随包站位图、180ms普通透明度过渡、两路优先队列、取消屏障、计时/播报解耦、自定义媒体请求接入 |
| 2 动作库 | `pose_hub_action_browser.dart` | 两列中文图文、组合筛选、排除待补项、中文名称/别名查询 |
| 3 单动作训练 | `pose_hub_action_browser.dart`、`trainer_player.dart` | 直接共享训练播放器、语义剂量/实际场景/会话估时、原详情入口仅保留兼容 wrapper |
| 4/5 套路卡 | `packages/ugk_coach_ui/lib/src/plan_card.dart` | 22px留白、5px间隔、弱化副信息、首行对齐、288px透明人物卡及共享飞行动画几何 |
| 6 AI 参数 | `agent_prompt.dart`、`coach_agent.dart`、`coach_conversation_controller.dart`、新增 `training_parameters.dart`、生成的 `prompts.g.dart`、`ask_user.dart`、UI的 `models.dart` / `question_bubble.dart` | 单轮form、参数推断/门禁、回答/跳过API及兼容呈现 |

清单仅升三个 minor、更新 trainer 对 coach 的新 tag/version 约束并声明站位图目录；没有新增运行依赖。唯一跟踪的 example lock 变化仅 coach `0.6.2→0.7.0`、trainer `0.4.2→0.5.0` 两个版本值。

219 个新增站位 WebP 通过直接读取 `a451760` 的 Git 对象逐项计算 SHA256，与该提交中未改变的 v3 catalog `files.cover.sha256` 全部相同；总计 **5,316,554 bytes**。这些是原封面的离线打包，不是液态玻璃素材或本次首帧重导出结果。

## 液态玻璃隔离证据

以下路径在 `main...a451760` 中 **无差异**：

- trainer 的 `trainer_theme.dart`、`trainer_surface.dart`、`trainer_stage.dart`。
- coach_ui 的 `theme.dart`、`primitives.dart`。
- `packages/ugk_trainer/shaders/`（包括既有 `packed_alpha.frag`）。
- `packages/ugk_trainer/android/`、`ios/`、`assets/pose_hub_player/`。

对该不可变提交的运行源与三包清单执行 `git grep`，`liquid_glass`、`TrainerGlass`、`BackdropFilter`、`ImageFilter.blur`、`refraction`、`optical` 均无命中。对新增 Dart/YAML/shader/JS 行的同类扫描也未发现材质实现。

`packed_alpha.frag` 和原 native composed-first-frame 协议属于已有透明视频合成，未改动，不能因为“alpha/shader”字样误判成液态玻璃。`AnimatedOpacity` 的180ms媒体过渡也仅为用户要求的站位图/视频切换。

历史 README/CHANGELOG 中玻璃版本的记录和工作树路径仍会出现相关词，这些为历史来源说明；差异中没有重新引入其运行代码、依赖、主题 token 或光学滤镜。

## 执行边界

本次仅做只读 Git 对象/差异/资源哈希核验并新增此报告，没有修改源码、运行设备、reset、清理、stash、commit、push 或创建 tag。动作库交接 C① 的新增视觉补齐由主 Agent 单独实现和验证，不属于本报告对 `a451760` 的既有差异结论。
