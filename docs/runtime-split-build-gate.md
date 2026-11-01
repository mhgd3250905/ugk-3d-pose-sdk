# Runtime 拆包的实际构建门禁

`tool/verify_trainer_runtime_bundle.py` 在 SDK 自己的 `build/` 中生成两个最小
Flutter Android 宿主。二者使用同一份界面、媒体输入、Android 模板和构建参数，
只把直接依赖从 `ugk_trainer_runtime` 换为兼容入口 `ugk_trainer`。真实 App 的
仓库、依赖 pin、缓存和设备均不参与本门禁。

## 复现

环境需要已有的 Flutter、Dart、Python 3、Android SDK 和可用于构建的 JDK。
脚本只使用 Python 标准库；不自动接受许可证，不修改全局工具配置，不补丁依赖缓存。
Windows 已安装 Android Studio JBR 时，脚本仅给本次子进程补 `JAVA_HOME`。
两个示例宿主均限定单次 Gradle 进程（daemon 关闭）、2 workers、2 GiB Java heap、
1 GiB metaspace、4 个 JVM 逻辑处理器及进程内 Kotlin 编译。仅写生成宿主的
`android/gradle.properties`；未改全局 Gradle 或任何 App 的配置，也未降低工具版本、
Android target、lint 或 release 要求。

从 SDK checkout 根目录运行：

```powershell
python -X utf8 -m unittest discover -s tool -p test_verify_trainer_runtime_bundle.py -v
python -X utf8 tool/verify_trainer_runtime_bundle.py --out build/runtime-split/gate-r1
```

输出目录必须是本 checkout 的 `build/` 内新目录。可先加 `--prepare-only`
下载并校验原始输入，再以 `--resume` 继续同一目录。已有非本工具所有的目录会被
拒绝；失败日志保留，重试日志单独编号。两个变体构建期间生产源码指纹必须相同。

每个宿主执行：

```text
flutter pub get --offline
flutter test --no-pub --reporter expanded test/asset_probe_test.dart
flutter build apk --release --target-platform android-arm64 --no-pub
```

生成宿主的模板在 `examples/trainer_runtime_minimal/`。工作区相对包解析仅用于本
SDK 内的测试宿主，不代表任何 App 改用 path 依赖。模板的 release 配置使用
Flutter 示例调试签名，产物用于包内容验收，不是发布候选包。

## 白名单与输入凭证

本次只选 SF 已授权动作 `s-butterfly`，不是 HipLab 或托马斯的正式 manifest。
白名单生成器采用 `pose-hub-delivery@1`，明确选择 `voicePolicy: silent`、
`kitPolicy: none`；R1 历史跨 App binding 不会作为默认依赖偷偷保留。

原始目录来自兼容包的 `assets/pose_hub/app-test-pack-r1`：

| 输入 | 字节 | SHA-256 |
| --- | ---: | --- |
| `catalog.json` | 2896158 | `75881cf91621c967f80732f0219f23e85b35e8bde5d1a51ee75dec5f7c5edd36` |
| `s-butterfly.rgb-alpha.mp4` | 855104 | `2df21e9aaf2dea5acfd16b4cb601563db909fdf0891aad80fef7037b4831418e` |
| `s-butterfly.cover.alpha.webp` | 27214 | `635d6606847d5d1efdae82e1ad07c12e556b414f317ee00c67f67ba2c4917b35` |
| `s-butterfly.thumbnail.alpha.webp` | 5432 | `8fa2db79be34b0c27d7c94c112f1b9f0166e74ba98b2f9ca31b4589c721b5949` |

三个媒体文件按原 catalog 的 `downloadUrl` 下载并按原 `sha256` / `bytes` 严格核验。
standing 图按本地原文件生成显式 manifest integrity receipt。未转码、重绘或用
占位素材替换。catalog / semantic 投影由同一白名单闭包工具生成；全部输出文件
及收据见 `closure/asset-closure.json`，显式 Flutter 资源列表见
`closure/pubspec-assets.yaml`。

## 门禁检查的对象

检查的是 APK 内实际 `assets/flutter_assets/AssetManifest.bin`，用严格的
`StandardMessageCodec` 解码器解析；解码器有固定字节样本、扩展长度、对齐及
错误输入单测。不会用源码 pubspec、文件名搜索或旧 JSON manifest 替代它。

检查同时覆盖：

- 每个 manifest variant 指向实际 ZIP 文件；每个白名单文件在 manifest 和 APK 中
  都存在，内容 SHA-256 / 字节数与闭包收据一致，白名单目录没有额外文件。
- runtime-only 包不存在旧 `packages/ugk_trainer/` 资源；所有打包 JSON 的 action
  引用和所有资源路径均不出现库内名单外 ID。runtime 包资源只允许明确列出的公共项。
- legacy 比较包的动作 ID 集合必须与完整目录一致：219 张 standing 图，加两个
  standing 索引；全部 230 个历史非 shader 资源逐字节等于原文件，防止不完整旧包作对照。
- 实际宿主 bundle 可以加载白名单 catalog / semantic / 媒体；公共静音音轨和两个
  HTML 播放器可加载；旧 common key 在 runtime-only 中解析到新 key，在 legacy 中
  仍使用原 key。legacy 默认 standing 海报原 key 也可加载。
- `.flutter-plugins-dependencies` 和生成的 `GeneratedPluginRegistrant` 中 Trainer
  插件各一份；`aapt2 dump xmltree` 解析 APK 的 AndroidManifest，训练服务声明一份。

