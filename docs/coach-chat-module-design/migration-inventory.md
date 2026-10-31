# SF 对话模块搬迁盘点与保真验收

这是设计附录，不是实施完成记录。没有改动 SF 或 SDK 运行代码、测试、依赖与素材，
没有生成或更新 golden，也没有运行模型、设备或三包测试。

## 1. 不可变来源与计数口径

源仓库为 `E:/AII-3D/3D-Sport-AI/Sport-Helper-coach-ui-kit`，所有下列路径、行数和行为均
以 `git show 3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10:<path>` 读取。该提交的 App 为
`0.1.0+51`，三包及 coach override pin 都是 SDK `700d0100f1cb42ef122e774a6ee0076d1916b5e5`。
工作目录只用于查找仓库；当前分支或工作区后续变化不会替换盘点来源。

行数为原始文件按 `bytes.splitlines()` 计数，含空白、注释、import，不是有效代码行。
“目标”是实施时的建议归属，尚未创建相应 Dart 文件。表中的“部分抽”仍要求把全部
对话功能搬到 SDK；它只说明源文件还混有品牌、宿主存储或“我的计划”职责，需要拆分。

已有迁移事实必须保留：SF 此提交中已不存在 `lib/ui/chat/coach_task_bubble.dart`、
`coach_delivery_transition.dart`、`plan_focus_label.dart`。它直接使用 SDK 的
`CoachTaskBubble`、`CoachDeliveryTransition`、`PlanFocusLabel` 及 renderer 插槽。
不能把这些旧路径再次列成待搬代码或计入新增删除行数。

`lib/ui/training_route.dart` 也已是 SDK `TrainerSlideRoute` 的诊断包装，不能再复制一套路由
动效到新对话包。SF 的 `PlanCard`、气泡和 validated plan card 多数已是 SDK UI 的适配层。

## 2. 对话源文件的归属

下表 16 个源文件合计 **5344 行**，是净删除估算的唯一运行源基数。

