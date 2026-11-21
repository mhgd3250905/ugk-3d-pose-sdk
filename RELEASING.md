# SDK 与 App 出包时的内置目录

每次 SDK 出版本、或任何 App 出包前，内置目录必须等于当时 `beta` 指针指向的最新 pack。出 `stable` 包时，必须等于当时 `stable` 指针指向的最新 pack。热更新失败、重装和首次离线启动仍会使用内置目录，因此不能只升级远端缓存。

在 SDK 仓库运行（Python 3；生成新站位帧需要 PATH 中有 FFmpeg，无第三方 Python 依赖）：

```powershell
python tool/sync_bundled_pack.py --channel beta
python tool/sync_bundled_pack.py --channel beta --check
```

正式 stable 包把两条命令的 `beta` 换成 `stable`。`--check` 只下载比较，任何本地文件都不写；内置资源、常量或 pubspec 与指针不一致时退出码为 1，可直接用作 CI / App 出包门禁。App 使用固定 SDK revision 时，要在该 revision 上运行检查；落后时先升级到完成同步的 SDK revision 再出包。

同步脚本读取 `https://media.uuugk.win/pack/channels/<channel>.json`，核验指针的 schema、pack、HTTPS catalog、SHA-256、字节数与 min_sdk 格式；`published_at` 仅为说明信息，不影响目录准入。随后下载 pack 的 `catalog.json` 和 `catalog/catalog.json`，分别核对指针、主目录声明的 SHA-256 和字节数，再与站位图一起写入 `packages/ugk_trainer/assets/pose_hub/app-pack-<pack>/`，更新 `PoseHubActionLibrary` 常量及 pubspec。

`standing/` 与目录一起更新：先核验每个动作视频的 SHA-256 和字节数，按 packed RGB-top / red-alpha-bottom 协议抽取第 0 帧，生成 640×640 透明 WebP（quality 80）。`standing/index.json` 记录每个动作的源视频 path / SHA、图片 SHA 与大小。已有记录与当前视频一致且图片校验通过时复用；否则重新抽帧。全部生成成功才改内置资源，旧目录及旧图集被替换，不重复打包。下载或抽帧失败时，已有内置文件不变。

可用 `--media-root F:/PoseHub-v3/app-pack/r2-v7` 指定本地已发布包目录，多个来源可重复传入；本地视频同样必须通过 SHA 和字节数检查。缺少本地视频时，脚本自动下载到被忽略的 `build/bundled-pack-sync/videos/` 缓存，再校验和抽帧；`--ffmpeg` 可指定可执行文件。`--check` 不下载视频、不抽帧，也不写资源或缓存；它核对当前线上目录、常量、pubspec，以及索引的完整动作集、源视频身份、每张图片的 SHA / 大小 / 640×640 alpha 规格。

宿主启用持久化更新时，用同一个 `PoseHubCatalogStore` 创建 `PoseHubCatalogUpdater.withPersistentAssets(config: ..., store: store)` 并调用 `PoseHubActionLibrary.useVerifiedCache(store)`。展示页先显示 `PoseHubActionLibrary.load()` 返回的目录，再订阅 `updater.catalogChanges`。完整更新通过后，订阅立即收到新目录，可以刷新首页和素材库。根据新目录重建展示端的素材仓库，训练中的会话继续使用已经加载的目录。如果宿主使用自定义 Application Support 根目录，更新器和素材读取端须配置同一个根目录。

在 Navigator 下使用 `ugk_coach_ui` 的弹窗宿主，挂载后于后台调用 `updater.maybeCheck()`。没有新版时进度流不发事件。更新失败时界面仍可用，用户可重试。

```dart
PoseHubDisplayUpdateDialogHost(
  progress: updater.displayProgress,
  onRetry: () async { await updater.checkNow(); },
  child: home,
)
```

展示类先校验主目录和语义目录，再准备封面、缩略图、站位图及首页展示图。新版指针获准后先发出等待状态，确定缺失文件后报告准确的网络文件数和字节数。全部验证成功才切换当前目录指针。训练视频和动作语音在打开对应动作时按 SHA-256 复用或下载。