`runtime-asset-manifest.json` / `legacy-asset-manifest.json` 是实际二进制 manifest
解码结果；`*-apk-files.json` 是完整 ZIP 索引；`*-asset-sha256.json` 是实际资源
哈希；`dependency-provenance/` 保留两个依赖图、锁文件、Gradle 配置及哈希。
工具链版本、每条命令、退出码和耗时均有单独日志。最终 `summary.json` 只在两次
构建和全部检查通过后生成。

后续的依赖凭证统一按原字节保存成 `*.snapshot`，例如
`pubspec.yaml.snapshot`、`analysis_options.yaml.snapshot` 和
`.dart_tool/package_config.json.snapshot`，避免凭证副本被 Dart 当成另一份
可运行 package。每个归档的 `receipt.json` 列出 `originalPath`、`snapshotPath`、
`bytes`、`sha256` 及原宿主目录；原始路径可追溯，原始字节及换行不改动。若归档
目录已存在，重试使用编号新目录，不移动、删除或覆盖旧凭证。

R1/R2/R3 旧存档仍按当时的原样保留，其 pubspec 中的相对资产路径并不属于凭证
目录；失败试跑宿主的分析依赖也可能尚未齐备。它们不是可直接分析运行的项目副本。
这次只修正凭证输出格式，另加 3 条 Python 归档测试（与解码器共 11/11），没有
重新构建或改动既有 APK。源码最终门禁在同 SHA 的全新干净验证 worktree 中执行
四包完整 analyze，不增加排除规则，也不把存档的依赖/路径问题作为源码通过的证据。

## 结果与边界

2026-11-01 正式 R3 运行完整退出码为 0；两个变体前后生产源码指纹一致：
`28ba19d4ecec29cf69a870b6ba337141b2418c298d7e284d625955572b81d67c`。

工具链为 Flutter 3.47.8（`737ba8f885dc774b53b442759999a312c9461e4e`）、
Dart 3.13.7、Android Studio JBR 17.0.11、Gradle 9.3.1、AGP 9.1.0、
Kotlin 2.4.0；两个 release 构建分别用时 113.4 / 105.2 秒。时间用于定位本次
构建，不作为性能对比。Python 解码器测试 8/8；两个真实宿主的 Flutter bundle
probe 各 1/1。全部资源/插件/服务断言通过，无剩余未通过项。

| 实际 APK 指标 | runtime-only | legacy 兼容入口 |
| --- | ---: | ---: |
| APK 字节 | 17176180 | 23805071 |
| Flutter assets ZIP 内未压缩字节 | 1394114 | 12721482 |
| Flutter assets ZIP 内压缩字节 | 1179901 | 7742822 |
| Flutter asset 文件 | 22 | 253 |
| 实际 manifest key | 15 | 246 |
| 唯一动作 ID | 1 | 219 |
| Trainer 插件注册 / 服务声明 | 1 / 1 | 1 / 1 |

runtime-only 少 **6628891 APK 字节**、**11327368 asset 字节**；白名单实际输出
6 文件、936898 字节，名单外动作资源及目录引用为 0。legacy 全部 230 个历史非
shader 资源原字节不变，219 张图和两个 standing 索引均在包内。公共资源清单包括
静音音轨、media-player HTML/JS/CSS、PoseHub HTML/JS 和 packed-alpha shader；
字体及 Flutter 生成的元数据不计作动作资源。

实际 APK SHA-256：

```text
runtime e791823812e4f475677011b54fa1c71fb64f785933d35c81fc6626073a45d793
legacy  55dc5b8f367dfeb1724b610d34ea2012cfc32ad6ba8da5c099a1f71efdfc0186
```

实际 `AssetManifest.bin` SHA-256：

```text
runtime 6198c677fb2154f09c8a71fc3a56f33246906bac2b98a10845b0885f6822cfbb
legacy  fa3de13efd2cc832a6bb00d945d2531add7f09c32bf404fa13dbd88a797aeea0
```

本 checkout 的完整收据及 APK 保留在
`build/runtime-split/gate-r3-20261101/`，主收据为 `summary.json`；闭包 proof SHA-256
为 `bd558ec6955d9c33cd56a42abef722757cd631a13e9045369c5c793a58e3ba86`。
R1/R2 也保留在同级目录，未删除或用新结果覆盖。

首次试跑的两个 release APK 均构建成功。初版审计把 standing 目录两个索引文件
也计入动作数，因 `221 != 219` 返回失败；保留该轮日志和产物，随后改为精确
动作 ID 集合校验，并增加全部 230 个历史非 shader 资源逐字节比较。没有通过
删除历史文件或放宽阈值绕过失败。正式结果使用新目录重新跑完整链路。

第二轮 runtime 构建及审计通过；legacy 构建中 JVM 报 native allocation 无法分配
192937984 字节，Gradle daemon 退出，`hs_err_pid6832.log` 保留在该宿主 Android
目录。这是工作站内存提交不足；后续仅按上面的示例宿主进程资源上限重跑，所有
测试、资源断言、构建版本和目标保持不变。
另外核对并停止了该已崩溃 Gradle PID 6832 遗留的两个 idle Kotlin daemon
（39004、77388）：父 PID 与 Kotlin main class 均匹配，CPU 采样增量为 0，父
daemon 的四个构建工作目录全部属于本门禁 R1/R2。只停止这两个精确 PID，未使用
全局 `--stop` 或按进程名批量终止；凭证见 R3 的 `owned-*-provenance.json` 与
`owned-daemon-retirement.json`。

本最小宿主明确没有启用命名语音或 action-kit；它验证静音播放资产闭包及公共资源。
命名语音、kit 的引用闭包由生成器的专门 fixture 测试覆盖，不能把这个静音 APK
描述成语音、kit、视频解码、真机性能或 App 页面验收。
