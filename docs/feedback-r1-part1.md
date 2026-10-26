# 真机反馈 r1 · 第 1 部分

开哥于 2026-10-26 批准合入 main、推送并发布 **ugk_coach 0.7.0 / ugk_trainer 0.5.0 / ugk_coach_ui 0.3.0**。基线为 `main ac9b31f`，开发分支 `codex/feedback-r1-part1`；原候选 `a451760` 复核后仅包含六项反馈及对应资源、测试和文档，没有夹带液态玻璃改动。三个固定 tag 为 `ugk_coach-v0.7.0`、`ugk_trainer-v0.5.0`、`ugk_coach_ui-v0.3.0`，旧 tag 保持不变。

开发在原有隔离工作树 `.worktrees/trainer-liquid-glass` 完成。原始 checkout 的 `fix/phone-feedback-media-20261024` / `159dadf`、其他工作树与微拟物 stash 保持；本轮没有整体配色或视觉重设计，没有设备与模拟器操作。

## 训练与媒体

开始直接进入共享 `TrainerPlayer`。下载、解码或网络失败不阻塞训练计时与播报。播放器先显示随包 alpha WebP，视频实际首帧可呈现后在相同方形区域约 180 ms 淡入；不显示准备页、字节、百分比或下载错误。失败保留站位图，后台退避重试。

宿主继续实现 `PoseHubMediaPreparer.prepareAction(action)`，负责下载、逐文件 bytes / SHA256 校验、缓存与原子安装。SDK 的队列只编排这些调用，最多并发两个，当前与休息后的下一动作优先，其余按训练顺序预取。宿主缓存命中应直接发 `PoseHubMediaReady`，避免重新下载。Ready 仍只接受 native 本地 file 目录 / Web 同源目录；R2 地址用于下载，不直接传给同源播放器。

计划训练接入共享播放器时提供 `poseHubActionOf`、`poseHubMediaBaseUri`、`poseHubMediaPreparer`；旧 `mediaBuilder` 保持宿主自定义入口。自定义构建器若接管全部媒体展示，应由宿主使用相同准备队列或显式接入新的 `PoseHubPackMedia`。未注入 preparer 的已安装本地包仍可播放。

### 原静帧与首帧的素材限制

219 张 v3 原始 cover alpha WebP **逐字节不变**地加入 `packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/standing/<actionId>.webp`；总计 **5,316,554 bytes**，逐项 SHA256 与目录一致。资源使用相同 square contain 放置，无需网络。

首帧审计比较全部 219 个动作，**187 张不一致**，其中用户可见的 211 个完整动作有 **183 张不一致**。不少 `coverFrame` 明确选在动作中段；其余也通过实际解码核对，而非仅按元数据判定。原封面与首帧不同的动作，180 ms 淡入能保持画布尺寸和位置，不能保证人物姿态完全不变。本轮遵照要求不改素材，后续需素材方提供首帧静帧才能满足完全同姿势切换。

- [完整差异清单与方法](evidence/feedback-r1-part1/standing-first-frame-audit.md)
- [全部 219 项机器可读测量](evidence/feedback-r1-part1/standing-first-frame-audit.json)
- [空心体支撑对比](evidence/feedback-r1-part1/abs-A.jpg)、[内收肌对比](evidence/feedback-r1-part1/adductors-A.jpg)、[深蹲对照](evidence/feedback-r1-part1/h-squat.jpg)

复现（只读源素材，图片输出仅作证据）：

```powershell
python tool/audit_posehub_standing.py <v3-pack-root> <evidence-output-directory> --workers 4
```

工具按媒体协议解码视频 frame 0，在 320 square 比较 alpha>=128 的轮廓 IoU 和白/深底合成的前景 RGB 平均绝对误差。通过阈值为 IoU>=0.95 且 MAE<=8，用于容忍 H.264/WebP 的不同有损编码；不是逐像素相等证明或用户视觉验收。

## 动作库与单动作训练

用户动作库只列 211 个语义完整动作，219/211/8 的原始目录数据不变。两列卡片以上方透明人物为主体，下方仅中文名称（最多两行）；名称/别名中文搜索，不按内部 ID 搜索。器械、部位、类型三维横向筛选可组合。动作 ID、完整性状态、总数与 pending 筛选不出现在用户界面。

合入前按交接 C ① 补齐卡片22px圆角、1:1渐变图区、名称最多两行；选中筛选项使用青绿浅底和勾选，另有中文已选项摘要及右侧“清除”（同时恢复搜索与全部筛选）。无结果时提供图标、提示与恢复入口。局部视觉补齐不改全局主题或媒体素材。

截图：[默认](evidence/feedback-r1-part1/browser-default.png)、[组合筛选](evidence/feedback-r1-part1/browser-filtered.png)、[空状态](evidence/feedback-r1-part1/browser-empty.png)、[320px深色](evidence/feedback-r1-part1/browser-dark-320.png)。使用原始alpha素材和本机字体，仅为Flutter软件渲染证据。不可变原候选的[差异范围核验](evidence/feedback-r1-part1/diff-scope-audit.md)单独记录，无玻璃实现夹带。