| SF 原路径 | 原行数 | 处理 | 实施目标与宿主保留边界 |
| --- | ---: | --- | --- |
| `lib/chat/ai_chat_engine.dart` | 474 | 部分抽，教练对话功能全搬 | `ugk_coach_chat` 的 Agent/Conversation 适配；复用 `ugk_coach`，移除 SF RuntimeLog/Scenario 类型耦合，改观察者端口；不另写模型循环 |
| `lib/chat/ai_coach_config.dart` | 56 | 留 SF 薄配置 | App 编译环境与 device identity 绑定保留；用公开 gateway/client 配置供模块，不能把 `SMARTFIT_*` 环境变量名或凭据写死进 SDK |
| `lib/chat/app_chat_actions.dart` | 151 | 部分抽 | 新对话、历史、上次计划、已保存计划送入对话等语义归模块；品牌建议语归 profile；library/settings/custom/my-plans/appearance/voice 等变 typed 宿主动作，不能靠任意模型正文执行命令 |
| `lib/chat/chat_controller.dart` | 1185 | 部分抽，对话控制功能全搬 | `CoachChatController`；消息列表、question、cancel/reset epoch、进度、保存/更新语义、focus、训练回执、对话持久化调度归 SDK；AppStore 的具体实现经存储端口注入 |
| `lib/chat/chat_models.dart` | 628 | 全搬通用模型并改类型引用 | 模块展示消息/状态/历史与兼容解码；用 SDK canonical plan 和 validated 类型，SF 的 Scenario/Exercise/SavedPlan 仅留边界映射，不创建第二个模型可见 sessionState |
| `lib/chat/safety_script.dart` | 39 | 全搬流程，文案可配 | 同一安全对话流程与步骤编号；profile 提供范围、文案、明确判定配置，宿主提供持久化/全局训练许可，不允许仅改提示词就解除阻断 |
| `lib/ui/chat/chat_home_page.dart` | 655 | 全搬页面，移除具体宿主页引用 | `CoachChatPage`；输入焦点、消息时间线、等待→出卡、训练往返防重入与回执插入、菜单中的新对话归模块；library/my-plans/settings 只发宿主回调 |
| `lib/ui/chat/chat_composer_dock.dart` | 511 | 全搬 | 模块 composer/dock，保持键盘/菜单高度接力、focus label、训练期间 metrics 延迟发布及 reduced-motion 行为；不留 SF 全局 singleton 依赖 |
| `lib/ui/chat/chat_timeline.dart` | 206 | 全搬 | 模块时间线与 `TrainingFinishedEntry`；保留 reverse list、stable key、findChildIndexCallback、消息入场与完成回执占位动画 |
| `lib/ui/chat/chat_widgets.dart` | 411 | 全搬，品牌改注入 | 建议语条、输入栏、feature panel；尺寸、文本样式、点击/键盘语义保留；图标与颜色来自 profile |
| `lib/ui/chat/coach_ui_adapter.dart` | 545 | 部分抽 | 通用消息/question/plan→`ugk_coach_ui` 数据映射归模块；SF palette/type/icon/剪影配置归 App profile；`withSmartfitSavedPlanUi` 等“我的计划”包装保留为小型宿主适配 |
| `lib/ui/chat/cosmos.dart` | 217 | 全搬可配置背景实现 | 模块背景 preset/背景 builder，原 SF 天空、48 星、seed、前后台/减少动效/33ms 节流保持原样；其他 App 可关闭或换主题，不能要求每 App 复制星场 |
| `lib/ui/chat/chat_bubble_adapter.dart` | 93 | 已有 SDK，可消 SF 薄壳 | 模块把展示模型映射给现有 `CoachMessageBubble/CoachOptionPill/CoachGreetingBlock/CoachTimeMark`，不复制底层组件 |
| `lib/ui/chat/plan_card.dart` | 72 | 已有 SDK，可消 SF 薄壳 | 模块共享卡片适配调用 `CoachPlanCard`；“我的计划”也可消费公共卡片 adapter，不能为了删除这 72 行反过来复制一份卡片布局 |
| `lib/ui/chat/validated_plan_card.dart` | 51 | 已有 SDK，可消 SF 薄壳 | SDK 验证后的卡片入口归模块，留住 validated provenance/version/savedRef，不把任意历史 JSON 直接当已验证计划 |
| `lib/ui/chat/training_card_media.dart` | 50 | 部分抽 | 模块负责卡片可见时的预热调度；宿主/素材端口提供同一播放器海报解码源。不得替换成空占位或另一次可能闪烁的异步图片加载 |

以下三个文件同在 `lib/ui/chat`，但属于用户明确留在宿主的“我的计划”，合计 **1393 行**，
完全排除在上述 5344 行及预计删除量之外：

| SF 原路径 | 原行数 | 留宿主内容与共享边界 |
| --- | ---: | --- |
| `lib/ui/chat/saved_plans_page.dart` | 724 | 列表、空列表、命名/删除/排序/最近使用入口与页面导航；“发到对话”改调模块 controller，不留另一套 focus/会话导入逻辑 |
| `lib/ui/chat/saved_plan_actions.dart` | 536 | 宿主计划菜单、按压/遮罩/重命名/删除交互，不因放在 chat 目录就搬入对话包 |
| `lib/ui/chat/saved_plan_animated_list.dart` | 133 | 宿主保存计划列表的增删动画；不计入 SDK 对话迁移收益 |

核算：`lib/chat` 六文件 2533 行；`lib/ui/chat` 十三文件 4204 行，其中保留三文件
1393 行；`2533 + 4204 - 1393 = 5344`。

## 3. 依赖拆分与不应整体搬走的文件

这些文件是已核对的直接或明确共享依赖。它们不能原封不动成为新包对 SF 的反向依赖，
但下表所有行数均**不计入** 5344 行删除基数，避免对共享代码重复计减。