线上包可在动作或主题的 `files` 中添加可选 `standing` 描述符（`media/<id>/` 下的 WebP），或用顶层 `displayAssets` 对象公布按名称查找的首页素材（`media/` 或 `standing/` 下的图片）。每个描述符都要求 `path`、`bytes` 和 `sha256`。展示端通过 `catalog.displayAssets`、`PoseHubImageCache.ensureFile` 和该目录的媒体基址读取首页素材。渠道 `min_sdk` 应与发布格式匹配。

提交同步结果前运行脚本回归和两个包的完整测试，并确认静态分析无问题：

```powershell
python -m unittest discover -s tool -p test_sync_bundled_pack.py
# 在 packages/ugk_trainer_runtime 和 packages/ugk_trainer 分别执行：
dart analyze lib test
flutter test
```

内置目录 SHA-256、standing 索引与实际资源字节必须由测试核对。出包前再次运行 `--check`，避免验证期间线上 beta 已发布新的 pack。记录使用的 channel、pack、主目录与语义目录的 SHA-256、SDK revision 及测试数字。

这些命令只读取线上已发布对象，不上传、不修改指针，不替代 SDK 合并、打 tag 或 App 发包的授权。

## 渠道计划包

渠道 JSON 的 schema 仍为 1。可选的 `plans` 对象包含 `version`、HTTPS `url`、`bytes`、`sha256` 和 `min_sdk`。使用 `plans.min_sdk = "1.0.2"`；渠道顶层 `min_sdk` 继续表示目录需要的最低 SDK。没有 `plans` 时，目录更新流程照常运行。旧 SDK 会忽略新增字段。从旧 SDK 更新后，现有的指针缓存会重新检查一次，以便读到旧版本忽略的计划信息。

计划包 JSON 包含 `schema: 1`、`app`、`version`、`min_catalog_pack`、`voice_manifest` 和 `plans`。其中 `voice_manifest` 提供 HTTPS `url`、`bytes` 和 `sha256`。`plans` 是由 App 解读的原样 JSON 数组。计划包和语音清单均通过完整性与格式检查，并确认目录和 SDK 版本满足要求后，计划包才切换。目录 pack 不变时也会检查计划包。订阅 `updater.planChanges` 即可在计划生效后刷新对应 App 的列表；`checkNow()` 的返回值仍表示目录状态。

宿主继续使用现有的更新器和持久化存储。首次离线时，`loadBundled` 可以从 App 资源读取计划包和语音清单，传给 `PoseHubPlanSnapshot.fromBytes(planBytes, voiceBytes, minSdk: '1.0.2')`。更新失败时，读取兼容的上次已验证快照；没有可用快照时才读随包副本。

```dart
final snapshot = await updater.planSnapshotFor(app, loadBundled: loadBundled);
if (snapshot != null) {
  final plans = snapshot.planPack.plans;
  // 将 snapshot.id 和选中的计划 ID 一起保存到训练或续练记录。
}
final pinned = await updater.restorePlanSnapshot(app, savedSnapshotId);
```

训练中使用已取得的快照，续练按原 ID 恢复。若原快照不可恢复，由 App 明确提示用户，避免把新计划接到旧进度上。

语音清单使用 `schema: 1` 和 `files` 数组。文件记录包括 `path`、`bytes` 和 `sha256`，可另给 `url`。相对地址以清单 URL 为基准，省略 `url` 时使用 `path`，解析结果须为 HTTPS。可选的 `plans` 对象将计划 ID 映射到文件路径列表。App 选定计划后，用 `PoseHubPlanVoiceCache.inApplicationSupport()` 取得缓存，再调用 `prefetchPlan(snapshot.voiceManifest, planId)`。若由 App 自己维护计划与语音的映射，则调用 `prefetchFiles(snapshot.voiceManifest, paths)`。返回映射中的 `null` 表示该文件不可用。缓存按 SHA-256 复用。语音缓存的 `loadBundled` 可按 SHA-256 提供随包音频字节，通过校验后直接使用。