点动作卡片直接启动只含该动作的共享训练播放器。默认剂量取动作目录语义，不从视频时长推断；使用共享训练页的说明展示。旧单练入口保持可调用，详情页不再是导航中转。

## 套路卡

展开标题到外卡顶部/左侧均 22 px，标题与副信息间距 5 px，副信息降到 12 px muted；收起按钮与标题首行居中。透明人物的多动作套路卡从 240 增到 288 px，首图 contain 区域放大约 30–32%，与标题保持 8 px 间隔；保留出框与 hero→第一行动作缩略图动画。单动作卡原为左图右文横排，没有该 hero/缩略条结构，保持原布局。

`cutoutTopInset` 与宿主已验证的 alpha 边界 / 背景面下移 12–16dp 约定不变。整张原 cover 的透明边距不会由 SDK 擅自裁掉；实际头部出框继续通过同一宿主 renderer 完成，不能仅把含透明边的原图贴到卡片里就宣称头部已出框。

[收起](evidence/feedback-r1-part1/plan-card-collapsed.png)、[展开](evidence/feedback-r1-part1/plan-card-expanded.png)、[展开 250ms](evidence/feedback-r1-part1/plan-card-expanding-250ms.png)使用本机中文字体、原始 alpha WebP 和 Flutter test renderer。内容是布局测试数据，不是 AI 排课结果或设备截图。复现工具 `packages/ugk_coach_ui/tool/feedback_plan_card_preview_test.dart` 通过 `COACH_PREVIEW_CJK_FONT` / `COACH_PREVIEW_ICON_FONT` 读本机字体，无配置时跳过；字体不入仓库。

## AI 一轮补齐参数

生成训练组前从对话与 App 上下文提取场景、可用器械和时长；已知信息不重复问。缺多项时在一个 `form` 提问中用可点击分组补齐，器械支持多选且来自当前动作库，附“直接出方案”。最多追问一轮，用户跳过或回答仍不完整时使用明确默认，已有参数齐全则直接生成。

`AskUserMode.form` / UI 对应 form 为新增枚举值，旧穷举 switch 需补分支。旧 text / choice 数据仍可解析。宿主需将 fields 映射到 `CoachQuestionData`，通过 `answerForm` 提交分组值；skip 调用 `skipQuestion` 或提交“直接出方案”。详情见 [ask_user 协议](ask-user.md)与[会话控制器](coach-conversation-controller.md)。旧 App 不会因 SDK 升级自动完成这层映射，本轮没有修改任何 App。

## 验证与发布边界

已完成 coach 全套 **509/509**、coach_ui 全套 **44/44** 和中文实图套路卡截图检查 **1/1**。新增 AI 分组 UI 的 5 项定向回归也已通过。相关修改文件静态分析零问题；根 `dart analyze` 仍报告基线相同的 3 条 `unawaited_return_in_try_block` warning（`coach_assistant.dart:205`、`coach_session.dart:349/352`），对应两文件与 `ac9b31f` 无差异，本轮未扩改。

新增确定性多轮测试覆盖信息全、缺1项、缺3项、跳过，以及缺项直接出方案、已知参数重问、第二轮追问、否定场景/器械、常见训练意图和实际剂量估时约束。`dart run tool/eval_ask_user.dart --dry` 的 **10/10** fixture 校验通过（[回执](evidence/feedback-r1-part1/ask-user-fixture-validation.json)）。当前环境没有模型鉴权配置，`modelCalls=0` / `modelQualityPassed=null`；这两类证据不冒充真实模型效果评测。

trainer 合入前最终全套 **301/301** 与 `flutter analyze --no-pub` 通过（原候选298项，加交接C视觉/交互回归3项）；动作库中文实图截图检查1/1通过。回归覆盖所有视频始终 pending 时整计划计时与播报正常完成、首帧后180ms淡入、失败静默退避、取消/晚事件、当前抢占、异步取消完成前不释放并发槽、同host父重建复用队列、换host先等待旧队列取消、320px/2倍字体，以及正方形渐变、22px圆角、筛选与清除/空状态恢复。

example 的 `flutter pub get --offline --enforce-lockfile` 与 `flutter build web --release --no-pub` 通过；Web 产物内219张站位图再次逐SHA核对，全部与v3目录一致。`git diff --check` 通过。源媒体219项解码审计与219个bundle cover SHA256全量核对已完成；没有改原媒体、目录或R2对象。没有启动设备或模拟器，构建与软件截图不扩张为原生硬解、设备性能、长时训练或iOS验收。

仓内 trainer 测试通过忽略的 `pubspec_overrides.yaml` 指向同一工作树 coach。正式消费者验证必须从真实远端固定 tags 获取三个包、无 override，并使用 `--enforce-lockfile` 复核；不能把仓内 path 测试当成远端 tag 验证。
