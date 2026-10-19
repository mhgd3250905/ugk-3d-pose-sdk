# 测试夹具来源

| 文件 | 来源 |
|---|---|
| `pose-hub-catalog.json` | 3D-Pose-Hub `feat/ai-coach-catalog` 809f36a 的 `catalog/catalog.json`（0.1.0，142 个动作；与 ai-coach-eval d0c5cab–c60023f 的 `catalog.json` 相同） |
| `golden/*.md` | ai-coach-eval c60023f（kernel v2）`prompt/built/*.md`（`tools/build_prompt.py` 产物），用于断言 SDK 渲染的系统提示词逐字节一致 |
| `packs/*/pack.json` | Sport-Helper 6d4eb30 `assets/packs/`（drill-pack format 1） |

上游更新后整体替换，并重新生成 golden（`python3 tools/build_prompt.py --profile profiles/<id>.json --out …`）。
