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

提交同步结果前运行脚本回归和两个包的完整测试，并确认静态分析无问题：

```powershell
python -m unittest discover -s tool -p test_sync_bundled_pack.py
# 在 packages/ugk_trainer_runtime 和 packages/ugk_trainer 分别执行：
dart analyze lib test
flutter test
```

内置目录 SHA-256、standing 索引与实际资源字节必须由测试核对。出包前再次运行 `--check`，避免验证期间线上 beta 已发布新的 pack。记录使用的 channel、pack、主目录与语义目录的 SHA-256、SDK revision 及测试数字。

这些命令只读取线上已发布对象，不上传、不修改指针，不替代 SDK 合并、打 tag 或 App 发包的授权。
