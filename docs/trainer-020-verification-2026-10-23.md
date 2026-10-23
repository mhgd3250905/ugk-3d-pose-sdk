# trainer 0.2.0 分支验证

基线 main：`b8f5b82bcf6f4075480fa6fb2382acea4c44b9c0`。开发分支：`codex/trainer-shared-player`。2026-10-23，版本 trainer 0.2.0 / coach 0.4.1，开哥已批准验收提交 `64a54874307449c8685577f8eeb913296b207a7c` 并快进合入 main；后续批准状态提交只改文档，测试证据仍绑定该验收源码。

## 结果

| 验证 | 结果与边界 |
|---|---|
| 根包 `dart test --reporter expanded` | 456 项通过；新增 30 项 PlanSegment/Codec/Validator/时长回归，既有 426 项保留通过 |
| trainer `flutter test --no-pub --reporter expanded` | 207 项通过；统计、节奏、分段、控件、媒体插槽、平台通道、语音队列，含原 SmartFit/HipLab fixtures |
| `dart analyze` / trainer `flutter analyze --no-pub` | 无问题 |
| 正式 JSON Schema / Codec | Python jsonschema 4.26.0 与 Dart 共用 12 个合法/非法分段案例，结果一致；`python tool/check_plan_segment_schema.py` 通过 |
| SmartFit 原 App 临时副本 | 41 项定向测试通过；只在临时副本补既有 askUser switch 分支，并将一项旧“缺节奏等点击”断言更新为新自动完成要求 |
| FlareLab 固定目录 | 51 项可自动引导：41 项 SDK 缺省、2 项目录节奏、8 项计时；无 parser problem；[机器结果](trainer-020-catalog-guidance-2026-10-23.json) |
| Git diff / 文档 | whitespace 检查、相对链接检查通过；已批准快进合入。2026-10-24 再次以 `git ls-remote origin refs/heads/main` 核对远端为 `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110`，与本地 main 一致；后续文档收束 SHA 见最终交付回执 |

无设备安装、无 App 业务源码修改、无 Pose-Hub 发布、无新增语音素材。后台/锁屏、实际来电、原生媒体与整节真机训练尚未验收，不能从这些测试推断通过。

## 原报告六例

源报告：FlareLab `app/docs/sdk-shared-player-audit-2026-10-23.md`，原脚本 `output/sdk-player-audit-20261023/reproduce_results.dart`。对应 SDK [回归文件](../packages/ugk_trainer/test/engine_audit_regression_test.dart)：

| 原场景 | 修复后的断言 |
|---|---|
| 左先行，只完成左侧 | completedSets=0，partial，整场完成数0 |
| 右先行，只完成右侧（对照） | completedSets=0，partial，整场完成数0 |
| 左先行，双侧全部完成（对照） | completedSets=1，completed，整场full=true |
| 同一父项Y/T/W，只完成Y后跳过 | 用新segmentId编码，completedSets=0，partial，整场完成数0 |
| Y/T/W拆三个独立项（对照） | completed/skipped/skipped，完成数1/3，full=false |
| 默认Builder完成第1组后previous重练，第2组未完成 | 只完成1/2个唯一组，partial；工作活动时间22秒全部累计 |

第四例明确迁移到新分段身份：旧自定义相位不含 segmentId 时，SDK 无法从相同 `(itemIndex,set,side)` 猜出分段而非重练。除六例外覆盖 0.1+0.2 浮点结束、全分段全侧、多次重练、段跳过、计时提前完成、延长休息、晚到点击不误操作下一段、hold覆盖缺省节奏、保留自定义 rhythmOf、替换当前分段不丢完成身份。

## SmartFit 接入复查

来源是报告指定的 `Sport-Helper-media-cache` 工作区，HEAD `6c807c6b7285f3b19b88d6c9deeeb45f230df3f3`；复制时 tracked 工作区干净，验证后原工作区仍干净。lib/test/pubspec/lock 复制到临时目录，素材通过只读使用的目录 junction 引用；`pubspec_overrides.yaml` 将两个 SDK 包指向本开发工作区。没有改动原 App 或其 SDK 缓存。

运行：

```text
flutter test --no-pub test/trainer_integration_test.dart test/trainer_storage_test.dart test/domain_test.dart test/voice_session_test.dart --reporter expanded
```

原样第一次：存储/领域/语音 37 项通过；播放器测试未能编译，因为 `chat_controller.dart` 对 AgentEventKind 的穷举 switch 缺少 0.4.0 新增 askUser。这是已存在于 SDK main 的 coach 升级障碍；开哥明确选择只在临时副本补 `AgentEventKind.askUser => null`，原 App 待聊天流畅度修复后统一升级。

补分支后：40 项通过，1 项旧测试预期“缺 repSeconds 时等待手动完成”失败。该预期与本次明确要求相反，临时测试改为检查无需点击自动完成、保存 full=true、completedSets=1；其余断言与 App 播放/存储代码保持原样。最终 41/41 通过；[临时副本补丁](trainer-020-smartfit-probe.patch)完整记录这两处变化。

覆盖实际 App PlayerPage 的主题/语言/媒体注入、暂停恢复、结果回传与持久化同一sessionId、幂等保存/失败重试、模板和领域约束、逐次语音时间轴与缺语言降级。未运行 SmartFit 聊天气泡 UI、整 App 全量测试或真机安装，因此不声称整 App 升级无需补枚举分支。

临时副本 `flutter pub get` 解析了 SDK 路径依赖；测试采用 Flutter 现有安装环境，锁文件不是产品发布构建锁定证据。原生插件在 widget 测试里由模拟平台/输出替代。

## 审阅与交付

代码并行实现后独立复查，补齐父剂量省略的Codec往返、分段替换身份、缺省节奏下hold优先、长段名不吞首个报数、弹窗期间音频中断不得自动继续。新控件默认关闭，旧无segments计划不输出多余字段；复用既有 RhythmSource.dose，未给该枚举增加新值，避免再产生穷举switch兼容障碍。

接口、语音素材格式、selfPaced待确认类别与平台策略见[接入契约](trainer-020-integration.md)。本记录随 main 保留。FlareLab 按最终 main 提交固定依赖后做锁屏、来电中断、原生播放真机验收；若发现 SDK 问题，再出补丁版本。SmartFit、HipLab 暂不升级。