| SF 路径 | 原行数 | 设计处理 |
| --- | ---: | --- |
| `lib/app/services.dart` | 402 | 留宿主组合根：创建 profile、catalog/media、gateway、存储适配与共享 builder；原 `_createChatEngine/_createChat` 接线替换为模块构造，训练结果与全局设置存储仍由宿主负责 |
| `lib/data/app_store.dart` | 486 | 留宿主数据；现 `smartfit.state.v1`、计划与训练记录不重建。对话模块经 port 读写 chatLog/display/session，保留串行写入与旧数据兼容 |
| `lib/core/storage/local_state_storage.dart` | 31 | 留宿主，shared_preferences 细节不进入通用控制器 |
| `lib/app/user_memory_store.dart` | 39 | 留宿主具体实现，注入原 SDK `UserMemoryStore`；模块管理对话侧开关/清空命令，设置页仍由 App 持有 |
| `lib/domain/exercise.dart` | 313 | SF 动作库页面/媒体适配保留；模块使用 scoped SDK catalog/通用媒体接口，不依赖此 SF 类 |
| `lib/domain/plan.dart` | 305 | SF 我的计划/历史数据的旧 JSON 兼容与边界映射保留，通用对话改用 SDK `TrainingPlan` |
| `lib/domain/scenario.dart` | 163 | 旧 request/scene 接入映射留适配层，不能让新模块继承 SF 专属 Scenario 枚举 |
| `lib/domain/saved_plan.dart` | 54 | 宿主我的计划实体保留，用存储 adapter 映射 externalId/baseVersion/version |
| `lib/domain/session.dart` | 44 | 已是 trainer adapter；宿主实际 rhythm/builder 配置保留并经 `CoachAppProfile.executionTiming` 提供同时间线测量 |
| `lib/domain/plan_generator.dart` | 393 | 旧手工计划/我的计划编排功能保留，不作为新 SDK 的第二套 Coach 配时规则 |
| `lib/domain/plan_validator.dart` | 102 | 宿主旧数据适配可留；SDK 对话接入、外部计划导入与输出仍须经过 scoped SDK validator，不能仅信任此适配 |
| `lib/ui/plan_page.dart` | 741 | **部分抽出**：通用详情/预览/动作条目归模块 `CoachChatPlanDetailsPage`（可复用 UI leaf view），聊天与我的计划共用；宿主留薄入口与 store 回调。不声称整文件删除，暂不计净减量 |
| `lib/ui/custom_plan_page.dart` | 331 | 留宿主我的计划手工编辑功能；对话菜单通过宿主导航回调进入 |
| `lib/ui/library_page.dart` | 321 | 留宿主动作库页面；聊天推荐卡打开动作只调 typed 宿主回调，不反向 import 整页 |
| `lib/ui/about_page.dart` | 607 | 留宿主设置/品牌/关于页；模块菜单通过导航回调打开，不携带 App 设备/账号/版本展示 |
| `lib/ui/player_page.dart` | 240 | 宿主组合 trainer 的适配入口，不搬另一份播放器。训练播放能力仍在 `ugk_trainer` |
| `lib/ui/open_training.dart` | 122 | 启动防重入、前后台与预加载接线需抽成可复用 launch contract；实际 route 与 App 素材/保存接线由宿主提供。同一 `SessionBuilder` 用于 Coach gate 和播放 |
| `lib/ui/training_route.dart` | 111 | 原动效已归 SDK；保留/缩小宿主诊断 wrapper，观测口可选，不把 frame recorder 或 performance 实验页搬入模块 |
| `lib/app/training_transition_activity.dart` | 36 | 抽出通用短时 transition activity/scope，模块 composer 与背景 freeze 使用公共生命周期；宿主媒体后台队列可通过 adapter 订阅，同一 entry/exit hold 幂等释放 |
| `lib/ui/training_transition_freeze.dart` | 88 | 保留视觉语义并抽入公共模块：retained layer、scroll、ticker 与最新模型数据的延迟发布；不能仅删 wrapper 而让 keyboard/后台消息在路由中途跳布局 |
| `lib/ui/training_poster_image.dart` | 215 | 播放/动作库/对话共用的海报与解码处理，适合媒体能力下沉 trainer，App 留实际素材源；不让 chat 包复制播放器解码策略 |
| `lib/ui/training_visible_poster_preload.dart` | 67 | 同一媒体能力/asset port 复用；保留首次完整首帧契约，不复制 SF 资源路径猜测 |
| `lib/ui/alpha_artwork.dart` | 253 | 通用 alpha 绘制/剪裁与 SF 资源选择拆开；renderer 插槽接现有画法，SF 我的计划和动作库共用的部分继续可用 |
| `lib/ui/plan_presentation.dart` | 38 | 剂量/时长/分块文案改通用 profile 格式器，可供宿主我的计划复用；`holdSeconds` 覆盖不能只改一处卡片字符串 |
| `lib/ui/theme/tokens.dart` | 548 | 品牌 palette、字型、app-wide spacing 仍由 App theme/profile 提供；对话尺寸/动效常量抽公共 token，原数值不改。禁止为了对话搬迁删掉其他页面仍使用的主题类 |
| `lib/ui/theme/ui_polish_tokens.dart` | 213 | 生成卡参数多数已有 SDK `task_bubble_tokens.dart`；保留 brand bindings 与 SavedPlan tokens。只在引用已收敛后删除重复常量，不能全文件计删 |
| `lib/ui/theme/sf_icons.dart` | 929 | CustomPainter 图标属于品牌配置；宿主传现有绘制 builder/size/color，不能改成近似 Material glyph 通过验收 |
| `lib/ui/theme/widgets.dart` | 666 | 对话用的通用控件抽 SDK 或调已有 UI primitive；设置/我的计划/其他页仍用的控件保留；不得整文件复制到 chat 并让两个版本长期分叉 |
| `lib/ui/theme/polish_card.dart` | 89 | 通用 card surface/品牌值拆分，对话通过 profile 的同一 surface builder；非对话引用保留 |
| `lib/ui/theme/solid_surface.dart` | 157 | surface/toast 的通用绘制可复用 SDK，品牌 palette/图标由配置提供；不改变 padding、半透明层级、裁切与点击区域 |
| `lib/ui/theme/measure_size.dart` | 31 | 通用测量 helper 可搬模块，保留 post-frame 发布时序与测试；其他 SF 引用可暂作 re-export |
| `lib/ui/theme/app_theme.dart` | 279 | 留宿主 App theme、系统栏/平台路由；模块依赖注入的主题而非 SF 全局静态颜色状态 |
| `lib/ui/theme.dart` | 18 | SF 主题聚合导出，继续供宿主使用；新包不能 import SF barrel |
| `lib/ui/theme/media_theme.dart` | 45 | 拆分媒体 palette/动画配置与 SF 全局变量；模块通过 profile/renderer 接现有素材画法，其余宿主页引用保留 |
| `lib/ui/theme/transitions.dart` | 81 | 普通页面 400/340ms 的 App 壳路由保留；训练路线继续用 SDK 300/280ms，不把两者误合并 |

