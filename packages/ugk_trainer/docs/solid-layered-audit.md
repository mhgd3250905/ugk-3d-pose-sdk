# 实色分层 UI：删除审计与迁移

审计基线为不可变提交 `e6dd32d90d0533aecf595f17f002701c0bec7d7a`（BASE），工作分支为 `codex/solid-layered-ui`。下文“旧位置”的行号全部来自 `git grep BASE` / `git show BASE:path`，不引用其他 agent 正在修改的工作区行号。范围为 `packages/ugk_trainer`、`packages/ugk_coach_ui`、训练包验收展示入口（根 `example` 只读核对，未修改）。

本轮目标版本：`ugk_trainer 0.3.0`、`ugk_coach_ui 0.2.0`。它们有意移除旧公开接口；两个版本在同一已验证提交上打 tag。main 合入与推送等待开哥另行批准。

## 交付边界

删除光学库、背景模糊、仿玻璃半透明表面、反光与描边渐变，以及对应公开参数、旧材质测试和演示资产。不得保留关闭开关、弃用别名、兼容空壳或无效字段。普通 UI 改用三级实底、1px 低对比边线与轻阴影；所有颜色和表面 token 由主题注入。

训练功能、旧版布局、媒体生命周期、按钮防闪颜色交接，以及 MorphPulse 的形变和时序保持。不能将“删除玻璃”扩大成删除全部 shader、全部透明像素或全部动画。

## BASE 依赖与资产清单

| 旧位置（相对仓库根） | BASE 事实 | 本轮处置 |
| --- | --- | --- |
| `packages/ugk_trainer/pubspec.yaml:18` | 直接依赖 `liquid_glass_widgets: 1.15.0` | 删除直接依赖，重新解析受影响 lock，不保留适配开关。 |
| `packages/ugk_trainer/example/pubspec.yaml:13-14` | 展示入口依赖本地 `ugk_trainer` | 继续使用本地包，随新版本解析依赖。 |
| `packages/ugk_trainer/example/pubspec.lock:267-274` | `liquid_glass_widgets 1.15.0` 为 `transitive`，由展示入口经 trainer 引入 | 删除后 lock 中不应残留该包。 |
| `packages/ugk_coach_ui/pubspec.yaml:12-13` | 运行依赖只有 Flutter，没有光学包 | 不虚构该包原来使用了光学库；只替换其仿玻璃语义和表面。 |
| 根 `pubspec.yaml:13-14` | Dart 层依赖 `crypto`、`http`，没有玻璃库 | 保持根业务 SDK 范围。 |
| `packages/ugk_trainer/pubspec.yaml:43-44` | 唯一受控 shader 声明为 `shaders/packed_alpha.frag` | 保留，原因见下文。 |
| `packages/ugk_trainer/docs/visuals/` | 16 张 `before-*` / `after-*` PNG，加旧 `capture-manifest.json`、`layout-comparison.json` | 删除 8 张旧 before 图；8 张 after 图全部重采实色版本，重新生成 manifest 与坐标对照。 |

BASE 受控树只有训练展示入口这一份 `pubspec.lock`；trainer 与 coach_ui 自身没有受控 lock。lock 是解析结果，不包含完整依赖边，因此不能仅凭 lock 将 `ffi`、`ffi_leak_tracker`、`jni`、`vector_math` 等通用传递包判为“玻璃专用”并强删。最终由依赖解析裁去真正不再可达的节点，再检查运行和资产清单。库内光学 shader 由外部依赖提供，BASE 没有复制一份本地玻璃 `.frag`。

## BASE 绘制路径与替代位置

下表的“新位置”先记录主 agent 已确定的接口；最终位置及验证结果见本文末尾。

