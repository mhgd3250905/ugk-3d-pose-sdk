# 白名单播放素材闭包

`tool/trainer_asset_closure.dart` 将一份显式动作 ID 清单与固定的 PoseHub delivery
投影为一个可被 Flutter 打包的播放素材目录。工具离线运行，不读取 App 工作区，不下载
文件，不修改源数据，不使用通配符或文件名子串搜索动作。空名单是配置错误。

本批构建门禁使用已授权动作 `s-butterfly` 的真实 RGB/alpha MP4、封面、缩略图及
standing，显式选择 **silent / no kit**。语音与 kit 的引用闭包由使用真实元数据结构、
合成 payload 的单元测试验证；不能把这些单测描述成真实语音播放或完整 App 验收。
SF 按 219 授权 / 211 可规划定稿；HipLab 45、托马斯 51 仍是候选。本工具与测试
没有为 App 生成正式 manifest，以下均为构建或单测输入示例。

## 调用

```powershell
dart run tool/trainer_asset_closure.dart `
  --manifest build/runtime-split/scope.json `
  --out build/runtime-split/generated-assets `
  --asset-prefix assets/trainer
```

`--out` 必须不存在或为空；工具拒绝覆盖已有内容。将生成目录放到最小宿主的
`assets/trainer/`，再合并生成的 `pubspec-assets.yaml`。这里不直接修改任何 App。
错误以 JSON 输出 `code` 和相对资源字段，进程退出码为 2；成功输出文件数、总字节数与
证明文件路径。

也可以直接从 Dart 调用：

```dart
Future<TrainerAssetClosureResult> generateTrainerAssetClosure({
  required File manifestFile,
  required Directory outputDirectory,
  String assetPrefix = 'assets/trainer',
});
```

所有配置、源文件与最终投影先验证，验证成功后才建立输出。返回值含
`outputDirectory`、排序后的 `allowedActionIds`、`files` 与 `totalBytes`。

## Manifest v1

以下是静音、无 kit 的配置结构；示例校验值需替换为实际源文件的值。

```json
{
  "schemaVersion": 1,
  "appId": "runtime-bundle-gate",
  "adapter": "pose-hub-delivery@1",
  "allowedActionIds": ["s-butterfly"],
  "catalog": "catalog.json",
  "catalogSha256": "<catalog.json 的 64 位小写 SHA-256>",
  "sourceRoots": ["./source"],
  "voicePolicy": "silent",
  "kitPolicy": "none",
  "includeStanding": true,
  "integrity": {
    "standing/s-butterfly.webp": {
      "sha256": "<64 位小写 SHA-256>",
      "bytes": 30688
    }
  }
}
```

`adapter`、`voicePolicy` 与 `kitPolicy` 必须显式提供。当前 adapter 只支持
`pose-hub-app-test-catalog@1` delivery 与其 `pose-hub-catalog` semantic catalog。
它选用当前 delivery 的三种媒体，替代 semantic 中历史的跨 App 播放绑定。

`sourceRoots` 可以为绝对目录，也可以相对于 manifest 所在目录。它们是逻辑 pack root，
`catalog` 与每个资源路径都相对于这些 root。同一路径存在多个镜像时内容必须一致。
资源路径只接受不含 `..`、反斜杠、绝对路径、URI 编码或控制字符的相对路径。解析符号
链接后仍须位于其声明的 root 内。大小写冲突的输出路径也拒绝。

`catalogSha256` 可用于固定输入版本，建议正式构建始终提供；提供但不匹配立即失败。
semantic 与媒体的 SHA-256/字节数取自原 delivery。standing 及未自带完整 receipt 的
kit/语音资源，必须在 `integrity` 中提供 SHA-256 和正整数字节数。原 catalog 现有媒体
大部分只有远端 receipt；只有 JSON、standing 并不能构成可打包的视频素材。必须预先
准备同一 receipt 的原文件，缺文件时工具直接失败，不填充占位资源。

工具不开放任意 `sharedAssets` 文件复制入口；提供该字段会失败，防止把名单外 kit、
命名语音或完整目录伪装成通用文件。公共播放器网页、shader 与静音音轨由
`ugk_trainer_runtime` 自身的固定公共资源声明提供。默认动作海报只在旧包中保留；
runtime-only 宿主必须提供白名单海报。

## Kit 与语音

需要 kit 时设置 `kitPolicy: "index"` 并提供 `actionKitIndex`：

```json
{
  "kitPolicy": "index",
  "actionKitIndex": "assets/action_kits/index.json",
  "voicePolicy": "manifest",
  "voice": {
    "manifest": "assets/voice/manifest.json",
    "root": "assets/voice",
    "languages": ["zh"],
    "sharedKeys": ["p.welcome", "p.finish"],
    "chimes": ["end", "finish", "tick"]
  }
}
```

索引及语音 manifest 自身同样须在 `integrity` 中固定。kit 索引为
`{"schema":"action-kit-index@1","kits":[...]}`，每项支持两种格式：

- 相对字符串路径，文件名必须为精确的 `<actionId>.json`。
- `{"id":"s-butterfly","path":"assets/action_kits/s-butterfly.json",`
  `"sha256":"...","bytes":123}`。

只读取、验证并投影所选 ID 的 kit；索引里的其他合法动作不会被带进输出，也不要求
它们的 payload 已下载。重复 ID、重复路径、未知 ID、kit 内 ID 与索引不符都会失败。
kit schema 为现有 `action-kit@1`，支持 `display.poster` 字符串或 `{asset,...}`
receipt，以及 `media.video` 的 `{asset,...}`。所有声明的浅/深变体均复制并校验，
输出引用加上 asset prefix。作者侧 `media.poseHub.spec` 是来源证据，不作为运行时文件
引用复制。不会递归扫描任意 JSON 字符串并猜测其为资源。

语音 adapter 对应现有 `ManifestVoiceSource` 的 manifest 结构：
`clips[lang][key]`、`chimes[key]`、`lines[key][lang]`、`texts[kind][text]`。
动作命名语音为 `drill.<actionId>` 与 `point.<actionId>`，每个所选语言都必须存在。
另外收集 kit 的 `voice.lines`、`prepare`、`go`、`count`、`lastRep`、`nextSet`、
`end`、`firstSide`、`coach`、`switch`、`midHold` 字符串和 cycle phase 的 `cue`。
`{k}` 模板只对源 manifest 中精确匹配的数字键展开；没有匹配项会失败。`chime.*`
转到 chime 通道。音频路径固定为 `<root>/<lang>/<key>.m4a` 和
`<root>/chime/<key>.m4a`，每个文件须有 receipt。

`voice.sharedKeys` 是显式公共语音清单，只接受 `ManifestVoiceSource` 已知的公共
`p.*` 调用键与正整数 `n.*`、`sec.*`、`min.*`，防止旧 App 动作别名混入。
kit 所需的专有 cue 按该 kit 归属，不能通过 shared 清单引入名单外
`drill.*` / `point.*`。输出语音索引仅保留本次使用的键、语言和文字映射。
缺文件、缺键、非法时长、错误 SHA/大小均失败，不改成静音继续。

`voicePolicy: "silent"` 不附带语音配置；semantic 的 voice 状态明确为 `missing`。
`kitPolicy: "none"` 不附带 kit 索引。若启用 kit 且 kit 声明了语音，则必须同时提供
语音配置。两种 opt-out 都会写进证明文件，不能被解释为已复制历史语音/kit。

## 投影与校验结果

输出包含选定媒体、可选 standing、过滤后的 `catalog.json`、`catalog/catalog.json`，
以及启用时的 kit/voice 文件。dose、rhythm 与首个正数 `repSeconds` 保留，`alternative`
等动作引用只指向允许集合。原始 semantic 的历史 assets 绑定由当前 adapter 取代，
省略类别记录在证明的 `projection.omittedLegacyBindings` 中。QA/release 标记不会升级。
源文件字节不变；生成的 catalog/semantic 使用新的相互引用 SHA 和大小，并用原
`PoseHubAppTestCatalog.fromBytes` 完整重读验证。

`asset-closure.json` 包含：

| 字段 | 用途 |
| --- | --- |
| `allowedActionIds`、`allowlistSha256` | 精确白名单及稳定摘要 |
| `sourceCatalogSha256`、`sourceMetadata` | 原输入元数据的路径、大小与摘要 |
| `assetPrefix`、`projection` | adapter、silent/manifest、none/index、voice root 与省略声明 |
| `files` | 全部运行时输出；每项含 `path`、完整 `assetKey`、`bytes`、`sha256`、`owners`、`kinds`、`generated` |
| `generatedMetadata` | `files` 中 `generated=true` 的同形子集，不要重复计数 |

`files` 的 `assetKey` 已包含 `assets/trainer/` 前缀。证明自身与
`pubspec-assets.yaml` 不在 `files`，避免自哈希。Flutter 片段逐文件列出 `assetKey`，
不用目录 glob。归档审计应对每个 expected asset 校验实际字节、大小与摘要，核对包内
asset manifest 及物理条目，额外 runtime 公共资源使用其固定声明；不能只按动作名称
搜文件。运行时计划的 scope 准入与真实模型门禁属于后续批次。

## 验证

```powershell
dart test test/trainer_asset_closure_test.dart
dart analyze --fatal-infos tool/trainer_asset_closure.dart tool/src/trainer_assets/closure.dart test/trainer_asset_closure_test.dart
```

测试覆盖真实目录结构投影可加载、剂量/节奏不变、名单隔离、原文件不变、kit/语音
引用、索引裁剪、缺失/哈希/大小错误、非法路径、重复 ID 与 shared 旁路拒绝。
真实媒体的 runtime-only 与 legacy APK 精确资产核验、体积比较另见本批构建报告。
