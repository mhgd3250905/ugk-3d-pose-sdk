# 项目维护台账

更新日期：2026-10-26。仓库：[mhgd3250905/ugk-3d-pose-sdk](https://github.com/mhgd3250905/ugk-3d-pose-sdk)。

本台账统一记录维护状态、已合并成果、验证证据和待办。包版本、接口行为仍以对应清单和实现为准；发布历史保留在 CHANGELOG。表内 SHA 是核验快照，后续文档提交会推进 main，不能把快照当成永远最新的分支指针。

## 当前快照：v3 压缩媒体与宿主准备接口（2026-10-26）

coach 0.6.2 / trainer 0.4.2 将 657 个媒体从 587,456,377 bytes 压缩到 163,351,529 bytes，由 R2 posehub-media 桶的 media.uuugk.win/pack/r1-v3/ 按原相对路径分发；GitHub Release 仅保留 catalog 和整包 ZIP 备份；保持 219 / 211 / 8 全部动作与语义。新增可选的宿主媒体准备事件流，准备完成后才允许单练计时；无注入保留本地播放。SDK 目录准入改为版本/清单/定义校验，取消固定 v2 SHA 门槛。旧 v1/v2、微拟物暂存和原始工作区保持。

接口签名、逐文件 URL、进度/失败/取消契约、压缩和五动作画质对照见[v3 接入与核验](posehub-app-test-pack-r1-v3.md)。本轮不启动模拟器或操作设备，编码兼容性不扩张为原生硬解或 Raster P99 实测结论。

## 历史快照：扁平版批准与 219 动作包（2026-10-26）

开哥已确认扁平版真机流畅，`c6e261e`（trainer 0.3.1 / coach_ui 0.2.1）已快进合入并推送 main。微拟物 stash `fcda16d` 未动；原始主工作区 `159dadf` 未动。

随后从 main 新建 `codex/posehub-219-assets` 接入原始 R1：219 动作、657 媒体、587,456,377 bytes；142 个完整，77 个标“训练说明待补”，AI 投影只含 142 个。coach 0.6.0 / trainer 0.4.0 为新增接口，coach_ui 保持 0.2.1；没有本轮新增 API 删除。素材以完整 ZIP 的 Release asset 分发（592,170,694 bytes），不进入普通 Git 历史。现有训练页布局、防闪按钮和 Morph Pulse 保持不变。

用户已授权测试通过后合 main、推送和打 tag。测试、文件完整性、Web 透明播放、构建与平台边界见[本轮核验](posehub219-verification-2026-10-26.md)；接口和素材安装见[接入指南](posehub-app-test-pack-r1.md)。原生 Raster P99 待测，本轮不启动模拟器、不操作设备。

## 历史快照：trainer 0.2.10 与 R4 合入批准（2026-10-25）

开哥已同意将当前 R4 候选做版本归档并推进 main。版本组合为根包 `ugk_coach 0.5.0`、`ugk_coach_ui 0.1.2`、`ugk_trainer 0.2.10`；已批准快进 main，最终 SHA 见交付回执。本轮不发布新 tag，也不移动既有 tag；固定 tag 与清单版本、main 指针分别记录。

候选 `4a843a7` 基于既有 trainer 0.2.4–0.2.9 修复及媒体/播放控制实现，R4 采用技能中已调过的浅深 accessory / control 光学配方，保留原布局、业务规则与自定义材质入口。候选祖先 `ee83dc3` 中的 coach_ui 0.1.2 `topInset` / `fadeTop` 一并合入；根包运行代码、测试、提示词和配置相对当前 main 均未改。

R4 软件与构建证据绑定 `4a843a7`：trainer 253 项、展示入口 4 项测试通过，两处分析通过；四状态浅深 106 个控件外框与 v0.2.9 最大偏移 0dp。Coach UI 本次集成检查：23 项测试与静态分析通过；媒体播放协议 8/8 通过，示例依赖严格锁文件校验通过。版本和文档收束不把这些软件结果扩张为原生视觉或性能验收。

用户的“还行吧”及合入批准只证明本轮允许版本归档与 main 推进；R4 原生通透效果、真实透明视频合成、设备性能和 iOS 构建仍未验证。遵照用户内存限制与禁止模拟器的指令，不再启动模拟器或安装用户设备。旧 0.2.8/0.2.9 profile 结果保留历史来源，不能作为 R4 性能成绩。

原始主工作区 `E:\AII-3D\3D-Pose-SDK` 保持 `fix/phone-feedback-media-20261024`、`159dadf` 及原有工作；本轮在候选 worktree 完成版本收束与集成，不重置或清理原工作区。

## 历史快照：coach_ui 0.1.1 与 ASCII 清单（2026-10-24）

已按开哥批准先核对「320px + 2 倍字体 + 浅/深主题 + 展开套路卡 + 中文长剂量」用例存在且通过，再合入并推送 SDK `3302d6235a39e2c2b4b51fa196cc32b37c31b54c`。`ugk_coach_ui-v0.1.1`、`ugk_coach-v0.4.2`、`ugk_trainer-v0.2.2` 均已发布并固定该提交；旧 16 个 tag 未移动。

SDK UI 21 项、ASCII 清单 1 项测试通过，SmartFit 454 通过 / 13 条件跳过、分析无问题，常规深浅布局 golden 一致。SmartFit 从正式 GitHub 远端用全新 Git 缓存、原生 git/Pub 无转码包装器验证严格锁文件后，已合入并推送功能源码 `9d2ff7db6f598fe6cf629de02ed3c56ade660f9e`。验收工具链为 Flutter 3.44.7；机器全局已独立更新至 3.47.8，本次用隔离的原验收工具链保持已测锁文件，不混入另外 5 项依赖升级。后续只更新发布状态 Markdown，tag 和运行代码保持固定。

## 已发布基线：共享聊天 UI 0.1.0（2026-10-24）

开哥已批准 SDK `f0ea0647586913b205fc6dbb75fc9f97cedc55ce` 合入并推送 main，`ugk_coach_ui-v0.1.0`、`ugk_trainer-v0.2.1` 均已发布且固定该 SHA。coach 继续锁 `ugk_coach-v0.4.1`（`88da65ab4e7d6753ab548d779f4168f023dbf9f8`）。后续收束只改发布状态文档，不能把 tag SHA 写成永远最新的 main 指针。

新 UI 包只依赖 Flutter，公开主题、呈现 DTO 与操作回调，接口清单和可编译示例见[包 README](../packages/ugk_coach_ui/README.md)。UI 8 项和 trainer 207 项测试、静态分析通过。SmartFit 功能源码 `7f3458dabbf8db4d5c65297d72bccc77eeed8c86` 已在正式 GitHub 远端重新 `flutter pub get --enforce-lockfile` 通过、锁文件未变化后合入并推送 main；全套 452 通过 / 13 条件跳过、原 main 深浅色 golden 一致、Web/Android 编译通过。未验证真实 Key、真机长时锁屏或 iOS，也未改 SmartFit `release/1.0`。

trainer 0.2.1 仅将相对 coach 依赖改锁正式 tag，解决宿主分别锁包 tag 的 Git 来源冲突，运行代码保持 0.2.0。HipLab / Flare 按各自安排接入，本轮没有替其它 App 修改依赖。

## 历史快照：trainer 0.2.0 / coach 0.4.1

2026-10-24 核验：开哥已批准 `codex/trainer-shared-player` 的 trainer 0.2.0 / coach 0.4.1。main 与远端 `refs/heads/main` 均为 `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110`，包含验收提交 `64a54874307449c8685577f8eeb913296b207a7c`。这是本次文档收束前的 Git 快照；收束提交会推进 main，最终 SHA 以交付回执为准。

| 项目 | 已核对状态 |
|---|---|
| 主线代码 | 已批准快进合入并推送；验收源码 `64a54874307449c8685577f8eeb913296b207a7c`，后续 `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110` 只改批准状态文档 |
| 根包 | `ugk_coach` 0.4.1；新增 PlanSegment 模型、Codec、Validator 和时长支持；本阶段未改 Agent 工具/提示词 |
| 训练执行 | `ugk_trainer` 0.2.0；唯一组 × 必需侧 × 分段统计、缺省自动计次、一组多段及可选播放器操作，见[接入契约](trainer-020-integration.md) |
| 推荐入口 | `CoachAgent`；`CoachSession` 保留作 0.2 降级，`CoachAssistant` 为 deprecated 旧接口 |
| 版本管理 | 三包各自以 pubspec.yaml 管理版本；均为 `publish_to: none`。本轮 trainer 归档为 0.2.10，coach 维持 0.5.0，coach_ui 为候选已有 0.1.2；已批准快进 main，最终 SHA 见交付回执，不新增或移动 tag |
| 离线验证 | 验收源码根包 456 项、trainer 207 项、正式 Schema/Codec 12 个共享样例通过，静态分析无问题；详见[验证记录](trainer-020-verification-2026-10-23.md) |
| SmartFit 回归边界 | 原 App 未改；仅临时副本补既有 askUser 穷举分支并更新自动计次预期后，41 项定向测试通过。不代表整 App 无修改升级或真机验收通过 |
| App 升级安排 | FlareLab 固定交付的 SDK main 提交接入；SmartFit、HipLab 暂不升级。coach 0.4.0 起的 `AgentEventKind.askUser` 仍要求旧穷举 switch 补分支 |
| 真机与目录待办 | FlareLab 接入后验收锁屏、来电中断、原生播放；发现 SDK 问题再出补丁。Pose-Hub 的 41 项 rhythm 补齐及目录发布另行安排 |
| 历史证据 | coach 0.4.0 的 426 项/真实六例、0.3.3 的 377 项及 trainer 0.1.7 的 170 项保留原 source 语境，不作为当前整 App 或真机验收证明 |
| Cockpit | 当前绑定会话 active；本次保存后只登记一次非终态检查点，不结束会话或生成交接 |

## 事实来源与文档分工

以下来源均已从根 README 的直接声明核对。本台账新增后，也由根 README 直接指向。

| 路径 | 类别 | current / archive-history | 用途与核对结果 |
|---|---|---|---|
| [README.md](../README.md) | 项目入口 | current | 当前接入方式与文档入口；区分 Agent、工具版和 JSON 信封旧接口 |
| [pubspec.yaml](../pubspec.yaml) | 包配置 | current | 根包名 `ugk_coach`、版本 0.5.0、ASCII 清单、禁止 pub.dev 发布；本轮根包运行代码不变 |
| [docs/agent-plan.md](agent-plan.md) | Agent 设计 | current | 0.4 先问再排、工具循环、技能披露、用户记忆和事件；不充当真实服务验收记录 |
| [CHANGELOG.md](../CHANGELOG.md) | 仓库版本变更记录 | current / history；按包名区分 | 当前归档 coach 0.5.0 / trainer 0.2.10 / coach_ui 0.1.2；历史证据保留原语境 |
| [packages/ugk_trainer/pubspec.yaml](../packages/ugk_trainer/pubspec.yaml) | 训练包配置 | current | trainer 0.2.10，ASCII 清单，coach 依赖固定 `ugk_coach-v0.5.0`；`publish_to: none` 保留 |
| [packages/ugk_coach_ui/README.md](../packages/ugk_coach_ui/README.md) | 共享聊天 UI 接入 | current | coach_ui 0.1.2 的公开 API、`topInset` / `fadeTop`、主题/回调和宿主职责边界；本轮不变更已有 tag |
| [packages/ugk_trainer/README.md](../packages/ugk_trainer/README.md) | 训练接口与接入约定 | current | 0.2.10 接入及 R4 材质，保留统计、自动节奏、分段和播放器接口；明确 iOS 15+、Web 降级与原生待验边界 |
| [packages/ugk_trainer/CHANGELOG.md](../packages/ugk_trainer/CHANGELOG.md) | 训练包版本记录 | current / history | 0.2.10 归档 R4 与既有 0.2.4–0.2.9 增量；旧版运行行为与验证证据保留原语境 |
| [0.2.0 接入契约](trainer-020-integration.md) | 当前接入约定 | current | 统计、自动计次、segments、操作开关、语音素材与平台策略 |
| [0.2.0 验证记录](trainer-020-verification-2026-10-23.md) | 验收证据 | current | 绑定 64a5487；含 SmartFit 临时副本边界、目录审计和真机待验 |
| [ask_user](ask-user.md) | Agent 接口 | current | 事件/回答接入及 0.4.0 新枚举对穷举 switch 的破坏性变更 |
| [0.3.3 提速记录](coach-033-speed-2026-10-21.md) | 实测与合入状态 | archive/history | 记录 0.3.3 最终六条前后对比，保留先前性能未达标候选与余额不足尝试，不混用源码版本 |
| [docs/design.md](design.md) | 早期设计决策 | archive/history | 标题明确为 ugk_coach 0.1.2，不用它覆盖 0.3 行为或判定外部 PR 的当前状态 |
| [docs/smoke-2026-10-20.md](smoke-2026-10-20.md) | 历史真实调用 | archive/history | 0.1 / OpenCSG 的一次真实冒烟，不能证明 0.3 Worker 多步链路通过 |
| [docs/project-ledger.md](project-ledger.md) | 维护与验收台账 | current | 本文；承接当前合并状态、验证适用范围、未决事项和维护规则 |

最初文档对齐没有修改 profile、目录、提示词或依赖。原修复新增推理协议回传及记忆开启指令，历史 0.3.2 在指定源上集成，并补齐请求时限、推理预算口径及逐工具记忆持久化；具体变更见 CHANGELOG。源分支原 Unreleased 的必要事实已归入 0.3.2，原真实验证保留在下方历史小节。

## 合并记录

PR #1 / #3 / #4 / #5 的状态与完整 SHA 于 2026-10-21 核对；PR #6 于 2026-10-23 通过 GitHub 和本机 Git 核对。日期按 Asia/Shanghai 记录。

| PR | 成果 | 状态 / 日期 | 合入提交 |
|---|---|---|---|
| [#1](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/1) | 通用训练模块 ugk_trainer 0.1.0 | MERGED / 2026-10-20 | `68c3f32389749c04ad61a06af96e4b9841ccce87` |
| [#3](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/3) | ugk_coach 0.2.0 工具版会话与门禁 | MERGED / 2026-10-21 | `09a392bc0b736e6a23eef71d55d86108660e0e59` |
| [#4](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4) | ugk_coach 0.3.0 Agent 与渐进式技能披露 | MERGED / 2026-10-21 | `1f8be6edf9c0c57575d963448af379e8fdf8df2a` |
| [#5](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/5) | ugk_coach 0.3.1 Agent 韧性与审核修复 | MERGED / 2026-10-21 | `517fdbef6d9e611eff3f68bc2138f8e00e35c82e` |
| [#6](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6) | ugk_trainer 沉浸式舞台 UI 与 r9 修复，版本收束为 0.1.7 | MERGED / 2026-10-23 | `eb29c749a52c1b226841726a3fba8e9f62e9e6be` |

PR #4 的复审 head 为 `48417e03f5ff05d4434dc2e15cc36237464153d2`。合并提交的两父提交分别为 `09a392bc0b736e6a23eef71d55d86108660e0e59` 和该复审 head；合并树与复审树一致。

0.3.3 在开哥明确批准后通过 Git 快进合入 main，包含验收提交 `a931a04d6362ce8efba262556b34df3b485cc51d`；本次没有新建 PR。批准状态文档独立提交，运行时代码与已验证的 `e8c8921508139dc0f3eee1d2099eb5feefa80774` 相同。

PR #6 在开哥明确同意后合并，两个父提交为原 main `f684e02f38e652633c23fa8946a53d02b6aa3ea2` 与复审 head `b84881f58c035b1fce2ff929cdb207e465821c92`。合并树与复审树一致；后续 0.1.7 版本及文档收束不改运行时代码。0.1.5 / 0.1.6 的媒体功能已在合并前的 main 中，本次不将其冒记为 PR #6 新增。

trainer 0.2.0 / coach 0.4.1 于 2026-10-23 获开哥批准后通过 Git 快进合入 main，验收提交 `64a54874307449c8685577f8eeb913296b207a7c`；批准状态文档提交为 `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110`，2026-10-24 再次核对远端一致。本阶段没有新建 PR。

## 验证证据与适用范围

### trainer 0.2.0 / coach 0.4.1：版本与文档收束（2026-10-24）

开发基线 `b8f5b82bcf6f4075480fa6fb2382acea4c44b9c0` 来自已保存的分支验证记录，已核对存在且为收束前 HEAD `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110` 的祖先。baseline..HEAD 为 2 个提交、42 个路径：运行代码 12、测试/样例 14、工具 2、schema 1、包清单 2、文档/证据 11。完整 `git status --porcelain=v1 --untracked-files=all` 无输出，tracked/staged/unstaged/deleted/renamed/untracked 均为 0；阶段成果均属于已批准的 SDK 开发。

本次从根 README 的直接声明核对当前事实来源，修正台账仍把 0.4.0 / 0.1.7 写作当前版本的问题，补齐远端快照、App 升级安排与真机待验。两份 pubspec 已是 0.4.1 / 0.2.0；本次保持不变，仅更新文档记录。旧版本记录保留历史语境。

2026-10-23 的验证绑定验收源码 `64a54874307449c8685577f8eeb913296b207a7c`：根目录 `dart test --reporter expanded` 456 项；trainer 目录 `flutter test --no-pub --reporter expanded` 207 项；`dart analyze` / `flutter analyze --no-pub` 无问题；`python tool/check_plan_segment_schema.py` 的 12 个共享案例通过。SmartFit 临时副本定向测试为 41 项，补丁和原 App 未改的边界见[验证记录](trainer-020-verification-2026-10-23.md)。

本次只读 `git diff --name-status 64a54874307449c8685577f8eeb913296b207a7c 8b60032c2f43fd8e91f8802c8f054a8ecb7cc110` 确认差异仅 8 个 Markdown 文件；因此复用已验源码的测试证据，不声称重新执行全套测试。收束只检查文档差异、相对链接、版本一致性、完整工作区与 Git 远端。真机和整 App 验收仍按 SDK-003 / SDK-004 单独安排。

本次文档检查：`git diff --check` 通过；只读 Python stdin 校验确认 72 个本地链接目标存在，两包清单版本一致且未修改，验收源码到当前工作树仍只有 8 个 Markdown 路径差异。保存前完整状态为本次 Agent 修改的 7 个 tracked Markdown 文件、untracked 0；不包含业务代码、测试、依赖或素材变更。

### ugk_trainer 0.1.7：PR #6 已合并，版本与文档收束（2026-10-23）

本阶段 baseline 是 PR #6 合并前已审核的 main `f684e02f38e652633c23fa8946a53d02b6aa3ea2`（合并提交第一父提交）；收束起点 HEAD 为 `eb29c749a52c1b226841726a3fba8e9f62e9e6be`。baseline 是 HEAD 祖先，stage delta 为 12 个提交、10 个路径：6 个 trainer UI/导出文件、3 个测试文件和 1 个 CHANGELOG。收束前在主目录执行完整 `git status --porcelain=v1 --untracked-files=all` 无输出，tracked/staged/unstaged/deleted/renamed/untracked 均为 0。

收束核对的 current 来源为根 README / pubspec / CHANGELOG、本台账及训练包 README / pubspec / CHANGELOG；版本与接入事实分别按包核对。训练包 CHANGELOG 中原 10 组 Unreleased 改归 0.1.7，原迭代原文降为 history，避免旧位置/尺寸说明覆盖最终 r9 行为；既有 0.1.5 / 0.1.6 记录保留。根包维持 0.3.3，依赖和运行时代码不变。

以下测试由本会话在 2026-10-23 复审时独立执行；[通过审核记录](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6#pullrequestreview-5617366622) 提交于当日 00:15:49（Asia/Shanghai），绑定完整 source `b84881f58c035b1fce2ff929cdb207e465821c92`。这是复审 source 的证据，不是声称在版本/文档提交后重复跑过全套测试。

| 命令 / 检查 | 结果 | source state / 适用性 |
|---|---|---|
| trainer 目录：`$reviewTests = @(git ls-files 'test/*_test.dart'); flutter test --no-pub --reporter expanded @reviewTests` | 170 项通过，退出码 0 | b84881f 完整已跟踪测试，含 r9 新增 17 项；未计入审查工作副本的旧故障诊断文件 |
| trainer 目录：`flutter analyze --no-pub` | No issues found，退出码 0 | b84881f；包括 UI 及合并后的媒体代码 |
| 根目录：`dart test --reporter expanded` | 377 项通过，退出码 0 | b84881f；根包证据，不代替 Flutter 或真机验收 |
| `git diff --quiet b84881f58c035b1fce2ff929cdb207e465821c92 eb29c749a52c1b226841726a3fba8e9f62e9e6be` | 退出码 0，整树一致 | 合并后及本次 Preflight 重查；上述证据可复用于合并树 |
| GitHub PR #6 状态、合入 SHA 与复审记录 | MERGED；合入 eb29c74、审核 b84881f | 远端观察，不充当测试或对外发布证明 |

本次收束验证于 2026-10-23 执行，source state 为 eb29c74 加以下 6 个已归属改动：根 README、根 CHANGELOG、本台账及训练包 README、CHANGELOG、pubspec。`git diff --check` 通过；`node --input-type=module` 的只读 stdin 核对确认 41 个本地文档链接可解析，两个包版本一致，训练包 manifest 仅有 0.1.6 → 0.1.7 的版本行变化，0.1.6 及更早发布记录和 10 组历史迭代正文保留。完整状态为 tracked modified 6、staged 0、untracked 0；没有其他来源改动。

已用 `git diff --exit-code eb29c749a52c1b226841726a3fba8e9f62e9e6be -- lib test prompts skills profiles packages/ugk_trainer/lib packages/ugk_trainer/test packages/ugk_trainer/assets packages/ugk_trainer/android pubspec.yaml` 确认运行时、测试、素材、平台代码与根包配置无变化；训练包依赖也已通过 manifest 整文对比确认不变，因此复用上述测试证据。浅色和深色 Web 预览只作为外部界面观察；真机帧率、原生媒体播放、锁屏保活及宿主完整训练仍须另行验收。本地版本收束不创建 Git tag 或对外 release，不结束 Cockpit 会话。

### 0.3.3 提速：离线与真实六条通过，已批准合入 main（2026-10-21）

源码 `e8c8921508139dc0f3eee1d2099eb5feefa80774` 在独立分支上实现作用域紧凑索引、内联三条技能快路径、明确动作要领的受限详情预载，以及普通请求隐藏自检/门禁拒绝后开放。默认步数、超时、上下文和重试配置不变，跨轮 reasoning 保留官方协议。旧臀桥 badResponse 缺失原始证据，补安全诊断但未声称已确定或修复历史根因。

SDK 377 项测试与 analyze 0 问题通过；SmartFit 定向 56 项通过（仅隔离测试适配 agent-v2 元数据断言及显式自检输入，App 运行时代码未改）。候选 c4981c9 的完整六条正确性通过，问答 1 步 24.824 秒，但记忆关闭计划因两次自检达到 78.875 秒/34,515 token，不算性能验收通过；据此进一步限制自检工具的初始开放。

余额恢复后，在仅追加文档的 checkout `3a23ba0803a05efc1519efac3a231fc480e8ba1a` 完整重跑同六条，运行时代码与 e8c8921 相同。最终合计 8 步/8 请求、180.430 秒、74,130 token，较基线减少耗时 79.2%、token 80.7%；4 条计划均 1 步、28.616–36.306 秒，要领 1 步、25.397 秒，无回落，编造 id 为 0，护腰及记忆应用/关闭隔离与持久化通过。独立只读核验确认原始记录、脱敏 JSON、哈希和表格一致。先前余额不足 403 尝试保留原状态，未参与最终性能汇总；开哥批准后 main 已快进包含 a931a04。详细表格、协议对照、脱敏记录与复现测试补丁见[提速验证](coach-033-speed-2026-10-21.md)。

本次也补读了 main 0.3.2 的 SmartFit 六条证据（App b393044、SDK b26e4fd），共 39 逻辑步、43 请求、867.891 秒、384,013 token；[逐次拆解](coach-033-baseline-analysis-2026-10-21.md)保留全部 P/C 与工具路径。下面 0.3.2 集成时的“尚无新代码树实测”是当时验收边界，不能覆盖本次后来提供的基线记录。

跨轮推理对照已完成：空推理 ping 对照作为有限控制组保留，另用门禁接受的真实排课工具轮取得 1,222 个历史 reasoning token，完整/置空/省略均被当前网关接受，后两者 prompt 少 1,222 token。由于这与当前 DeepSeek 官方 tools 协议要求不一致，按“不确定先不动”保留跨轮推理；独立协议探测不计入六条性能指标，详见上述报告。

### 0.3.2 集成离线已验收并获批合入 main（2026-10-21）

本次以 `9bc392c42222d61d8c57e8dc00373ee165e56e06` 为指定源，在 `517fdbef6d9e611eff3f68bc2138f8e00e35c82e` 上集成；版本为 0.3.2，集成提交为 `31fb6f806612e0416f3bea4e32332068fd333473`。开哥审阅后明确同意合并，main 已快进包含该提交；原修复分支保留。批准状态文档单独提交，验证范围仍绑定上述源码。

当前行为为：Agent 整轮默认 360s、slow 提示 30s、单请求 60s；60k 上下文估算不计推理，仅压缩早期 read / ls 的 tool 结果。每条 assistant wire 消息均保留 `reasoning_content`，缺失使用空串；单步重试继续执行记忆隐私过滤。`remember` / `forget` 逐条等待 store.save 成功才返回 ok，失败返回工具错误；已确认前序保存可在后续取消时保留，pending 保存的迟到结果不写缓存 / 会话，并由串行队列补偿，清除记忆优先。

本次根包 `dart test` 342 项全部通过，Dart 3.12.2 的 `dart analyze` 为 0 问题，`git diff --check` 通过。新增持久化时序、失败恢复、取消/reset/清除/超时补偿和推理跨压缩/重试/清除隔离测试。训练包未改动，本次未重复执行 Flutter 验收。没有为新 0.3.2 代码树重新声明真实 Worker、真机 UI 或完整训练验收通过；下方 304 / 126 / 217 项测试数及 204.564s 等真实请求结果均保留其原 source 语境。

### 原 main 基线的离线证据（历史）

以下为原 main 基线的历史验证，2026-10-21 本机执行，Dart 3.12.2。结果已发布到 [PR #4 复审评论](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4#issuecomment-6309269982)。修复分支补验单列在后文，不覆盖这些历史结果。

| 命令 / 检查 | 结果 | 对应 source state / 来源 |
|---|---|---|
| `dart pub get` | 退出码 0 | 本会话本机验证，`48417e03f5ff05d4434dc2e15cc36237464153d2` |
| `dart test` | 284 项全部通过，退出码 0 | 同上；根包证据，不覆盖 packages 下的 Flutter 包 |
| `dart analyze` | No issues found，退出码 0 | 同上 |
| 原 Fake / Completer 复现 | 11 项记忆与目录检查通过；剩余两条记忆关闭问题修复 | 同上；复审评论记录完整请求参数清除、异步 load 边界与混合工具配对结果 |
| `git diff --quiet 48417e03f5ff05d4434dc2e15cc36237464153d2 1f8be6edf9c0c57575d963448af379e8fdf8df2a` | 退出码 0，树一致 | 2026-10-21 文档 Preflight；因此可把上述离线证据复用于合并后的代码树 |
| `git status --porcelain=v1 --untracked-files=all` | 对齐前无输出 | 2026-10-21 文档 Preflight；没有证据之后的未提交代码变更 |
| `gh pr view <1/3/4> --repo mhgd3250905/ugk-3d-pose-sdk --json number,title,state,mergedAt,mergeCommit,headRefOid,url` | 三个 PR 均为 MERGED | 2026-10-21 远端观察；不代替测试证据 |
| `git ls-remote origin refs/heads/main` | 当时返回 `1d1aad86f516bd7121cc73c71d623043f1042dc3` | 原文档对齐时的历史远端观察，不代表当前 main |

### 原修复分支补验与真实 Worker（历史，2026-10-21）

修复依次为 `029af4a1e735b5f1c3f1ee5cef6c82aad8a1c3f4`（推理回传）、`712cb7b3d636a5314c5aa08211c822928a0af4f4`（空推理协议字段）、`43dfef637144a1e08b5eda5ed743db0671ba5a8d`（记忆开启指令）。根包 `dart test` 304 项、`dart analyze` 0 问题，训练包 `flutter test` 126 项、`flutter analyze` 0 问题，均绑定到 `43dfef6` 的运行与测试树。吸收 main 的文档提交后，`git diff --quiet 43dfef637144a1e08b5eda5ed743db0671ba5a8d 5b5aa27747b6eeaf67c18cc8bd7bebdeea566381 -- lib test packages tool prompts skills profiles pubspec.yaml analysis_options.yaml` 退出码 0。

真实请求由 SmartFit App 链路访问 `https://api.uuugk.win/v1` / `deepseek-v4-flash-0731`，在 Flutter 测试宿主执行，记忆使用本机文件；不是假模型或真机 UI 验收。App 最终运行源码 `5743073691547d44aec891ab6d4a45b5b3fa381b`，217 项测试及分析通过。完整问题、初始失败、用量口径与本机证据目录见 [SmartFit 真实 Worker 报告](https://github.com/mhgd3250905/Sport-Helper/blob/feat/smartfit-skill-agent/docs/coach-agent-smoke-2026-10-21.md)。

| 最终采用用例 | SDK source / 记忆状态 | 步数 | 耗时（秒） | token 合计 | 结果 |
|---|---|---:|---:|---:|---|
| 在家 15 分钟练核心，徒手 | `712cb7b` / 关闭 | 7 | 140.800 | 63,487 | ok；有效核心计划，无回落 |
| 臀桥怎么做 | `712cb7b` / 关闭 | 7 | 101.670 | 39,219 | ok；有效动作卡，无回落 |
| 我腰不太舒服，想练腿 20 分钟 | `712cb7b` / 关闭 | 8 | 204.564 | 98,806 | ok；护腰条件与计划通过门禁，无回落 |
| 我是新手，家里有哑铃 | `43dfef6` / 开启 | 3 | 35.372 | 11,487 | ok；先读记忆 skill，实际保存 level=新手、equipment=家里有哑铃，文字确认且未擅自排课，无回落 |
| 请给我排一个15分钟的居家力量训练计划 | `43dfef6` / 开启、新对话 | 6 | 119.549 | 72,881 | ok；请求含记忆摘要，难度 1，实际含哑铃地板卧推和划船，无回落 |
| 同一句计划问题 | `43dfef6` / 关闭、再开新对话 | 7 | 167.122 | 80,886 | ok；无记忆摘要、无记忆工具、无哑铃动作，本机原两条记忆保留，无回落 |

这是分组复验：`43dfef6` 唯一生产代码差异是 `memory ? ... : ''` 的开启分支字符串；新增回归验证三个 profile 的关闭记忆 system/tools 完整 SHA-256 与 `712cb7b` 相同，因此复用前三条通过记录，未声称最终 SHA 再完整执行六轮。六条合计 38 步、366,766 token（prompt + completion，reasoning 不重复相加）。

以上是原修复分支的历史验收。当前 SDK 0.3.2 已获批准合入 SDK main，代码集成提交为 `31fb6f8`。SmartFit App 后续应将 git ref 固定到包含修复的 SDK main 具体提交，其主线集成待独立安排；不把临时修复分支 ref 带入 App main。

原验证记录同步只修改 README、CHANGELOG 和本文，不改当时的代码、测试、配置或生成物，复用上述验证。该历史范围不覆盖本次含代码、测试与版本变化的 0.3.2；新集成必须以自身最终离线验证记录验收。

历史 Android 编译记录不升级为本次 HEAD 的验收证据；真机语音、锁屏保活和 Web 等流程也不能由 SDK 离线测试或此次真实 Worker 验证推定通过。

## 未决事项

| 编号 | 状态 / 级别 | 事项 | 验收条件 |
|---|---|---|---|
| SDK-001 | 原 source 已验证；0.3.2 真实服务待验 | 0.3 `CoachAgent` 真实 Worker 多步链路 | 上文六类分组验证绑定 `712cb7b` / `43dfef6`；本次 0.3.2 的行为与默认时限已变化，历史记录不能证明新代码树已通过真实 Worker 验收 |
| SDK-002 | 已知非阻塞 P3 | `_withoutMemory` 的跨消息 ID 过滤：不同步骤复用工具调用 ID 时，后续普通调用和回复可能被误过滤 | 修正按消息配对或缺失 ID 的回退策略后，验证唯一 ID 正常路径及跨步骤复用 ID 场景；当前没有证据证明实际 Worker 会缺失或复用 ID |
| SDK-003 | 暂不升级；待 App 后续安排 | SmartFit / HipLab SDK 升级 | 开哥明确暂不升级；SmartFit 聊天流畅度修复与 coach ask_user 气泡后续统一接入，升级时补穷举分支。历史 0.3.2 集成记录不代表 App 当前依赖已更新 |
| SDK-004 | trainer 0.2.0 已合入；FlareLab 接入后真机验收 | 锁屏计时/播报、来电暂停及手动恢复、原生播放和完整训练 | FlareLab 固定交付 main SHA 后验收；207 项离线测试不能替代真机验证。发现 SDK 问题再出补丁版本 |
| SDK-005 | Pose-Hub 待安排 | 41 项缺 rhythm 动作补齐并发布目录新版本 | 当前 SDK 缺省节奏可用；固定 51 项目录中未发现需标 selfPaced 的现有动作。未来技术尝试类候选须开哥确认，不能编造动作 ID |

SDK-001 的真实验证只覆盖历史 source；SDK 0.3.2 主线集成已获批准，SDK-003 剩余 App 主线工作待独立安排。SDK-002 未在本次集成中处理，其条件与不阻塞合并的判断见上述 PR #4 复审评论。

## 台账维护规则

每次有效成果更新对应记录：写明目标、状态、完整提交 SHA、验证命令、执行日期与适用范围；有 PR 时补链接和合入 SHA。保留“已合并”“离线已验证”“真实服务待验证”的区别，旧版本证据保留历史标记。

台账与事实冲突时，先核对代码清单、Git/PR 和绑定到具体 source state 的验证，再修正文档。不得为了对齐文档改写未经验证的产品行为，或把待办改成已完成。不要记录凭据或一次性接入代码。

保存流程：核对完整工作区与改动归属 → 仅暂存本次明确路径 → commit → 在已获用户授权时普通 push → 条件具备时登记一次 Cockpit working 检查点。文档完成不自动结束 Cockpit 会话，不自动 relay/handoff。
