# Single-surface plan card

Import `package:ugk_coach_ui/ugk_coach_ui.dart` and use `CoachPlanExpanded`.
It reuses the dialogue plan card's numbered rows, thumbnail renderer, complete
`detailDose` text, header/collapse control, note, footer action and start control.
The same theme and host builders apply; this widget adds no style options.
The component owns one opaque surface and one 20px rounded content clip. The
surface is outside every fade transition. Do not wrap it in another card.

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
| `expanded` | Host-controlled state. Without slots, the existing expanded-only view collapses to zero. With slots, the shell/header/summary remain as one card. |
| `header` | Optional persistent top content, outside size/fade transitions. The collapse-control slot reserves its width in both states. |
| `collapsedSummary` | Optional content directly below the header when collapsed. |
| `onToggle` | Optional callback for tapping the whole header/summary area, with ink clipped to the card. It requests a change; the host updates `expanded`. |
| `onCollapse` | Requests collapse without mutating host state. |
| `actionIcon` | Optional left action icon, default `CoachGlyph.bookmark`. |
| `actionLabel` | Optional left action text, default the theme's localized Save label. |
| `onAction` | Optional left action callback; omitted means disabled. |
| `onStart` | Existing `void Function(CoachOriginRect)` start contract. The deferred origin resolves this widget's current screen bounds. |

For a different left action, supply `actionIcon`, `actionLabel` and `onAction`;
no save/network/training operation is performed by the widget itself. Plan
titles and metadata are passive when no `onToggle` is provided; collapse and start
are independent controls. Single-item routines display an ordinary numbered
action row here.

## Optional slots for My Plans

The slot mode is enabled only when `header`, `collapsedSummary` or `onToggle`
is supplied. Existing dialogue callers do not opt in automatically.

```dart
// Keep an expensive/stateful header instance stable while only expanded changes.
final header = Text(routine.title);
final summary = Text(routine.metaLabel);

CoachPlanExpanded(
  plan: routine,
  library: exerciseLibrary,
  header: header,
  collapsedSummary: summary,
  expanded: expanded,
  onToggle: () => setState(() => expanded = !expanded),
  onCollapse: () => setState(() => expanded = false),
  onAction: saveRoutine,
  onStart: (origin) => openTraining(origin),
)
```

The header slot remains mounted above the animated content. Its state and
position survive expansion/reversal; the component does not rebuild it on
animation ticks. Replacing header data/widgets remains a normal host update.
The right collapse control fades in over 120 ms only when expanded. Nested
collapse/action/start taps do not also invoke `onToggle`.

The two content branches stay mounted at their natural sizes. The shared
`AnimatedSize` uses 280 ms, `easeOutCubic`, `Alignment.topCenter`. On expansion,
the summary fades out over 120 ms; the body waits 60 ms, then fades in over
180 ms and moves from y=-8px to zero. On collapse, the body fades out over
120 ms; the summary waits 160 ms, then fades in over the final 120 ms.
Fully transparent/hidden controls do not receive taps, focus or semantics.
The shell never fades, including during the blank portion of a transition.

An instance mounted expanded is immediately visible. Rapid reversals cancel
pending delays and continue from the current presentation. Reduced motion
changes state immediately. Surface tokens remain white/`#E3E8E6` in light mode
and `#1A2324`/white at 8% in dark mode, with a 1px border and 20px radius.
Typography, row sizing, spacing and button appearance are unchanged.

`CoachPlanCard` calls this same widget through a private dialogue adapter.
That adapter preserves existing saved/disabled state, header navigation,
single-action cue expansion and the original thumbnail-flight choreography.
It supplies its existing canvas to the shared shell/size configuration; its
already animated natural dimensions prevent a second height animation. The
dialogue itself no longer owns an outer card. Its header positions, `onOpen`
behavior and media flights remain unchanged, per the selected compatibility
option. Cutout media that already overhangs the surface keeps its original
overlay. No extra public compatibility/style switch is added.

Validation: the widget has 20 focused tests. Before/after dialogue probes
match byte for byte when collapsed, at 250 ms of expansion and fully expanded;
existing overflow, cutout, text-scaling and media-flight tests are retained.
The [parity manifest](evidence/plan-single-card/parity.json) records the before
and after hashes for the [collapsed](evidence/plan-single-card/plan-card-collapsed.png),
[250ms](evidence/plan-single-card/plan-card-expanding-250ms.png) and
[expanded](evidence/plan-single-card/plan-card-expanded.png) captures. These are
local Flutter widget renders of the existing fixture. Training and completion
sources are unchanged. Use a commit containing this API; existing release tags
remain unchanged by this work.

## Validation of the single-card revision

| Package | Full suite | Static analysis |
| --- | --- | --- |
| Coach | `dart test --concurrency 1`: 1210 passed | `dart analyze --fatal-infos`: no issues |
| Coach UI | `flutter test`: 111 passed | `dart analyze --fatal-infos`: no issues |
| Trainer | `flutter test`: 365 passed | `dart analyze --fatal-infos`: no issues |

The first concurrent Coach run hit an existing 60ms turn-timeout test before
its request record was created. The complete serial rerun passed; Coach source
was not changed. Coach UI and Trainer passed their full runs. Focused coverage
includes 20 public-widget tests and the 55 existing plan-card regressions.