| 旧位置与用途 | 处置与新位置 |
| --- | --- |
| `trainer_control_surface.dart:2,31-60`：库主题、`GlassContainer`、premium / clear 与 tint；`trainer_result_surface.dart:4,29-30,103-117`：结果页光学表面与材质 scope | 删除库适配和材质 scope。普通表面统一为 `lib/src/ui/trainer_surface.dart` 的 `TrainerSurface`；结果页也使用同一实底层级。新位置：`trainer_surface.dart:10`，结果背景组合位于 `trainer_stage.dart:83`。 |
| `trainer_header_surface.dart:27-40`：显式 `glassStyle` 旁路与旧玻璃卡片 | 删除分支和包装，不保留禁用玻璃时的旧实现。顶部原内容、padding、高度与交互由实底表面承载。 |
| `trainer_glass.dart:15-148`：`TrainerGlassStyle` 的 tint/rim/specular/blur/innerShade/contactShadow 等字段与预设 | 整套删除。新表面只读主题的实色、边线、阴影角色。 |
| `trainer_glass.dart:130-146,254`：`ImageFilter.blur` / compose 与 `BackdropFilter` | 全部删除。普通 UI 不再读取背景。 |
| `trainer_glass.dart:268-310`：`_ShadowPainter` 使用 `MaskFilter.blur` 绘制外沿；`:313-449`：`_GlassPainter` 用多层渐变模拟玻璃 | 删除手工材质。轻阴影由统一表面组件读取主题 shadow token；不保留定向高光、内反光或可调 blur。 |
| `trainer_glass.dart:456-598`：`TrainerGlassButton`；`:513-520` 的高光渐变主圆钮 | 用 `TrainerIconButton` 替代，删去 `overMedia` 等材质参数；保留焦点、语义、键盘及点击反馈。 |
| `trainer_glass.dart:604-645`：`TrainerGlassField` 与径向背景染色 | 删除公开类型和用于衬托玻璃的环境场。 |
| `trainer_theme.dart:28,76,80-81,99,120`：`glassStyle` 构造参数、字段、getter 与 `copyWith` | 删除；新增实色边线、阴影和环端点 token；`copyWith` 覆盖所有现存 token。 |
| `trainer_player.dart:888,959,1086-1090`：从 glass 配置读取边线及媒体前景色；`:1040,1066,1095,1676,1987,2112,2128,2286` 的材质/按钮调用 | 改为注入的语义 token 与 `TrainerSurface` / `TrainerIconButton`。不得靠页面内硬编码浅深色补齐。 |
| `trainer_stage.dart:91-220`：环境光、媒体边缘渐隐、径向光池和晕影；`:247-301`：`TrainerHover` | 删除玻璃衬托渐变和 `TrainerHover` 类型；舞台保留实际几何地平线与媒体摆放，使用主题实底。 |
| `ugk_play_pause_button.dart:535-638`：`materialAlpha=.72`、三段色彩渐变、反光与内边缘渐变 | 删除材质 alpha 和全部反光绘制，圆盘改为实色。保留颜色波纹交接、glyph morph、呼吸、ripple 和防闪状态时序。 |
| `packages/ugk_coach_ui/lib/src/primitives.dart:84-110,146-174,206-236`：控件、卡片和启动按钮已有普通填色 | 使用统一三级表面、主题 outline/shadow。不是删除光学滤镜，而是补足实色层级与主题注入。 |
| `packages/ugk_coach_ui/lib/src/plan_card.dart:1366-1449`：`glass` bool、不同 padding 和半透明 tonal / scrim pill；`:962-1018` 的玻璃边缘注释及落地反光 | 删除旧材质分支、半透明表面和反光字段；使用 `surfaceRaised` / `mediaLabelSurface` 等语义角色，保留展开、落地编排和命中区域。 |
| `packages/ugk_coach_ui/lib/src/theme.dart:24-25,32,57-58`：`thumb`、`mediaScrim`、`landingHighlight` | 以明确的实色层级和媒体标签承载色替代；删除旧字段，见 API 表。 |
| `packages/ugk_coach_ui/lib/src/message_widgets.dart:26-28,160` 与 `plan_card.dart:12,962,1430,1531,1837` | 清除已经不符合实现的玻璃说明，不将旧命名留作新实色实现的空壳。 |

上表中未带包前缀的文件都位于 `packages/ugk_trainer/lib/src/ui/`。最终普通表面不得出现 `BackdropFilter`、`ImageFilter.blur`、光学库导入或模拟反光的渐变 painter。

## 公开 API 迁移

`ugk_trainer/lib/ugk_trainer.dart:18,20,22` 原先完整导出材质、舞台与主题文件，因此下列删除会直接影响消费者；不是只有包内部的实现替换。