`lib/diagnostics` 的具体文件留宿主：`performance_lab.dart` 41、`runtime_log.dart` 406、`coach_tool_trace.dart` 330、
`runtime_log_storage.dart` 11、`runtime_log_storage_io.dart` 108、
`runtime_log_storage_stub.dart` 30、`session_snapshot_archive.dart` 11、
`session_snapshot_archive_contract.dart` 5、`session_snapshot_archive_io.dart` 124、
`session_snapshot_archive_web.dart` 22、`training_transition_timings_storage.dart` 12、
`training_transition_timings_storage_io.dart` 67、`training_transition_timings_storage_stub.dart` 12。
模块提供可选事件/错误/快照观察接口；不默认持有这些诊断的文件 IO、实验页、录帧、
日志导出、真实 gateway 凭据或 SF 路径。它们均不计源码删除量。

## 4. 测试迁移清单

下列 27 文件共 **7931 行** 是可复核的测试候选基数。它们含宿主集成断言，不能直接声称
7931 行全删。设计推荐：SDK 接走共用单元/控件断言，SF 仍保留真实存储/导航/主题/素材
profile 的接线集成用例；同一断言只保留一个主要归属，不把 AppStore fake 直接搬成新依赖。

| 原测试文件（均在 `test/`） | 原行数 | 推荐归属 |
| --- | ---: | --- |
| `ai_chat_engine_test.dart` | 598 | SDK 的 gateway/Agent/conversation adapter；SF 留 gateway 配置接线 |
| `chat_coach_session_test.dart` | 1016 | SDK 主体；宿主 AppStore/external plan 适配契约保留集成段 |
| `chat_composer_dock_transition_test.dart` | 222 | SDK，全移；保留 freeze/metrics 的事件序列 |
| `chat_constraints_test.dart` | 33 | SDK，原约束与布局条件 |
| `chat_controls_regression_test.dart` | 209 | SDK 主体，SF profile glyph/token 接线留集成 |
| `chat_details_test.dart` | 146 | 模块共享计划详情 + SF 我的计划薄入口 |
| `chat_engine_test.dart` | 110 | SDK，明确 App command 语义改 typed callback |
| `chat_feature_panel_test.dart` | 265 | SDK 菜单/布局；该文件末尾 SavedPlansPage 场景留 SF |
| `chat_home_ia_test.dart` | 264 | SDK 信息结构/安全/输入主体；library/settings/my-plans 导航留 SF 集成 |
| `chat_input_test.dart` | 165 | SDK，全移 |
| `chat_keyboard_focus_test.dart` | 68 | SDK，全移；宿主 IME 冒烟另留 |
| `chat_panel_motion_test.dart` | 374 | SDK，全移，保持所有中间帧断言 |
| `chat_save_test.dart` | 207 | SDK 保存/更新/副本命令 + SF 存储 adapter 集成 |
| `chat_started_snapshot_test.dart` | 211 | SDK started/finished 精确快照与幂等 + 宿主保存契约 |
| `chat_training_return_test.dart` | 130 | SDK，全移；回执插入第一帧不推挤已有行 |
| `coach_session_snapshot_test.dart` | 617 | SDK 主体；SF 旧 key/历史持久化兼容留适配测试 |
| `coach_ui_overflow_integration_test.dart` | 178 | SDK 页面 + SF profile 溢出接线集成 |
| `coach_ui_question_flow_test.dart` | 348 | SDK，全移，text/choice/form/skip/历史重建 |
| `cosmos_background_test.dart` | 43 | SDK 背景 preset；SF 配置是否使用该 preset 留接线 |
| `legacy_coach_history_test.dart` | 118 | SDK 兼容迁移 + SF 原存储导入适配 |
| `plan_card_accessibility_test.dart` | 321 | SDK UI 叶子组件/模块组合；保留 SF 主题与读屏集成 |
| `plan_card_layout_test.dart` | 497 | SDK UI 叶子组件/模块组合；已有同类 SDK 测试去重后逐条对账 |
| `plan_focus_card_test.dart` | 356 | SDK focus/saveRef/版本/保存文案组合；SF 存储集成留宿主 |
| `plan_focus_label_test.dart` | 212 | 既有 SDK PlanFocusLabel 对照去重；SF CustomPainter 接线仍测 |
| `plan_focus_session_test.dart` | 880 | SDK 主体，宿主发到对话/版本冲突接线留集成 |
| `r2_failure_bubble_test.dart` | 151 | SDK，全移；取消/失败/再试不能伪成功 |
| `safety_gate_test.dart` | 192 | SDK 流程 + SF 原安全持久化适配集成 |

