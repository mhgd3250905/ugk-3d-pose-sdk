# Public expanded plan

Import `package:ugk_coach_ui/ugk_coach_ui.dart` and use `CoachPlanExpanded`.
It reuses the dialogue plan card's numbered rows, thumbnail renderer, complete
`detailDose` text, header/collapse control, note, footer action and start control.
The same theme and host builders apply; this widget adds no style options.

```dart
CoachPlanExpanded(
  plan: routine,
  library: exerciseLibrary,
  expanded: expanded,
  onCollapse: () => setState(() => expanded = false),
  onAction: saveRoutine,
  onStart: (origin) => openTraining(origin),
)
```

| Parameter | Contract |
| --- | --- |
| `plan` | Existing `CoachRoutine` presentation data. Full row doses use `detailDose`. |
| `library` | Existing trusted catalogue adapter resolving names and assets from the routine IDs. |
| `expanded` | Host-controlled visibility. Collapsed height is zero; hidden controls are excluded from pointer, focus and semantics. |
| `onCollapse` | Requests collapse without mutating host state. |
| `actionIcon` | Optional left action icon, default `CoachGlyph.bookmark`. |
| `actionLabel` | Optional left action text, default the theme's localized Save label. |
| `onAction` | Optional left action callback; omitted means disabled. |
| `onStart` | Existing `void Function(CoachOriginRect)` start contract. The deferred origin resolves this widget's current screen bounds. |

For a different left action, supply `actionIcon`, `actionLabel` and `onAction`;
no save/network/training operation is performed by the widget itself. Plan
titles and metadata are passive in this standalone view; collapse and start
are independent controls. Single-item routines display an ordinary numbered
action row here.

Independent instances own their animation: height changes over 280 ms with
`easeOutCubic`, and content opacity completes during the first 180 ms. An
instance mounted with `expanded: true` is immediately visible. Rapid reversals
continue from the current height/opacity. Reduced motion changes state
immediately. The surface, typography, row sizing, spacing and button appearance
come from the existing plan card implementation.

`CoachPlanCard` now calls this same widget through a private dialogue adapter.
That adapter preserves existing saved/disabled state, header navigation,
single-action cue expansion and the original thumbnail-flight choreography.
Its animation/layout projections are private implementation details. Existing
dialogue callers and public parameters are unchanged.

Validation: the new widget has 9 focused tests. Before/after dialogue probes
match byte for byte when collapsed, at 250 ms of expansion and fully expanded;
existing overflow, cutout, text-scaling and media-flight tests are retained.
The full Coach / Coach UI / Trainer suites pass 1210 / 100 / 365 tests, and
all three packages pass `dart analyze --fatal-infos`. Training and completion
sources are unchanged. Use a commit containing this API; existing release
tags remain unchanged by this work.