| BASE API | 0.3.0 迁移目标 |
| --- | --- |
| `TrainerGlassStyle` 与所有光学/仿玻璃字段 | 删除，不提供兼容别名。消费者把需要的普通颜色、边线、阴影迁入 `TrainerTheme`。 |
| `TrainerTheme.glassStyle` / `glass`，构造及 `copyWith(glassStyle:)` | 删除。新增必需 `border`、`shadow`、`ringKnob`、`accentSubtle`；其余主题 token 保持全部可注入，`copyWith` 同步覆盖。 |
| `TrainerGlass` 及 `overMedia` / `control` / `pressed` 材质选项 | 替换为 `TrainerSurface(theme:, child:, level:)`。层级 enum 为 `TrainerSurfaceLevel.background / panel / control`，依次读取 `TrainerTheme.background / surface / surfaceHigh`。不接受旧材质开关。 |
| `TrainerGlassButton` / `overMedia` | 替换为 `TrainerIconButton`，保持原业务 callback、tooltip、键盘与语义。 |
| `TrainerTheme.scrim` / `TrainerStageFloor.fadeClipEdge` | 删除旧参数，不保留无效配置。 |
| `TrainerGlassField` / `TrainerHover` | 删除。使用实底布局；不存在新的透明环境场或 hover 材质旁路。 |
| `TrainerControlSurface` / `TrainerHeaderSurface` / `TrainerResultSurface` 等内部库适配 | 删除或直接改为实色组合，不能留下与玻璃配置有关的参数和 scope。它们不在 BASE barrel 中直接导出，不应误报为正式导出 API。 |

`ugk_coach_ui/lib/ugk_coach_ui.dart:6-17,19,21` 导出主题、基础组件、列表与计划卡；目标版本为 0.2.0。

| BASE API | 0.2.0 迁移目标 |
| --- | --- |
| `CoachUiColors.thumb` | 删除，以 `surfaceRaised` 替代。 |
| `CoachUiColors.mediaScrim` | 删除，以不透明 `mediaLabelSurface` 替代。 |
| `CoachUiColors.landingHighlight` | 删除，不保留反光控制字段。 |
| `CoachUiColors` 主题构造 | 新增必需 `background`、`surfaceRaised`、`outline`、`shadow`、`mediaLabelSurface` 等实色/分层角色，所有组件从主题取值。 |
| `CoachChatList.topColor`（`chat_list.dart:29,39`） | 删除，顶部滚动边缘直接读 `CoachUiColors.background`。`fadeTop` 与 `topInset` 保留，它们控制功能遮罩和系统避让。 |

消费者直接使用 `lib/src/...` 的私有路径时也必须迁移，SDK 不为已删除材质保留转发文件。

## 保留例外与裁决

| 位置（BASE） | 保留理由和限制 |
| --- | --- |
| `shaders/packed_alpha.frag:5-21`；`lib/src/media/packed_alpha_video.dart:27,104-115,311-321` | RGB-over-alpha 视频透明合成。shader 读取颜色与 alpha 两半并输出预乘像素；`ImageFilter.shader` 处理媒体本身，不是模糊或背景折射。必须保留资源声明、shader、GPU 路径及对应媒体测试。 |
| `ugk_play_pause_button.dart:52-109,179-194,280-283,403-490,652-721` | 用户明确保留 MorphPulse：播放/暂停形变、呼吸、颜色波纹、点击 ripple、原环/按钮独立重绘及中断后的防闪交接。删除玻璃高光不应重写状态机或挪动按钮。 |
| `countdown_ring.dart:211-265`；`ugk_play_pause_button.dart:432` | 环进度与径向 halo 属上述明确例外。`TrainerRingPainter.glowBlur`（`:179,188,240`）只参与 `haloRadius`、峰值和方差计算，最终用 `RadialGradient` 绘制，没有实时 blur 或 `MaskFilter`。不能因字段名带 Blur 就误删动画。 |
| `packages/ugk_coach_ui/lib/src/chat_list.dart:146-164` | 顶部滚动边缘 fade 是内容遮罩，保留 `fadeTop` / `topInset`，底色改读注入主题；不是玻璃表面。 |
| `packages/ugk_coach_ui/lib/src/plan_card.dart:1945-1951` 与媒体切换 crossfade | 媒体边缘和内容切换遮罩按本轮明确裁决保留，不承担玻璃表面。标签、卡片和控件本体必须实底。 |
| `packages/ugk_trainer/example/lib/main.dart:439,451` | 原创示例人物衣服与肤色的插画着色，不是 UI 玻璃 shader。保持不变；不得拿它充当玻璃移除不彻底的证据，也不能无说明扩张成 UI 材质。 |

允许轻阴影中的 blurRadius 不等于允许背景 `ImageFilter.blur`。最终检查应按绘制用途分类，不能用“所有 Gradient / shader / alpha 必须零命中”的粗暴规则误删以上例外。透明人物、图标变形过渡和媒体生命周期也不因本次样式迁移改变。

## 测试与演示迁移清单