相关但不整体搬的测试还有 `app_flow_test.dart`、`ai_memory_settings_test.dart`、
`local_state_storage_test.dart`、`saved_plan_versions_test.dart`、`saved_plans_expand_test.dart`、
`saved_plans_polish2_test.dart`、
`trainer_storage_test.dart`、`training_*`、`diagnostics/*`、动作库/素材/主题测试。
它们仍验证宿主壳、真实持久化、路由/诊断和媒体交付；SDK 模块新增接线不会取消这些职责。

此不可变树的 `lib/` 和 `test/` 中没有 `*.g.dart` 或 `*.freezed.dart`：生成 Dart 删除量
为 **0 行**。同一树没有已提交的整页 golden 文件，当前测试不能当作已存在的整页逐帧
像素基线。SDK 原有 16 张 UI 默认图只证明既有小组件默认路径，不证明 SF 整页搬迁。

## 5. 预计删除量：可复算但未实施

运行源估算只围绕 §2 的 5344 行，不把 §3 的共享文件和 §2 保留的我的计划 1393 行算进来。
预算 R 包括为替代这些文件而**保留或新增**的 SF 配置与适配代码，不含原本不动的
AppStore/Services/主题/图标源文件总长，也不包含 SDK 新增代码。

| R 的互不重复组成 | 预算行数 |
| --- | ---: |
| 原 `ai_coach_config.dart` 编译环境/gateway 适配 | 56 |
| SF `CoachAppProfile`、品牌主题/剪影/剂量/执行 builder 配置接线 | 180–280 |
| chat/saved-plan/safety/history/user-memory 的宿主存储适配 | 180–300 |
| AppServices/壳内新增的模块组合与导航/训练回调接线 | 180–300 |
| 我的计划继续需要的卡片/保存主题兼容小包装 | 54–114 |
| **R 合计** | **650–1050** |

