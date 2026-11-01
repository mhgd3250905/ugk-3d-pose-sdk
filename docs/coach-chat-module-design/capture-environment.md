# 第 3 批关键状态帧采集环境

原页来源为 SF `3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10`。采集器只读取 SF，
将源码、已有素材、已解析依赖的测试副本和输出放在当前 SDK 的 `build/`，不改 App/pin。

```powershell
pwsh -NoProfile -File tool/chat_capture_sf_baseline.ps1 -OutputDirectory build/chat-extract-baseline/sf-3eb2a9e-new
```

原页可在 SDK 侧自行渲染，不需要 SF Agent 另采。正式基线是本地
`build/chat-extract-baseline/sf-3eb2a9e-v7/`，两个主题采集测试均通过，22 张 PNG 已封存。
v1–v6 是采集开发过程，不能作为验收基线；v6 发现了框架与 engine 工具链混用，v7 在
任何候选像素对比之前统一完整工具链重采。后续不因候选差异改原页或更新这份基线。

| 项目 | 两边共用值 |
| --- | --- |
| Flutter / Dart | 完整 Flutter 3.44.7 / Dart 3.12.2；framework `84fc5cbb22`，engine `69c8c61792` |
| 工具路径 | `E:/AII-3D/3D-Sport-AI/deliveries/coach-ui-011-review-20261024/flutter-3.44.7/bin/flutter.bat` |
| Renderer | `flutter_tester` 的同一软件渲染环境 |
| 视口 | 390 × 844 logical px，DPR 1；top/bottom inset 各 24 |
| 字体 | SF 原 `assets/fonts/NotoSansSC.ttf`，实际 FontLoader 加载 |
| Controller 时钟 | `2026-10-30T12:00:00`；原页 TimeMark 使用的实际采集日期另存每张 JSON 的 `captureDate` |
| 背景与动效 | 原静止 48 星（原 seed），正常动效；不建立 ±1ms 或刷新率矩阵 |
| Flavour / flags | internal；`SMARTFIT_ALPHA_CARDS=true`、`SMARTFIT_POSEHUB_PACK=true`、`UGK_INTERNAL_MEDIA_PREVIEW=true` |
| 视觉基线依赖 | SF 原固定 SDK `700d010`；候选只在 SDK 测试宿主的 packages 配置指向当前 SDK 实现 |
| 素材 | SF 原 PoseHubAssetBundle / PoseHubBundledImages 与已有原图；缓存写 SDK build，未用空占位图 |

采集器从 SF 的既有 package_config 找出匹配的完整 Flutter 工具链，也可显式传
`-FlutterCommand`。该工具链须与 framework entries 一致，不能只换启动命令。
已解析插件仍从原缓存读取；不在 SF 仓库执行 pub get、测试或写缓存。

浅、深各 11 个关键帧：`empty`、`waiting-250ms`、`plan-collapsed`、
`plan-expand-280ms`、`plan-expanded`、`recommendations`、`focused-saved-plan`、
`training-enter-150ms`、`training-enter-300ms`、`training-exit-140ms`、`training-return`。
训练帧保留整个 390 × 844 原 PlayerPage 和来源页视口，没有裁掉控件或背景。

每张 PNG 旁的本地 JSON 保存：采集日期、控制器时钟、挂载后的 fake-clock 时刻、原话、
显示消息、完整 plan、动作 ID 和 Core snapshot。环境/版本、模型 fake、素材与日志也留在
同目录，不入库；只提交采集脚本和本清单。有限交付过渡先完成，再等真实解码/bounds
计算并绘制稳定帧；等待和中途展开仍按指定时刻采集，不改原动画数值。

候选像素 harness 通过正常 snapshot/legacy 恢复 canonical 计划，不重跑配时改变剂量。
仅测试宿主可覆盖控制器的只读 suggestions 展示值，以重现原 live 帧；不增加生产 setter，
不改变恢复或 live-send 语义。等待帧由真实 pending FakeLlm 驱动。这是 UI 展示状态
fixture，不能替代真实模型、业务、设备播放或性能验收。

计划展开、收起、推荐、已存计划和开练保持同一个页面及滚动状态；各阶段仍恢复原帧的
真实 snapshot/消息。两边预缓存同一 cover/thumbnail/standing。训练舞台由测试宿主保留
原 SF `openTraining` / PlayerPage，比较模块发起回调前后、来源页冻结和完整路由视口；
不把它写成各 App 已迁移或真机媒体播放验收。

候选采集复用已冻结的环境和逐帧输入，比较器使用 Flutter 默认的零差异阈值：

```powershell
pwsh -NoProfile -File tool/chat_capture_candidate.ps1 -OutputDirectory build/chat-extract-baseline/candidate-new
```

可用 `-Frames plan-collapsed,plan-expanded` 单独重现定位中的帧；完整收尾不传 `-Frames`。
候选 PNG、比较结果和差异图仍只写 SDK `build/`。正常恢复路径中的计划准入错误也属于
失败，不能用绕过准入的显示对象或缺素材占位替代。WidgetTester 的控制器异步关闭在
`runAsync` 内执行，避免 FakeAsync 的 stream-close 收尾等待影响后续主题采集。

本批最终完整运行输出为本地 `build/chat-extract-baseline/candidate-final/`：浅/深各 11 帧，
22/22 与冻结原页零像素差，2/2 采集测试通过。未更新源基线或原有 16 张组件 golden。