BASE `test/trainer_player_test.dart:226-230` 的 glassStyle/getter 断言、`stage_transition_test.dart:104-118` 的旧材质断言、`stage_r9_test.dart:174,211` 的 `TrainerGlassButton`，以及 `example/test/showcase_test.dart:150` 的旧表面 finder 都须迁移。删除纯旧玻璃参数测试；保留相应业务交互、布局、键盘、可访问性和重绘断言。

BASE `test/player_repaint_isolation_test.dart:65-92` 针对高对比与局部玻璃采样的检查须替换为新 UI 无背景滤镜边界；原 positive control 与按钮/媒体/环的隔离探针继续保留。`ugk_play_pause_button_test.dart:305-314` 的径向 halo 参数不是玻璃配置测试。`packed_alpha_video_test.dart` 也不是删除目标。

旧 `liquid-glass-design.md` 删除。`visual-review.md` 和 `visual-review.html` 改为本轮实色记录入口；不再展示旧 R4 图，不借用旧 253 项测试、旧 APK hash、旧截图或旧 106 外框结果声称本轮通过。网页演示的最终内容与新图由主 agent 更新。

## 最终检查（2026-10-26）

| 最终检查 | 状态 / 证据 |
| --- | --- |
| 版本与公开接口 | trainer 0.3.0、coach_ui 0.2.0；新构造要求和删除项见两包 CHANGELOG；无别名、转发空壳或玻璃开关。 |
| 新表面与主题 | `trainer_surface.dart:6,10,64`（层级、表面、图标按钮）；`trainer_theme.dart:5,114,135`（完整 token、深/浅默认值）；coach `theme.dart:6,43,44`。 |
| 依赖与资产 | trainer pubspec 与展示 lock 删除 liquid_glass_widgets；coach 原本无光学库。当前 package_config、插件 dependencyGraph、Web/APK 资产均无玻璃包；APK 中媒体 packed_alpha.frag 保留。 |
| 普通 UI 绘制 | 两包 lib 和展示 lib 无 BackdropFilter、ImageFilter.blur、MaskFilter.blur、旧玻璃类型/开关/光学库导入。表面实底、主题 1px 边线/轻阴影；没有仿反光 painter。 |
| 普通 UI 动效 | 位移、缩放、淡入；展开箭头用单节点静态方向交接，避免宿主自定义 icon 的 GlobalKey 重复挂载。分段进度色直接取 token，无表面色彩插值。Morph Pulse 依用户明确要求保持。 |
| 主题边界 | modal barrier、底单 drag handle/tint/shadow、弹窗和按钮反馈、独立 Tooltip 均接入 TrainerTheme；coach 输入框的填色、Android/iOS 选择色/光标/柄均接入注入 palette，主题切换保持输入状态与矩形。 |
| 布局对照 | 四状态×浅深，共 8 组；106 个外框、62 个缺席项一致，最大偏移 0dp。记录为 visuals/layout-comparison.json。 |
| 防闪与 Morph Pulse | 与 BASE 文本比较：状态机及颜色交接、glyph/ripple painter、颜色层数据结构逐字不变。仅圆盘材质与 token 读取变化；实底像素/中断快速反转/降动效测试通过。 |
| 独立重绘 | 呼吸只触发 disc/glyph，媒体只触发 media，进度只触发 ring；隔离测试与正向对照通过。 |
| 测试 | trainer 257/257，coach_ui 33/33，展示 4/4，播放 JS 协议 8/8；两包及展示 flutter analyze 无问题。Flutter 测试 concurrency=2。 |
| 构建与演示 | Web release、Android debug 构建成功；Web 已实际打开，暂停后切主题保持 35 秒与继续按钮。没有启动模拟器、安装设备或进行 iOS 构建。 |
| 新图与源制品 | 8 张实色截图均人工查看；软件 test renderer，430×932 逻辑视口、裁播放器 430×883、pixelRatio=2。源码/图/APK/Web SHA256 见 visuals/capture-manifest.json。 |
| 范围与差异 | 变更只在 packages/ugk_trainer 与 packages/ugk_coach_ui；git diff --check 通过。原工作区改动保留，main 未合入。 |

测试命令：两包分别 `flutter analyze --no-pub` 和 `flutter test --no-pub --concurrency=2 --reporter expanded`；展示入口相同，另执行 `flutter build web --release --no-pub`、`flutter build apk --debug --no-pub`；播放协议用 `node packages/ugk_trainer/tool/player_protocol_test.cjs`。

当前 Web 与截图用于实色 UI/交互验收，不证明原生透明视频、设备性能或 iOS。普通阴影的 blurRadius 不读取背景。功能遮罩、点击反馈淡入和媒体透明像素均不是仿玻璃表面。