因此运行源净减少为 `5344 - R = 4294–4694 行`。这是保守预算，**不是已经删除的行数**。
PlanPage 741 行、共享海报/冻结/主题 helper 的后续真实减量暂不计入；若适配预算超出，
应据实际 diff 下调，不通过扩大“待搬文件”口径补数字。

测试另算：候选基数 7931 行，建议 SF 留存/重写接线集成预算 1200–2200 行，故候选
测试净减少约 `7931 - 1200..2200 = 5731–6731 行`。这不是对测试条数的目标；实施必须
逐条列出原断言在 SDK/SF 的新位置，不能为减少行数删除行为覆盖。生成 Dart 为 0，
动作、字体、模型/海报/音频、golden 等二进制与数据不转成“代码删除行数”。

以上两种预算分开报告，不把运行源和测试相加宣传为产品代码减量。最终验收用源提交与
迁移提交之间的实际 `git diff --numstat`，并列明新增适配、SDK 新增、SF 删除、保留职责。

## 6. SF 浅/深色逐帧 0 像素验收设计

### 6.1 先封存旧页，再比较新模块

实施前从上述不可变 SF 提交创建只读验证源，使用其 pin 的原 SDK、同一 pubspec.lock、
Flutter/engine/font/media/renderer 生成旧页基准，记录每个脚本、截图和来源文件 SHA。
之后在同一环境运行新模块，不能从新模块生成基准后声称与旧页一致。

当前 SF `test/flutter_test_config.dart` 仅把 `SfCutouts.animate=false`，不包含整页 golden。
新验收须显式加载原 `assets/fonts/NotoSansSC.ttf`、Material 字体与 SF CustomPainter，
固定图片/剪影解码源与像素尺寸、DPR、viewport、textScale、locale、padding/viewInsets、
系统栏样式、假时钟/ID、输入游标相位、随机种子与 image cache 状态。天空星场沿用
`cosmos.dart:43` 的 48 星/seed 20261019、`:83` 的 33ms 节流；比较两端在相同时间轴取帧。
冻结媒体解码样本时要对两端采用相同输入，不能把模块动画本身禁用来获得全静态通过。

每个场景至少浅/深两主题、普通/减少动效两模式；主验收固定 SF 原 viewport 与 textScale，
再补窄屏/2x 文本和 IME 变化回归。每一动画按 60Hz 和 120Hz vsync 时间表逐帧捕获完整
Flutter 页面，并补事件边界 `t−1ms/t/t+1ms`，不只选起止图。零差指大小相同、RGBA
逐像素相同、差异像素数为 0；不能使用 1% 容差、裁掉有差异区域或更新基线规避。

平台 IME/系统栏另在相同设备/系统版本对照输入、返回与几何；测试内用原 MediaQuery/
metrics 轨迹复现 Flutter 内容。确定性截图不能单独冒充真机键盘/系统合成层验收。
若原媒体帧、字体或 renderer 无法复现，应标记该场景阻塞、保留原因与待取基准，不能
将其记为 0 像素通过，也不能降低门槛。所有新外观建议均留到另一项经用户授权的改版。

