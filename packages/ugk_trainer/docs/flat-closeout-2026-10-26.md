# 扁平实色版收尾 — 2026-10-26

选定运行基线：`c4d251dff93360f1fa376132dcad95a8b78fc4d1`。本轮只修正文档与版本/本地包 lock，所有生产源码、资产、shader、测试和展示入口均与该提交一致；保持 `codex/solid-layered-ui`。微拟物候选暂存 `fcda16df8feb2f5546fe7818efc40391c6140ade` 未触碰。

## 版本与交付边界

| 包 | 收尾版本 / tag | 运行变化 |
| --- | --- | --- |
| ugk_trainer | 0.3.1 / `ugk_trainer-v0.3.1` | 与选定 c4 基线一致；修正文档中两处旧材质 API 现行描述 |
| ugk_coach_ui | 0.2.1 / `ugk_coach_ui-v0.2.1` | 与选定 c4 基线一致；同步收尾、迁移和安装说明 |
| ugk_coach | 0.5.0 / 原 `ugk_coach-v0.5.0` | lib/test/pubspec 与原 tag 完全一致，不重发版本 |

旧 `ugk_trainer-v0.3.0` / `ugk_coach_ui-v0.2.0` 继续指向 c4，不移动。新 tag 绑定本收尾提交；tag 归档不等于 pub.dev 或 App 发布。main 不合入、不推送，等待开哥真机确认。

## 全库删除复核

- 全仓受控生产文件 121 个：玻璃依赖、`BackdropFilter`、`ImageFilter.blur`、`MaskFilter.blur`、旧玻璃类型/材质开关均为 **0**。根包、两个 Flutter 包及展示入口的 4 份 pubspec 无玻璃库；受控 lock 无玻璃包。
- 全库字面搜索仍能命中 CHANGELOG 的删除历史、迁移清单及测试中的禁止性断言。这些是记录和防回归检查，没有实例化玻璃功能，不伪称字面字符串也为 0。
- 唯一 shader 是 `shaders/packed_alpha.frag`：读取视频上下两半的 RGB 与 alpha，合成透明媒体；没有背景采样、折射或模糊，保留其资源与媒体测试。
- 原 `TrainerRingPainter.glowBlur` 是径向 halo 宽度计算参数，未调用实时滤镜；Morph Pulse 的环、呼吸、ripple 保持原实现。

## 本轮验证

| 检查 | 结果 |
| --- | --- |
| 根 ugk_coach 全套 `dart test --concurrency=2` | 471/471 通过 |
| ugk_trainer 全套 `flutter test --no-pub --concurrency=2` | 257/257 通过 |
| ugk_coach_ui 全套相同命令 | 33/33 通过 |
| SDK 展示入口全套相同命令 | 4/4 通过 |
| JS 播放协议 | 8/8 通过 |
| 两个 Flutter 包及展示入口静态分析 | 均无问题 |
| 根包静态分析 | 0 error，5 条未改动源码上的既有 warning，见下文 |
| 依赖 | 有 lock 的 Flutter 包和展示入口严格 lock 校验通过；展示 lock 仅将本地 trainer 版本从 0.3.0 改为 0.3.1 |
| 训练布局 | 训练/休息/换侧/结果 × 浅深 8 组，106 外框、62 缺席项一致，最大偏移 0dp |
| 截图 | 本轮重新采集 8 张软件图；8/8 PNG 摘要与 c4 已归档图相同 |
| 防闪与动画 | 中断/快速反转/降动效、语义/键盘和独立重绘回归通过；代码与选定 c4 完全相同 |

根包的 5 条 `unawaited_return_in_try_block` 分别位于 `lib/src/agent/coach_agent.dart:1255,1258`、`lib/src/assistant/coach_assistant.dart:205`、`lib/src/tools/coach_session.dart:349,352`。Dart 为 3.13.7；这些行与 `ugk_coach-v0.5.0` 一致，本轮未修改根包运行代码，也未降低告警等级。测试通过与根包分析仍有警告分别报告。

本轮没有启动模拟器、运行/安装设备或做 iOS/设备性能验收。原生媒体与整节训练的实际效果，仍等待开哥真机确认后再决定 main 集成。

## 不兼容迁移清单

收尾补丁没有新增 API 破坏；下列是从旧版迁入 c4 实色线时必须处理的既有不兼容项，两包 CHANGELOG 顶部均已列出。

| 包 | 删除 | 替换 / 新要求 |
| --- | --- | --- |
| trainer（从 0.2.x） | `TrainerGlassStyle`、`TrainerGlass`、`TrainerGlassButton`、`TrainerGlassField`、`TrainerHover`，以及各材质参数/转发文件 | `TrainerSurface`、`TrainerIconButton`，三级不透明表面 |
| trainer 主题/舞台 | `glassStyle`、`glass` getter、`scrim`、`fadeClipEdge` | 直接构造主题新增必需 `border`、`shadow`、`ringKnob`、`accentSubtle`，完整 copyWith |
| coach_ui（从 0.1.x） | `thumb`、`mediaScrim`、`landingHighlight`、`CoachChatList.topColor` | 构造新增必需 `background`、`surfaceRaised`、`outline`、`shadow`、`mediaLabelSurface`；顶部功能遮罩取 background |

旧版删除位置详见 [c4 删除审计](solid-layered-audit.md)；原浅深图及源码摘要见 [c4 评审记录](visual-review.md)。本轮自动检查明细为同目录 `flat-closeout-evidence.json`。
