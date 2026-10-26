# R1 semantics v2: inherited-work audit

Reviewed against base `e9b60b5ae2a743e17ebfffc4b7d2ddec524a8726`.
The inherited branch was `codex/posehub-r1-semantics-v2`, with 15 uncommitted
modified files. No inherited change was accepted solely on its existence.

## Decisions for all 15 modified files

| Inherited file | Decision |
| --- | --- |
| `CHANGELOG.md` | Adopt the 0.6.1 / 0.4.1 release entry; complete its missing linked v2 guide. |
| `README.md` | Adopt the current 211/8 overview, media invariance and v2 release references. |
| `docs/posehub-app-test-pack-r1.md` | Adopt the notice that the original guide describes immutable v1, with a new v2 link. |
| `lib/src/catalog/pose_hub_app_test_pack.dart` | Adopt the pinned semantic revision, original canonical validation and exact-source 69-definition projection. **Reject the new global 142-definition limit**; preserve general parser compatibility. |
| `packages/ugk_trainer/CHANGELOG.md` | Adopt the 0.4.1 checksum/version entry; no player or layout changes. |
| `packages/ugk_trainer/README.md` | Adopt 211/8 and 0.4.1; correct the primary integration link to the completed v2 guide. |
| `packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json` | Adopt only after exact byte equality with the supplied file and its required SHA256. |
| `packages/ugk_trainer/example/pubspec.lock` | Adopt the two local-package version updates; no dependency upgrade. |
| `packages/ugk_trainer/lib/src/pose_hub/pose_hub_action_library.dart` | Adopt the exact new SHA256 and v2 download URL. |
| `packages/ugk_trainer/pubspec.yaml` | Adopt trainer 0.4.1 and the matching coach 0.6.1 Git pin; no dependency additions. |
| `packages/ugk_trainer/test/pose_hub_action_library_test.dart` | Adopt 211/8 assertions; retain the existing browser/search/practice scenarios. |
| `pubspec.yaml` | Adopt coach 0.6.1. |
| `test/pose_hub_app_test_pack_test.dart` | Adopt the new counts, exact 69-definition values and tamper checks. Restore meaningful legacy-path negative coverage; add a matching 143-definition canonical compatibility case. |
| `tool/posehub_pack.py` | Adopt the exact-SHA semantic overlay, 211/8 and automatic fixed v1 recognition. **Reject the relaxation from ordered summary IDs to set equality**; keep strict order and no-overwrite behaviour. |
| `tool/tests/test_posehub_pack.py` | Adopt overlay/provenance, dose and v1 compatibility coverage; require both ID lists to reject reordering, duplicates and substitutions. |

No uncertain implementation was retained. The SDK source snapshot is never
edited to make a test pass. In particular, source availability/review flags
and unknown fields are not rewritten.

## Source and archive audit

- Required source and SDK copy are byte-identical: **2,770,221 bytes**, SHA256
  `a1655e5c64055c14af35850b5468390d9d11161e53a87a0cbe7780ec7ed25dc0`.
- All 219 IDs and their order, and every original media reference, are unchanged.
- Original 142 action objects retain the same field values; exactly 69 more
  complete definitions come from the reviewed source. Eight remain pending.
- All 660 v1/v2 ZIP entry names match. Full entry-byte comparison finds only
  **`catalog.json`** changed. `manifest.json`, the original canonical JSON and
  all **657 media / 587,456,377 bytes** remain byte-identical.
- The inherited staging `pack/`, ZIP and descriptor are adopted after full
  verification. A fresh deterministic build matches the inherited ZIP SHA256;
  an independent v2 installation verifies all 660 entries.
- v2 ZIP: **592,748,021 bytes**, SHA256
  `f59a699d6be905f5bf91bafdff7ca294c8d1a4e879ba792b794280a6e7559bdb`.
- The original v1 source pack still verifies with 142 complete / 77 pending.

The v1 Release baseline is ID `423932569`, with descriptor asset `677288447`
(SHA256 `cbf0e2d84bc246dfb92bf786b5a8ebe2e3a07880c3c2f9f5ea15ffb65525ec35`)
and ZIP asset `677288448`
(SHA256 `2ec6331499ed723a843cb620f52b250f5ee3310ea39566a58fdf546f3f771d97`).
Publication uses new tag and asset names; no v1 edit/delete/upload is performed.

## Verification scope

Verified: **487 coach tests, 269 trainer tests, 4 showcase tests and 21 Python
pack-tool tests** passed. The showcase's strict Pub lockfile check passed.
Focused model/test analysis and trainer analysis report no issues.
These checks validate this catalogue-only revision.
Tests retain ID/path/flag/count checks and explicitly cover the original 142,
the 69 supplied additions, the eight excluded pending IDs and host canonical
compatibility. The package tests load actual bundled source metadata.

No playback, widget layout, shader, native platform or coach UI runtime file
changes. No emulator, device operation or new Raster P99 claim is involved.
The supplied staging pack remains the adopted release artefact; temporary
dependency overrides and rejected source changes are excluded from Git.