### 6.2 场景、帧边界与原代码证据

“补帧”是在逐 vsync 捕获以外强制增加的时点，不是只拍这些点。所有位置必须依据
源实现保留，不允许把下表当作重新设计动画的规格。

| 场景 | 强制补帧/断言 | 原依据 |
| --- | --- | --- |
| 空态、时段问候、无历史/有历史 | `t=0/1/300/600ms`；固定 morning/evening 时钟，初始 retained history 不重新入场；背景与建议语逐像素相同 | `chat_home_page.dart:118–126`、`:439–537`；`chat_timeline.dart:70–103` 的 greeting 600ms |
| 用户输入与发送、IME 到菜单接力 | 每个 metrics event 前后与所有帧；输入框/建议语/列表 viewport 不闪跳；user 入场 `0/140/280ms` | `chat_widgets.dart:106–280`、`chat_composer_dock.dart:126–360`；`chat_timeline.dart:94–95`；`tokens.dart:462` |
| 功能面板展开/收起与返回键 | `0/60/120/180/240ms`，键盘与面板同高/不同高、开闭中切换焦点、连续点菜单；panel 返回先关菜单 | `ui_polish_tokens.dart:207–212` menu 240ms；`chat_panel_motion_test.dart`、`chat_home_page.dart:314–325` |
| 普通助手消息与同批文字/卡片 | assistant `0/180/360ms`；卡片 `0/260/520ms`，逐项叠加 120ms reply stagger；稳定 key/滚动位置不变 | `chat_timeline.dart:70–103`，`tokens.dart:471/491` |
| 等待卡六阶段、取消、空 picks | 六个阶段各捕获；`0/179/180/181/430/900/1200/1400/1600ms`，检查首张剪影延迟、过渡、取消热区、4 个 RepaintBoundary 与空 picks 回退 | 已有 SDK `task_bubble.dart`、`task_bubble_tokens.dart:17–67`；SF `chat_home_page.dart:481–522` 使用现有 SDK 组件 |
| 等待→计划/推荐成功出卡 | 相对 successful edge `0/120/240/350/589/590/591/790/889/890/891ms`；240ms visual +350ms hold 后 collapse，200ms 消隐/300ms收高；前后台/route covered/新请求打断不延迟数据 | SDK `coach_delivery_transition.dart:43–48/146–149/189–222` 与 `task_bubble_tokens.dart:53–57` |
| 等待→失败、普通文字、再试/取消 | 相对失败 edge `0/150/300ms`；失败不显示成功勾；新请求/取消不让旧回执覆盖，按钮只执行一次 | SDK delivery 的 legacy 300ms crossfade；SF `chat_home_page.dart:539–562`；`r2_failure_bubble_test.dart` |
| text/choice/form 问题和 skip | 有效/无效/已回答/历史恢复、disabled、选项多行、表单编辑；取每次交互前帧与后续所有动画帧 | `chat_models.dart:280–455` 不可信历史问题重建；`chat_controller.dart:612–666`；`coach_ui_question_flow_test.dart` |
| 计划卡收/展、标签、更新/保存副本 | 旧 SF 对话卡收/展两端与所有中间帧；外壳、剪影、title、footer 不变。保留现 SDK legacy 550/450ms 编排；内部 `CoachPlanExpanded` 280ms 尺寸/60+180ms 内容时轴不能误当整卡总时长 | SDK `plan_card.dart` 的 `_Timeline` 与 `plan_expanded.dart:64–68`；SF `plan_card.dart:34–70`、`validated_plan_card.dart` |
| 发到对话、focus 替换/清空 | focus入 `0/90/180ms`、出 `0/60/120ms`，替换 title/clear hit/保存更新文案一致；第3项替换、插/删、缩时仍按同 planId/version/savedRef | SDK `plan_focus_label.dart:145–148`；SF `chat_controller.dart:723/875–908`；`plan_focus_*_test.dart` |
| 保存、更新、另存与训练后保存邀请 | in-flight/成功/失败、重启恢复、外部 savedRef 版本冲突；主按钮已保存不误禁副本；toast glyph/text 同原 profile | `chat_controller.dart:738–825/828–908`；`plan_focus_card_test.dart`、`chat_started_snapshot_test.dart` |
| 新对话、历史/快照导入与进程重建 | 清空请求同帧、flush完成帧、恢复首帧；取消旧请求、无残留计时器、旧会话不被新写入覆盖；无动画重放/闪空态 | `chat_controller.dart:264–332/365–420/1101–1138`；原 80ms 延迟持久化与 focus 的即时串行写入语义保留 |
| 对话→训练与提前退出成功 | 进场 `0/1/150/299/300ms` 与 gate post-frame；退场 `0/140/279/280ms`；不透明舞台首帧完整，源列表与输入保持冻结，退出期间无完成页闪现 | SDK `trainer_slide_route.dart:21–40/117–125`；SF `open_training.dart`、`training_transition_freeze.dart` 和 `training_route.dart` 的 activity hold |
| 训练保存失败→重试、自然练完→完成 | 按原 route/save-failed 事件顺序采每帧，失败恢复完成页不被chrome遮掉；成功 receipt 只提交一次；自然done流程与原实现一致 | SDK TrainerPlayer/TrainerSlideRoute；SF `chat_home_page.dart:204–255` |
| 训练返回后的完成消息 | 第一布局帧（包括margin/time mark）零高度，不推挤已有行；`0/1/120/240ms`，reduced `0/75/150ms`；去重相同sessionId | `chat_timeline.dart:55–68/141–206`、`chat_training_return_test.dart`、`chat_home_page.dart:231–255` |
| 安全流程、阻断、重新确认 | 每一步问题/caption、触发阻断、进入库/设置但禁止生成与开练；旧记录恢复后仍受实时安全状态制约 | `safety_script.dart`、`chat_controller.dart:961–1041`、`safety_gate_test.dart` |

