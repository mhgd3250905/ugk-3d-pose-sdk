# 动作库热更新（规格草案，2026-11-04）

**状态：草案，待用户确认后实现。** 目标：以后加动作、删动作、改描述、修建模，只需「上传新包 + 改指针」，SF、HipLab、Flare 不必重新发版。本次从 r1-v3 切到 r2-v1 用这套机制走第一遍。

开发阶段不考虑旧版本用户的历史数据（用户 2026-11-04 确认）。

**规则：动作只增不删（用户 2026-11-04 18:57 定）。** 动作 ID 一旦发布就永远留在目录里；不想再推荐的动作标 `retired: true`：不进搜索、推荐和新计划，但已存计划和训练记录照常能播放。

## 1. 现状

- SDK 内置 r1-v3 目录：`packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json`（219 个动作）及语义目录，`PoseHubActionLibrary.catalogSha256` 写死。
- 媒体地址写死 `https://media.uuugk.win/pack/r1-v3/`（`PoseHubActionLibrary.mediaReleaseBaseUri`、`TrainingMediaPolicy.publicBaseUrl`），多个仓库类默认 `packVersion = 'r1-v3'`。
- App 侧还有各自的写死：SF `posehub_media_delivery.dart` 只认 `r1-v3`；Flare `assets/ai_tags/actions.json` 与 `flare_action_scope.dart` 的授权 ID 列表；HipLab 的草稿标签。
- 结果：换一版动作包 = 改 SDK + 改三个 App + 重新发版。

## 2. 分层

| 层 | 内容 | 谁更新 | 更新方式 |
| --- | --- | --- | --- |
| 动作数据（catalog） | ID、多语言名称与描述、标签、部位、器械、准入信息、每个媒体文件的路径/大小/SHA | Pose-Hub 产包 | 远程，随包版本 |
| 媒体 | 视频、poster、语音，按文件 SHA 寻址 | Pose-Hub 产包 | 按需下载；只变动的文件需要重下 |
| App 范围（scope） | 每个 App 允许用哪些动作 | 各 App 负责人 | 远程覆盖文件，随包版本 |
| 教练技能说明（SOP） | 怎么问、怎么挑、怎么换的规则，不列具体动作 | SDK | 随 SDK 发版 |
| 代码 | 解析、准入、播放 | SDK | 随 SDK 发版 |

要点：问答 v3 的模型通过 `search_actions` 查目录，目录换了模型自然看到新动作，SOP 不用改。只有新增**标签种类或字段**时才动 SOP 和 SDK 代码，这种包在指针里写更高的 `min_sdk`。

## 3. 线上结构

```
pack/r1-v3/ ...                 旧包，永不修改
pack/r2-v1/catalog.json         新包，只追加
pack/r2-v1/scopes/{sf,hiplab,flare}.json   各 App 范围覆盖（可选）
pack/channels/dev.json
pack/channels/beta.json
pack/channels/stable.json
```

指针文件（每个渠道一份，唯一会被改写的文件，`Cache-Control: no-cache`）：

```json
{
  "schema": 1,
  "pack": "r2-v1",
  "catalog": "https://media.uuugk.win/pack/r2-v1/catalog.json",
  "catalog_sha256": "22b2a391…e804e",
  "catalog_bytes": 0,
  "min_sdk": "0.8.0",
  "published_at": "2026-11-04T17:47:00+08:00"
}
```

- 包不可变：发现问题出新版（r2-v2），不覆盖旧文件。
- 渠道：内测 App 读 `dev`/`beta`，正式读 `stable`。验收通过后把 `stable` 指过去；出问题改回上一版就是回滚。
- App 读哪个渠道由 `CoachAppProfile` 配置，构建时决定，不在运行时切换。

## 4. catalog 增加的字段

- `schema`：目录格式版本，SDK 只接受自己认识的范围。
- `pack`：包版本号，如 `r2-v1`。
- 每个动作可带 `retired: true`（停用，见上方规则）与可选 `retired_in`（如 `r2-v2`）。目录里不允许少掉上一版已有的 ID，产包 check_run 加这条检查。

## 5. SDK 加载流程

1. 启动先用本地缓存；没有缓存用 App 内置的基线目录（保证首次离线可用）。
2. 每天最多一次（或 App 回到前台超过 24 小时）带 ETag 拉指针。
3. 指针的 `pack` 与本地相同 → 结束。`min_sdk` 高于当前 SDK → 不更新，记录事件 `pack.update_blocked`。
4. 下载 catalog → 校验字节数与 SHA → 解析与准入检查（动作数据完整、媒体记录齐全、scope 引用的 ID 都存在）。
5. 全部通过才原子替换本地缓存；当前会话不切换，下次进入教练或训练时生效，避免播到一半换数据。
6. 任何一步失败继续用旧目录，记录事件 `pack.update_failed` 与原因，不弹错误。
7. 媒体仍按需下载，缓存以 SHA 为键：动作没变的文件不重下；新版不再引用的文件交给现有 LRU 清理。

## 6. 停用动作与已存计划

- `search_actions`、推荐、`build_plan`、`swap` 的候选都排除 `retired`。
- 已存计划和历史记录里的停用动作照常显示、照常播放（媒体文件仍在线）。
- r2-v1 已经删掉了 `scapular-C`、`h-sleeper-stretch`，与新规则冲突：出 r2-v2，把这两个加回目录并标 `retired`，媒体直接引用 r1-v3 里已有的文件（逐文件地址，不重传）。
- SDK 校验新目录时，发现比本地少了 ID 就拒绝更新。

## 7. App 范围

- 默认规则：App 用 profile 里的规则（部位、类型、器械）从目录里筛，新动作符合规则就自动进入。
- 需要精确控制的 App（Flare 现在是显式 ID 列表）用 `scopes/flare.json` 远程覆盖：`allow` / `deny` 列表。
- App 内置一份同版本的 scope 作为离线基线。

## 8. 发布流程（每次更新动作）

1. Pose-Hub 产新包 → 现有 check_run 全量通过 → 只追加上传 → 匿名校验。
2. 改 `dev` 指针 → 内测 App 冷启动后自动拿到 → 真机清单验收。
3. 改 `beta`/`stable` 指针。出问题改回上一版。
4. 只有 `min_sdk` 提升时才需要 SDK 发版和 App 发版。

## 9. 本版工作量与拆分

| 批 | 内容 |
| --- | --- |
| A | SDK：指针与 catalog 下载、校验、原子缓存、失败回退；`packVersion` 不再写死，来自当前目录 |
| B | SDK：`retired` 过滤与「不许少 ID」校验；问答 `search_actions`、准入、PlanBuilder 读当前目录 |
| C | 内置基线换成 r2-v1；上线 `channels/*.json` 与 r2-v1 scope 文件 |
| D | 三个 App：去掉写死的 `r1-v3`、Flare 授权列表改为远程覆盖 + 内置基线、改锁、出包验收 |

测试：离线首启、指针未变、SHA 不符、`min_sdk` 过高、下载中断、切版后已存计划含停用动作、切版不打断正在播放的训练。

## 10. 已定（2026-11-04）

- 指针检查：每天一次，另外每次启动 App 查一次。
- 动作只增不删，停用用 `retired` 标记。
- 本版只做 SHA 校验，不加签名（签名防的是服务器被黑后换假包，当前收益小）。
