# SF → SDK 通用能力盘点（2026-11-02）

结论：应先把训练入口、海报与媒体生命周期组合成 SDK 默认接入路径，再下沉 SF 的按需下载/缓存和无视频打包方案，最后统一动作库/详情。SDK 已有动作库、训练路由、播放器、预取调度和聊天主体；不能将这些再次当成 SF 独有实现迁移。

本次只有文档。分支 `codex/shared-capabilities-audit`，基于 SDK `7d9be56`；没有修改任何 App、pin、实现或素材，没有合 main、打 tag、构建、安装或调用模型。后述接口名称均为建议，尚未实现。

## 固定基线与证据口径

| 简称 | 仓库 / 固定 main SHA | 本次只读位置 |
| --- | --- | --- |
| SF | [Sport-Helper](https://github.com/mhgd3250905/Sport-Helper/tree/52d30aecc74c177c438f2b7e4d7c9970d5ea591a) · `52d30aecc74c177c438f2b7e4d7c9970d5ea591a` | `E:/AII-3D/3D-Sport-AI/Sport-Helper` |
| HIP | [HipLab](https://github.com/mhgd3250905/HipLab/tree/0f507a3124436d29e8e3fbb7e2769a1d7d3c9018) · `0f507a3124436d29e8e3fbb7e2769a1d7d3c9018` | `E:/AII-3D/3D-Hip-worktrees/coach-chat-sdk/3D-Hip` |
| SDK | [ugk-3d-pose-sdk](https://github.com/mhgd3250905/ugk-3d-pose-sdk/tree/7d9be56a6c02b7a28e3d5d5cd9f6c3f1a23ac723) · `7d9be56a6c02b7a28e3d5d5cd9f6c3f1a23ac723` | 审计工作树 `F:/codex-worktrees/shared-capabilities-audit/3D-Pose-SDK` |

下文 `SF` / `HIP` / `SDK` 后的路径、行号均相对上述固定 Git 树，不引用其他分支或本地未提交版本。HIP 原目录 `E:/AII-3D/3D-Hip` 的 WIP 未参与比对。扫描覆盖 App 的 `lib/`、原生媒体适配、资源声明、构建工具及相关测试；按实际入口区分活跃路径与兼容分支。此处“未发现”仅指固定源码中的接入情况。

双方实际都 pin SDK `7d9be56`：SF `pubspec.yaml:16` 起仍同时依赖旧 `ugk_trainer` 与 runtime；HIP `pubspec.yaml:35` 起使用 runtime。HIP 体积不能归因为“SDK runtime 自动带入全库”。

必须保留的五个事实：

1. **动作库差异主要是驱动和页面不同，尚无证据证明 HIP 白名单数量错误。** HIP 内容 46 项，库筛掉 assessment-only 的 `n-thomas-test` 后为 45，AI 也显式授权 45；两者独立生成。SF 的 PoseHub 主库页面已经是 SDK `PoseHubActionBrowser`。
2. **HIP 已有局部静态预热、poster 首帧遮罩和暂停保帧。** 缺口是统一训练入口、路由 gate、同 key 全屏预热、下载缓存接线；不能记为全部从零。
3. **图标闪烁的根因尚未复现。** SF `lib/ui/theme/sf_icons.dart:65` 起是自绘图标，SDK `ugk_play_pause_button.dart:493` 为 CustomPaint；未发现 SF 独立的“按钮图标预缓存”实现。将图标/字形首次绘制列入防闪批定位与验收，不能预先认定缺少图片缓存就是原因。
4. **选姿 standing 与视频第 0 帧并非同一个承诺。** SDK `packages/ugk_trainer_runtime/lib/src/pose_hub/pose_hub_pack_image.dart:7` 明确保留源封面的姿势，`:23` 仍引用旧包 standing。SF themed 路径有对应视频首帧生成凭证，但不能据此声称全部 PoseHub standing 都已逐一对齐。
5. **体积证据分层。** 本次 Git 树检查：HIP `assets/` 跟踪 94 个 MP4，SF 跟踪 0 个。HIP `docs/coach-chat-sdk-2026-11-02.md:49` 记有 106,781,267 B 的历史 APK 回执；本次没有重新打开或测量 APK，不能据源码推出具体可节省多少 MB。

## 包归属原则

| 包 | 当前职责 / 本次建议 |
| --- | --- |
| `ugk_coach` | 纯 Dart 的 scope、目录、计划、剂量、安全及执行时长契约；继续提供唯一授权集合。 |
| `ugk_trainer_runtime` | 唯一引擎、播放/语音、原生插件、训练 UI/路由；通用 launcher、poster/presenter、v3 下载缓存与预热应在此收敛。现有 PoseHub 库/单练也在此，优先扩展现有组件。 |
| `ugk_coach_chat` | 聊天、计划详情、训练往返和宿主绑定；消费 runtime 的共享能力，提供聊天入口的默认组合与可选收藏/表单页。 |
| `ugk_coach_ui` | 无引擎、无业务存储的展示 DTO、列表/卡片/详情部件；不为动作库反向依赖 chat 或 runtime。 |
| `ugk_trainer` | 兼容导出及历史全量动作素材；**不向此包增加新的实现或将它作为新 App 的共享能力依赖**。 |

依赖方向保持 `coach ← runtime ← chat`（chat 亦消费 coach_ui）。SDK runtime 不读取 `CoachAppProfile`；配置类型定义在所属底层包，由 profile/组合层引用。旧包资源路径保留兼容，新宿主显式提供自己的 poster/目录。

## 清单 A：训练进出与动作切换

表中“端口”是 App 应提供的数据/业务回调；缓存键、生命周期和调度由 SDK 承担。

| ID / 通用能力 | SF 位置、当前行为 | HIP main 现状 | 建议归属与 App 配置端口 |
| --- | --- | --- | --- |
| A1 统一开练与重复点击去重 | `SF lib/ui/open_training.dart:16`、`:58`：锁覆盖 poster decode、onStarting、push/pop、route.completed；`:116` 准备时后台化可放弃进入。 | `HIP lib/hip/ui/hip_app.dart:569`、`:1467` 分散普通/快速入口；AI 另走 `lib/hip/ui/coach/hip_coach_chat_page.dart:90`。 | runtime 默认 launcher，chat host action 委托；App 提 plan/practice adapter、onStarting、结果存储、提示文案，不再逐入口写锁。 |
| A2 训练准入与安全提示 | `SF lib/ui/open_training.dart:36` 检查安全、空计划、未知项和 trainingDefinitionComplete。 | `HIP lib/hip/ui/library/drill_detail_page.dart:19`、`hip_player_page.dart:32` 有髋部疼痛/方向限制；聊天已有 scope。 | runtime launcher 消费现有准入结果/`canStart`；App 提业务安全建议。白名单沿目录/工具、计划准入、打包三处现有边界，不增第四套防线。 |
| A3 入出场媒体只显示 poster | `SF lib/ui/player_page.dart:99`、`:116`、`:174` 把 startGate、canPlay、退出 retirement 接入；`single_practice_page.dart:170` 做同等处理。 | `HIP lib/hip/ui/hip_player_page.dart:351` 未传 startGate；`:381` 仅以 `!request.paused` 控制视频。 | runtime 默认 presenter 自动连接 route control；App 提媒体描述/主题。动画期媒体区保持 poster，整页按钮与布局从首帧稳定存在。 |
| A4 路由、退出保存失败恢复 | `SF lib/ui/training_route.dart:15` 继承 SDK route，App 主要加诊断。SDK `packages/ugk_trainer_runtime/lib/src/ui/trainer_slide_route.dart:100`、`:193` 已管 gate/canPlay/退出/失败恢复。 | `HIP lib/hip/ui/hip_app.dart:569` 用 HipRoute rise/expand；AI `hip_coach_chat_page.dart:112` 同样未用该组合。 | 复用 runtime TrainerSlideRoute，launcher 给默认连线；App 可配置主题、减少动态效果、save 回调，不能复制另一套路由引擎。 |
| A5 冻结源页、保留滚动与交接 | `SF lib/ui/training_transition_freeze.dart:37` 保留 retained subtree；`lib/main.dart:281` 包宿主 listener；`lib/app/coach_chat.dart:241` 将短活动转给 holdTransition。 | `HIP lib/hip/ui/coach/hip_coach_chat_page.dart:90` 已 holdTransition/onStarting/route.completed；这不等于 TrainerPlayer startGate。 | chat 已有 freeze/activity，runtime 发短转场事件；共享组合接线。App 壳仅观察活动，不在整个训练期间冻结源页。 |
| A6 入场前推迟媒体准备 | `SF lib/app/gated_posehub_media_preparer.dart:8` 等 gate 与转场 idle 后订阅，取消不复活旧请求。 | HIP 无下载 preparer 接入；本地视频随播放器创建。 | runtime 的既有 preparer 装饰器/默认 presenter；App 提 delegate，SDK 负责 gate 与取消。 |
| A7 冷缓存与换动作遮罩 | `SF lib/ui/cached_exercise_media.dart:573`、`:742` 等 first-frame/真实回环再揭开 poster；`exercise_video.dart:84` training 启用该策略。 | `HIP lib/hip/ui/hip_widgets.dart:389`、`:489` 已有首帧遮罩/保帧，但无统一训练转场门控。SDK `media/drill_media_view.dart:408` 已有 handoff。 | runtime 合并成熟 presenter 与已有 handoff；App 提真实 poster、fit/mirror、媒体角色；避免再建第三套首帧检测。 |
| A8 暂停、覆盖、后台与解码器退休 | `SF lib/ui/cached_exercise_media.dart:295`、`:624` 观察 lifecycle/可见性，取消 prepare，endOfFrame 后释放 pin；保存中保留原画面。 | `HIP lib/hip/ui/hip_widgets.dart:343` 已 stop/endOfFrame；`hip_routes.dart:674` 按 Tab/当前路由控制播放。 | runtime 统一 surface ownership/retirement；App 壳提供可见性，媒体不再由各 App 自建 controller/Expando 协调。 |
| A9 媒体失败可继续训练 | `SF lib/ui/exercise_video.dart:123` 失败文案；cached presenter `:619` 只退媒体，计时/voice 仍由 SDK 管。 | HIP 当前依赖内置素材；尚无下载 miss/offline/error 统一接线。已有 HipMediaPolicy 可关闭视频。 | runtime 保留 poster、语音和计时；App 配字符串/重试与训练准备政策。不要把下载失败变成整个训练失败。 |
| A10 按钮/图标首绘防闪 | SF 自绘 `lib/ui/theme/sf_icons.dart:65`；SDK 播放按钮 `packages/ugk_trainer_runtime/lib/src/ui/ugk_play_pause_button.dart:493` 自绘；未找到专门图标 precache。 | HIP 训练 UI 使用 SDK 按钮；真机已报告一帧闪图标，源码盘点不足以定根因。 | runtime 承担共享按钮状态/首绘修复；App 提 icon builder/字体资产。先复现定位，确有资源首次绘制问题才统一预热，不要求 App 自行“补 precache”结案。 |

## 清单 B：海报、瘦身、按需交付与缓存

| ID / 通用能力 | SF 位置、当前行为 | HIP main 现状 | 建议归属与 App 配置端口 |
| --- | --- | --- | --- |
| B1 同 key 静态图预热与保留解码帧 | `SF lib/ui/training_poster_image.dart:7` 使用屏宽×DPR、同 ResizeImage key、候选回退；`:108` 保留 ImageStream，避免普通更新重开 codec。 | `HIP lib/hip/ui/hip_widgets.dart:514` 有 hipPrecache；`coach/hip_coach_visuals.dart:56` 接 preloadPoster；自测/引导也局部预热，训练首项/后续项未统一。 | runtime poster provider/preloader；App 提 action→主题/角色/asset或ImageProvider，SDK 统一 bundle、decode宽与key。chat 复用已有 visual.preloadPoster。 |
| B2 可见项、首动作预热 | `SF lib/ui/training_visible_poster_preload.dart:28` 观察实际 standing 请求；`posehub_library_page.dart:48`、`chat/training_card_media.dart:25`、`plan_page.dart:69` 接入。 | HIP 已有聊天 preloader，库和训练入口独立。SDK chat 的 `packages/ugk_coach_chat/lib/src/ui/training_visible_poster_preload.dart:26` 也已有可见请求观察。 | runtime 共享 resolver/prewarm，chat/库复用调度；App 给可见项/首项，避免全库 decode 和硬编码旧 standing 路径。 |
| B3 poster 与视频首帧/主题/构图对齐 | `SF tools/media/build_on_demand_assets.py:58`、`:320` 从校验过的对应主题视频提第0帧并记 sourceSha256；`cached_exercise_media.dart:710` 用 playbackPoster。训练候选 `training_poster_image.dart:17` 仍优先 standing。 | `HIP lib/hip/ui/hip_widgets.dart:373` 用 posterTime；`lib/core/media/media_view_native.dart:128` 与 `assets/drill_media/player.js:92` 按时间 seek，已有 fit/position 约定，未查验实际逐视频对齐。 | 构建工具保留原视频/帧来源凭证，runtime 分清 thumbnail/选姿cover/playbackPoster；App 提 time/variant/fit。不可把所有 cover 改作0帧，也不能把静态裁剪套到视频。 |
| B4 不内置视频、精确资源打包 | `SF pubspec.yaml:76` 起静态目录声明；`tools/media/build_on_demand_assets.py:242`、`:315`、`:373` 生成主题静图/索引并去旧视频；固定树跟踪 MP4 为0。 | `HIP pubspec.yaml:77`、`:82` 整目录纳入 light/drill_media；94个跟踪 MP4。HIP 已依赖 runtime，额外体积主要仍须审实际 App 资产。 | SDK `tool/` 复用闭包工具的白名单/receipt，新增显式 poster-only + 远程视频引用策略；App 提正式 scope、媒体发布清单、必要语音/字体/许可。不删训练定义换体积。 |
| B5 离线静态、显式播放、缺图回退 | `SF lib/ui/cached_exercise_media.dart:79` 只查本地缓存、不因滚动下载/建 decoder；`:775` GuidePreviewCoordinator 先 retire 再 claim 单一播放位。 | HIP 的 videoEnabled 是全局本地视频开关；不等于依据缓存/网络自动 poster-only。 | runtime 统一 preview/coordinator；App 配离线策略、已缓存源、显式播放回调。预览离线默认 poster；已下载训练视频可复用，不把离线理解为强制抹掉可用缓存。 |
| B6 缺失 poster 的本地提取 | `SF lib/app/guide_poster_cache.dart:8` 本地 file/asset、revision/frame0、in-flight 合并、15秒超时；`SF android/app/src/main/kotlin/com/ugk/smartfit/GuidePosterExtractor.kt:20` 起提帧，失败不阻塞正文。 | HIP 有内置 poster/本地播放器，未发现对应缓存提帧服务；缺图不应靠滚动自动下载视频解决。 | runtime 原生插件的可选 fallback；App 给已验证的本地源/revision，其他平台保留静态错误回退。正常路径优先发布方提供帧。 |
| B7 v3 按需下载、完整性与进度 | `SF lib/app/posehub_media_repository.dart:22`、`:333` 同内容合并/并发/mirror；`posehub_media_repository_io.dart:458` 校验 bytes/SHA 后发布；`posehub_media_preparer.dart:109` 以 verified completion 发 ready。 | 未发现 HIP runtime download/ensure/prefetch 接入；`tools/pose_hub_sync.py` 是开发期同步。 | runtime 给现有 PoseHubMediaPreparer 默认 repository 实现；App 提 catalog/版本/镜像/存储根/网络策略。已有旧 TrainingMediaRepository 不等于此v3实现，应收敛适配，不再加第三套系统。 |
| B8 开练前准备与训练期预取 | `SF lib/app/services.dart:99` 按计划签名/epoch/原序去重、2 workers，预取不阻塞计时/语音；`player_page.dart:47`、`plan_page.dart:189` 触发。聊天 listener `services.dart:278` 仅 media!=null 时挂，并非所有 PoseHub 聊天链路都主动预取。 | HIP 仅内置素材，无按需队列。SDK `packages/ugk_trainer_runtime/lib/src/pose_hub/pose_hub_media_prefetcher.dart:43` 已有训练期优先调度。 | runtime launcher/preparer 统一 preflight 与既有预取器；App 配首项/后续窗口、联网许可、超时及离线训练策略。等待首项校验准备是可选策略；旧调用保留SF非阻塞/明确降级语义，后续异步预取。 |
| B9 全局视频缓存预算与播放保护 | `SF lib/app/posehub_media_repository_types.dart:55` 上限300,000,000 B；`posehub_global_video_cache_io.dart:432` 按mtime淘汰owned且未pin项；`:467` clear 保留未知文件/播放中项，不清图片和私人记录。 | HIP 无运行期视频缓存管理接入。 | runtime 共享 cache service，保留跨版本预算、pin、取消/清理的顺序；App 给预算/根目录，不按 App 复制缓存算法，也不删不明文件。 |
| B10 缓存设置与网络偏好 | `SF lib/ui/training_media_settings.dart:8`、`:70`、`:122` 显示容量、busy防重/确认/错误；`about_page.dart:183` 设置入口。旧 repository 支持 wifiOnly。 | HIP 没有同等下载缓存管理入口，现有视频开关只控制内置播放。 | runtime 提 bytes/clear/network policy，提供可选设置 section；App 壳决定入口、主题、持久化偏好及文案，不绑定 SF About 页。 |
| B11 实物包体与资源门禁 | `SF tools/media/report_release_apks.py:32` 按 ZIP 分类、ABI/AOT/语音hash检查；`tools/coach/build_release.ps1:61` split-per-abi/JNI检查。旧 `report_apk_size.py:46` 仍固定413文件/32视频，是历史方案，不能充当当前零视频门禁。 | HIP 历史文档记录106,781,267 B；当前有内置视频与正常字体/音频，本次不测包。 | SDK `tool/` 泛化实物 AssetManifest+ZIP、白名单、无MP4、必要poster/语音/字体/插件门禁；App 给ABI/构建模式/清单/预算，数值按真实产品决定，不能硬搬SF固定计数或45MB作为所有App标准。 |

现有 `SDK tool/trainer_asset_closure.dart:11` 是媒体闭包工具：`SDK docs/trainer-assets-closure.md:65` 起仍要求真实视频输入，`:139` 起输出所选媒体与standing。runtime-only 已拆好不代表这个工具已有无视频模式；第2批需要显式扩展策略，不能直接向App承诺一键poster-only。

## 清单 C：动作库、详情与计划入口

| ID / 通用能力 | SF 位置、当前行为 | HIP main 现状 | 建议归属与 App 配置端口 |
| --- | --- | --- | --- |
| C1 同一白名单驱动动作库与AI | `SF lib/ui/library_page.dart:34` 有 PoseHub catalog 即委派；`posehub_library_page.dart:48` 使用SDK库；AI `lib/app/coach_chat.dart:42` 另建scope。库组件本身接受catalog，不能假定它自动读取chat manifest。 | `HIP lib/hip/domain/hip_library.dart:20` 独立按video/kit过滤，排除自测；`lib/hip/coach/hip_coach_profile.dart:13` 另列45项。 | coach scope为唯一授权源，runtime使用已投影目录；App只提供正式 manifest。库可见集、可规划集、可开练集分别展示，但不能扩出授权集；不再以“本地有视频”作为入库条件。 |
| C2 分类、搜索、排序和列表布局 | SF主链复用SDK筛选；SDK `packages/ugk_trainer_runtime/lib/src/pose_hub/pose_hub_action_browser.dart:153`、`:214` 固定器械/部位/类型及中文文案；SF无catalog fallback在 `library_page.dart:38`。`SF lib/app/coach_chat.dart:140` 虽传initialCategory，但PoseHub分支委派后 `posehub_library_page.dart:49` 未转发，当前主链并未兑现该参数。 | `HIP lib/hip/ui/library/practice_page.dart:73` 是动作/套路/我的；`library_widgets.dart:48` 髋方向/场景/方法/级别和中英搜索。 | 扩展runtime现有browser；纯展示部件可落coach_ui。App配category id/title/order/成员或筛选、初始项、搜索别名、排序、icon/strings；髋自测Tab留宿主slot。 |
| C3 动作详情、剂量与单练 | `SF lib/ui/library_page.dart:128` 走共享详情/单练；`posehub_library_page.dart:58` 回调统一openTraining。SDK `pose_hub_action_browser.dart:571` 单练已收 startGate/mediaBuilder。 | `HIP lib/hip/ui/library/drill_detail_page.dart:109`、`:178`、`:304`、`:367` 自有安全/媒体/剂量/加入组/单练。 | 复用runtime单练与详情，通用展示复用coach_ui；App配可显示字段、dose policy、onAddToPlan、安全建议与统一launcher，业务疼痛规则留HIP。 |
| C4 推荐卡、详情、训练同入口 | SF `lib/app/coach_chat.dart:232` AI详情已是 SDK CoachChatPlanDetailsPage；训练通过openTraining。 | HIP 已用SDK chat和45动作scope，训练 adapter 仍使用HipRoute/HipPlayerPage。 | chat 默认 host actions 接同一scope/media/launcher；保留自定义导航端口，所有入口共享同一媒体准备及训练生命周期。 |
| C5 收藏、展开、编辑与训练往返 | `SF lib/ui/chat/saved_plans_page.dart:242`、`:488` 原地展开/首项预热，复用SDK卡；`coach_chat.dart:153` 连接查看/rename-delete/训练。 | `HIP lib/hip/coach/hip_coach_chat_storage.dart:13` 已接 CoachPlanStorageAdapter；`library/group_editor_page.dart:41` 起有稳定key、删除事务与保存；套路页支持复制。 | 后续chat可选收藏页/通用编辑部件；沿现有storage adapter，App存储迁移、routine格式和入口留宿主，不复制SF AppStore。 |
| C6 自定义计划、模板与最近记录 | `SF lib/ui/custom_plan_page.dart:39`、`:215` 表单/前5条记录；`coach_chat.dart:190` 是活跃入口，表单→旧PlanPage→GuideMedia仍可达。 | HIP 自建组与套路编辑已存在，非SF相同训练表单；评估/髋目标是业务内容。 | 后续chat表单渲染+coach确定性模板adapter可选；App给模板、字段/场景/器械/标签、store，不强制采用SF模板或整体换壳。 |

## 清单 D：其余可共享体验与应保留的边界

| ID / 通用能力 | SF 位置、当前行为 | HIP main 现状 | 建议归属与 App 配置端口 |
| --- | --- | --- | --- |
| D1 结果保存、失败重试与完成反馈幂等 | `SF lib/data/app_store.dart:406` 按sessionId upsert且保留feeling，持久化后更新内存；`services.dart:185` 完成反馈不产生coach turn。 | `HIP lib/hip/ui/hip_player_page.dart:451` onFinished→saveTrainerSession，包含疼痛阶梯/感受；`lib/hip/control/hip_store.dart:258` 已按sessionId处理，不能记为没有保存去重。不得直接换成SF历史模型。 | runtime/chat明确结果回写契约及重试语义；App提供异步持久化adapter、pain/feeling业务投影，数据迁移留宿主。 |
| D2 动作问题标记/用户手动导出 | `SF lib/ui/action_issue_actions.dart:10` 点击即固定actionId/time，busy与late form保护；`diagnostics/action_issue_store.dart:60` 串行存储；`action_issue_export.dart:59` 导出。 | HIP固定树未发现同等 issue capture/form/export链；已有SDK媒体/训练回调可供接入。 | runtime复用DrillMediaPlaybackHandle抓上下文，通用表单可选；App配开关/标签/存储/手动导出端口，不自动上报。 |
| D3 运行日志、脱敏与导出 | `SF lib/diagnostics/runtime_log.dart:34`、`:236` 有安全字段与保留上限；`developer_log_sanitizer.dart:55` 递归清洗；`runtime_log.dart:343` 后台编码/转场idle写盘。 | HIP `lib/hip/coach/hip_coach_chat.dart:97` 有observer适配，未发现SF完整运行日志设置/导出组件接入。 | runtime/chat提供typed observer/sink与可选清洗/导出适配；App给开关、保留策略/存储目的地，不把身份、密钥或SF网关配置下沉。 |
| D4 训练/媒体/模型诊断关联 | `SF lib/diagnostics/training_log.dart:25`、`training_media_log.dart:20`、`coach_chat_diagnostics.dart:130` 只读关联operation/token/耗时；snapshot archive最多5份。 | HIP已有usage/observer和测试导出，非SF同等可观察链；无必要为盘点追加生产诊断系统。 | 分别由runtime/chat发稳定事件，App提供sink与保留/导出政策；可选工具消费，不强制新App带整套实验页。 |
| D5 转场性能与首帧原始证据 | `SF lib/diagnostics/training_transition_timings.dart:80`、`:147`、`:273` 内测采原始FrameTiming；route wrapper关联entry/exit/save_failed。 | HIP固定树未见对应训练转场采集器；用户真机闪帧现象尚无本次复现记录。 | runtime事件+SDK诊断工具/示例；App提供开关/环境信息/导出路径。不能用单测/RAF/静态图代替真机帧结论。 |
| D6 静态alpha卡片取景稳定 | `SF lib/ui/alpha_bounds.dart:7` 限定不可变cover/thumb；`alpha_artwork.dart:160` 准备bounds后首帧一致取景，缺失/过期退原图，不裁视频poster。 | HIP `lib/hip/ui/hip_widgets.dart:66` 起已有HipMediaFrame/Thumb/FocusImage；未证实与SF相同bounds索引机制，不判定全无静态取景支持。 | coach_ui/runtime可选静态artwork provider与工具metadata；App给asset/index；保持视频/播放poster原构图。 |
| D7 语音、节奏、保活与共享聊天 | `SF lib/voice/just_audio_output.dart:10` 继承SDK仅加诊断，`voice/session_runner.dart:1` 重导出；首页 `lib/ui/chat/chat_home_page.dart:19` 是SDK CoachChatPage。 | HIP TrainerPlayer已传voice，聊天亦为SDK；髋自测语音、疼痛反馈和连续天数是产品内容。 | 这些底座已共享，只统一遗漏接线；App配voice source、通知名/icon、文案/主题。SF旧screen_awake只有定义无使用，不作为独有活跃方案迁移。 |

盘点共 **34 项**（A10+B11+C6+D7）。以上包括待下沉、已共享但接线不一致、双方已有不同实现三种事实，不等于需要新增34个机制。品牌色/字体选择、图标语言、商店/账号/网关、模板内容、髋评估/疼痛处方/连续天数、App导航壳不列为通用默认实现。

## CoachAppProfile 扩展与宿主端口

现状：`SDK packages/ugk_coach_chat/lib/src/core/app_profile.dart:19` 只有 appId/revision、scopeManifest、coachProfile、conversationPolicy、executionTiming、strings、visual、doseOverrides。已有 `visual` 的 exerciseFor/assetResolverFor/mediaBuilder/cutout/preloadPoster/previewBuilder（`src/theme/chat_theme.dart:97`）；已有 `CoachChatHostActions`（`src/core/chat_bindings.dart:310`）与 storage adapters。扩展应复用这些端口，不另开一套全局配置或平行白名单。

建议增加三个**可选、默认null、旧行为不变**的配置分组；下列为设计名，不能作为当前可调用API：

| 提案字段 | 内容 | 边界 |
| --- | --- | --- |
| `library` | 分类/排序/初始分类、搜索别名、详情字段/剂量展示、列表空态/不可开练说明、可选宿主slot。 | 授权集合始终引用现有scopeManifest；分类不是第二份授权名单。可规划/可预览/可训练能力是同一授权动作的状态，缺视频不应把离线可见poster从库移除。 |
| `trainingExperience` | 选用共享launcher/route/presenter、poster-first、预热窗口、入出场与保存失败处理的策略；必要的theme/icon builder。 | 核心计时仍是现有executionTiming/SessionBuilder；不加另一套时长估算。Hip疼痛/业务安全经宿主准入回调。 |
| `mediaPolicy` | 预览离线poster、按需准备/预取范围、首项准备失败的允许降级政策、主题/媒体角色、缓存预算和网络偏好默认值。 | 发布清单、源URL、asset root、缓存实例、网络探针、storage与export函数由bindings/服务组合注入；凭据不进入profile。 |

新增共享媒体服务组合建议放 `CoachChatBindings` 同层，封装 resolver/preloader、preparer/repository/cache，并给已有 `visual.preloadPoster` 等端口提供默认委托。runtime独立使用同一底层配置/服务，不反向导入chat。共享动作库/训练提供默认host action，App仍可覆盖壳/导航；新App选用此组合即可获得接线，不能要求每App再复制SF的openTraining和StreamController。

宿主只需提供：正式scope/目录及分类内容；媒体发布描述和下载源；主题/图标/文案；业务准入；plan与结果存储adapter；设置入口/网络偏好持久化；可选诊断sink。保持默认兼容后，旧App必须在后续获批的迁移批显式选用共享组合，单纯更新pin并不能自动替换它自己的页面和媒体builder。

## 拆批建议与验收边界

| 批次 | SDK交付范围 | 主要验收 / 不扩范围 |
| --- | --- | --- |
| **1：防闪与首帧接线** | A1–A10、B1–B3；复用现有route/gate/handoff，抽SF launcher/poster/presenter；明确standing与playbackPoster角色，先定位按钮闪帧。 | SDK关键状态测试/既有golden；入/出、动作切换、冷/热静图、暂停/覆盖、退出保存失败、浅深与减少动态效果关键帧。后续App接入时做Android真机记录确认无一帧错图/按钮，不预建全刷新率矩阵，不据源码声称已修真机。 |
| **2：瘦身和按需媒体** | B4–B11及A6/A9：SF v3 repository/cache下沉，复用SDK preparer/prefetcher，补poster-only资源投影和可选缓存设置section；品牌格式/路径参数化。 | 最小宿主实物AssetManifest+APK ZIP验证无MP4、名单外资源为0、必要poster/语音/字体保留；同ABI/build条件比体积。首练按需下载、hash/bytes完成才ready、离线poster、复用/取消/网络限制、清理与播放pin行为。实际App节省量待其授权迁移后重新测，不承诺统一45MB。 |
| **3：动作库与详情** | C1–C4，复用PoseHubActionBrowser/SinglePractice/coach_ui；增加profile分类、排序、文案/slot、白名单目录与同一launcher/媒体服务。 | SF219授权/211可规划与HIP当前正式45项分别验证；库/推荐/详情/单练范围一致，App分类内容可以不同。缺视频仍能离线看poster，未可执行项说明清楚，既有剂量与安全不丢失。不得用旧“HIP45候选”文档覆盖当前App正式配置。 |
| **4：可选共享体验** | C5–C6、D1–D6：收藏/编辑/表单、issue capture、日志与性能示例；先立adapter再逐页迁移。D7以复用既有底座为主。 | 每个组件独立验收旧数据/保存重试/用户手动导出；HIP自测、疼痛规则与SF模板不合并为默认业务。避免前三批扩成整体换壳。 |

第1、2批优先于第3批。第1批媒体角色/resolver契约供第2批复用；缓存底层可独立准备，但不在两边各养一套新实现。App迁移、pin升级、APK与设备验收均需另批执行；本审计没有这些变更。

## 本次验证

核对三个固定SHA和只读App工作区，逐项交叉检查源码位置/活跃入口/配置及资源声明，检查文档引用路径与行号、`git diff --check` 和 docs-only变更范围。没有运行App全量测试/analyze、模型、构建或设备操作；纯文档盘点不产生新的功能通过数或真机通过结论。