减少动效单独对照原行为：不能将所有时长统一变成 0。示例：TrainerSlideRoute 原 reduced
进/退为 0；`TrainingFinishedEntry` 为 150ms；delivery 会直接完成；focus label 原有独立
降级逻辑。原实现的布局、pointer/semantics、前后台 ticker 和缓存边界同样属于保真范围。

### 6.3 三 App 上线顺序与真实门禁证据

先在 SF 换上模块并过上述完整逐帧门禁，再接 HipLab，再接托马斯。每个 App 接自己的
显式白名单、原主题/图标/剪影、保存适配和实际播放 builder；迁移不改 Coach 出计划规则、
模型工具顺序、请求参数、缓存素材节奏、手动计次分类或执行时间线。

每次真实模型验收记录所用 SDK/App full SHA、profile/catalog/白名单/素材与 builder
配置哈希、原始用户输入、卡片与执行秒数、手动估算标记、调用数和耗时。固定 5/10/20
分钟脚本以及执行时长分支已确立的独立会话数/上下限规则；迁移前后同一离线模型响应
应得到一致工具回执/计划/时间线，真实模型不能要求随机输出文本或剂量逐字相同。
所有超差、反问、中间轮失败都保留，不用失败重抽提高通过率。

视觉基线仍是 immutable SF 3eb 的原页。逻辑/执行时长的 A/B 则必须让旧页和新模块
使用同一版已审核执行回调 SDK 与相同 builder/profile；不能把旧 SDK 只校验卡片和新
SDK 双门禁之间已经批准的功能差异，混入“抽取导致的差异”。执行回调已经审核并合入
main `3fbd179063e9b8433cadd5387295ac07b7b93800`，本设计分支以它为基线，
自身增量只有文档；模块迁移不能顺带改 PlanBuilder 搜索规则。

每 App 的“计划不含名单外 ID”断言还必须检查 segments/父项、导入/恢复/编辑/替换与
开始训练入口。视觉、逻辑、模型、资源打包和设备证据分开标注：文档审核通过不等于
这些实现门禁已通过，本设计步骤不提前声称 SF/HipLab/托马斯已完成模块接入。
