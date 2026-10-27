# 测试夹具来源

| 文件 | 来源 |
|---|---|
| `pose-hub-catalog.json` | 3D-Pose-Hub `feat/ai-coach-catalog` 809f36a 的 `catalog/catalog.json`（0.1.0，142 个动作；与 ai-coach-eval d0c5cab–c60023f 的 `catalog.json` 相同） |
| `golden/*.md` | ai-coach-eval c60023f（kernel v2）`prompt/built/*.md`（`tools/build_prompt.py` 产物），用于断言 SDK 渲染的系统提示词逐字节一致 |
| `parity.json` | `eval/tools/export_parity.py` 导出：`validate.py` 自测 25 例 + 8 条补充规则样例（mode 与目录一致、动作 scenes 匹配计划场所），含 Python 实际判定；`test/parity_test.dart` 逐例比对错误分类与每类条数 |
| `packs/*/pack.json` | Sport-Helper 6d4eb30 `assets/packs/`（drill-pack format 1） |

上游更新后整体替换，并在仓库根重新生成：

```bash
for p in flarelab hiplab smartfit; do python3 eval/tools/build_prompt.py --profile profiles/$p.json --out test/fixtures/golden/$p.md; done
python3 eval/tools/export_parity.py
```
