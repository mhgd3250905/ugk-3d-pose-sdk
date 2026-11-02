# 第 3 批：动作库与详情下沉（2026-11-02）

**功能与相关测试完成，截图验收部分完成。** 分支 `codex/library-shared`，基于 `1071c22`；代码 `e500a54303cfdf02f430f5fe166e03f47b923743`。基准 HipLab `0f507a3`、SF `52d30ae`。

**交付。** `CoachAppProfile.library` 可选，null 保持原目录和 Coach 范围。`TrainingLibraryConfig` 配置 `scopeManifest`、分类顺序、品牌、文案；配置后 Coach 工具目录/计划准入直接使用 library 的 manifest。runtime 提供 `TrainingLibraryPage`、`TrainingLibraryDetails.open`、`TrainingLibraryActionArt`：搜索/器械/部位/类型筛选、poster 优先详情、点击才下载、失败保留 poster、自测镜像。详情预热复用第 1 批相同解码键；公共媒体走第 2 批 policy；开练用 launcher，或委托宿主原有安全/剂量/语音/保存回调。

**HipLab 临时接线。** 动作页、Coach/套路详情和自测示范入口接 SDK；library/Coach 共用可编辑的 45 项白名单来源，manifest 实例独立，无额外绑定。排除 `supine-cross-demo`，保留六方向问题、评分、比较图，该项无公共示范/详情。既有 `n-thomas-test` 仅保留 SDK 公共媒体自测演示，不进入动作库/训练/Coach。

| 验证 | 结果 |
| --- | --- |
| SDK 相关回归 | **54/54**：共享列表/详情 8、chat 14、原浏览/单动作流程 32；包括同源白名单/准入、分类文案、浏览不下载、显式播放、镜像、开练资格、宿主委托和弹层首帧解码 |
| HipLab 临时接线 | **5/5**：截图交互 2、profile 3；相关 12 文件 analyze 0 问题 |
| SDK analyze | runtime、chat 两包均 0 问题；format/diff 检查通过 |
| SF 原训练关键帧 | **2/2，32/32 浅深帧 0 像素差**，对比第 2 批已通过基线 |
| HipLab 截图 | 浅深列表/详情 4 张，浅色详情 poster 未解码；不是完整视觉通过 |
| SF 新动作库/详情对照 | 未完成，仅默认浅色列表；不能以原训练页回归代替 |
| 真实模型 | 不适用；本批展示/配置改动，以既有目录和准入内核回归验证 |

**仍与 SF 不同。** SF 默认目录为 93 个 release-visible 动作、分类条和推荐卡；本批复用 SF 内部公共包模式已有的 SDK 双列搜索/筛选界面（211 个完整动作再按 App 白名单收窄）。详情保留 SF 内容顺序、22/w800 名称、难度文案和 poster 点击行为，但使用通用主题/图标、公共首帧 poster，替代 SF 专用底板/图标/封面裁切；增加开练按钮以委托 HipLab 原业务，不宣称与 SF 旧详情逐像素一致。

**停止项。** SF 新采集首轮编译失败、次轮筛选点击超时，两轮停止。HipLab 两轮采集后发现浅色详情海报空白，最后补齐 SDK 同缓存键预热，首帧解码断言已通过；未做第三轮截图，四张旧图不能证明最终浅色详情通过。Hip 图为生产 SDK 包装层，未含宿主自测页头/底栏；均非原生播放或设备验收。

原始日志/截图/临时接线归档在本机忽略目录 `build/library-shared/`（`hip/`、`sf-baseline/`、`sf-trainer-regression-2/`），不入库。只普通推送分支，不合 main、不打 tag、不提交 App/pin、不改 Flare/托管、不生成/交付 APK、未使用模拟器或设备；构建环境留到最终 APK。

## 第 3 批收尾（2026-11-02）

**本次收尾完成；上文截图缺口和详情样式差异以本节为准。** 继续 `codex/library-shared`，起点 `803f0bd`；实现提交 `170fb3e85a7691c4cd2c1d82db1ec6f8e4764596`。基准仍为 SF `52d30ae`、HipLab `0f507a3`。

**改动。** 默认详情下沉 SF 现有配色、字距、行距、自绘图标、方形媒体舞台、弹层圆角/拖柄与动画；poster 点击才播放，不增加覆盖按钮。`TrainingLibraryConfig.showStartAction` 默认 `false`，需开练时显式设为 `true`，继续复用原 launcher 或宿主回调。新增公开 `TrainingLibraryBrowser(actions, actionArtwork, onOpenAction, config?, theme?, embedded?)`，不依赖内部素材路径或练习路由；搜索、筛选、卡片从原浏览器抽出。SF 公共包模式的 `PoseHubActionBrowser` 成为兼容适配层，HipLab 的 `TrainingLibraryPage` 直接复用同一组件；runtime/chat 均公开导出，App 只接目录、主题、素材和点击回调。

| 验证 | 本次最终结果 |
| --- | --- |
| SDK 相关测试 | **57/57**：共享列表/详情 11、原浏览/单动作流程 32、chat/profile/adapter 14 |
| analyze / 格式 | runtime、chat 两包及 HipLab 本次相关 2 文件均 **0 问题**；10 文件 format 0 改动，diff 检查通过 |
| HipLab 生产包装层 | **2/2**，浅深列表/详情 4 张均有已解码 poster；使用实际默认关闭开练按钮的配置 |
| SF 原接线 | 列表/详情 **2/2、4/4 全页 0 像素差**；训练 **2/2、32/32 关键帧 0 像素差** |
| SDK 默认详情对照 SF | **2/2**，同一 `h-squat`、浅深主题、无主题覆盖；poster 已解码，视频请求 0；媒体区外 **0 像素差** |
| 真实模型 | 未调用；本次仅展示/配置改动，目录与准入由上述既有回归验证 |

**截图及剩余差异。** 本机 `build/library-shared/closeout/` 保存日志、receipt 与截图；`library-details-eight-frames.png` 为 8 张总览。Hip 图在 `hip/{light,dark}-{library,detail}.png`，SF 原接线图在 `sf/candidate-final/sf-{light,dark}-{library,details}.png`；默认详情左右对照为 `sf/sf-vs-sdk-{light,dark}-details.png`（左 SF，右 SDK）。全部在 poster 解码后采集，修复了上文浅色详情空白的证据缺口。

剩余差异：① SF 生产默认仍用 93 项旧分类条/推荐卡；公共浏览器用双列搜索及器械/部位/类型筛选，Hip 白名单 45 项，故列表内容和布局不同，SF 公共包模式已共用新公开组件。② 公共 frame-zero poster 与 SF 旧主题海报的相机、人物尺度、阴影不同；默认详情差异全部位于媒体矩形 `(16,247,358,358)`，浅/深分别 127787/127734 像素，文字、主题、图标和布局一致。③ Hip 显式品牌主题保留自身配色/字体；截图不含宿主自测页头和底栏，不作为整 App 或原生播放/设备验收。`supine-cross-demo` 继续排除，六方向评分与比较图保留，`n-thomas-test` 仍仅为自测媒体。

只普通推送本分支；不合 main、不打 tag、不提交 App/pin、不出 APK、不改托管或 Flare，未启动模拟器或操作设备；App 已有临时接线与 WIP 保留。
