# HipLab SDK integration candidate — 2026-11-08

Branch `codex/hiplab-sync-r1` merges `fa957ff405cc57cd10d53987430313822ff20607`
into main baseline `01a12f54116b8c130f4182f30f0eddc889118bb9` with a normal
two-parent merge. Both histories remain intact; main and tags are unchanged.

- `coach_ui_adapter.dart`: retain localized action text, language, category,
  equipment and level labels, then apply `_withCatalogArtwork`; host artwork
  retains priority over catalog artwork.
- `training_action_media.dart`: combine idle prefetch and priority preparation
  with retained-route visibility, native alpha, first-frame preparation and
  readiness callbacks, paused-frame reveal and failure/retry handle binding.
  Unsupported platforms bind the current handle before returning.

The explicit `showInlineStatus` switch defaults to true, preserving standalone
loading and retry contracts. The shared player opts out because its download HUD
already owns status; merely providing an inspection handle does not hide status.

Two added regressions verify idle-prefetch/first-frame decoder reuse and handle
rebinding without downloads on unsupported native alpha. Existing tests and
assertions are retained. Three existing trainer animation tests only wrap their
intentional `animation.reverse(...)` futures in `unawaited`; `dart:async` was
already imported.

Final validation, Flutter 3.44.7 / Dart 3.12.2:

| Package | Analyze issues | Passed | Skipped | Failed |
|---|---:|---:|---:|---:|
| ugk_coach (root) | 0 | 1529 | 0 | 0 |
| ugk_trainer_runtime | 0 | 204 | 4 | 0 |
| ugk_coach_chat | 0 | 93 | 0 | 0 |
| ugk_trainer | 0 | 614 | 0 | 0 |

Local logs: `build/verification/final-*.log`. No device, listening, live-model,
iOS or store acceptance is implied. Submit as Draft PR only; do not merge.
