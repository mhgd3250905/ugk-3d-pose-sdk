# Training UX: preview, cues and completion

`TrainerPlayer.startMode` defaults to `TrainerStartMode.training`. Existing
callers continue directly into their configured preparation countdown. Opt in
to a video demonstration with `TrainerStartMode.preview`:

```dart
TrainerPlayer(
  plan: plan,
  drillOf: drillOf,
  strings: TrainerStrings.zh(),
  startMode: TrainerStartMode.preview,
  onStartTraining: () => recordTrainingStart(),
  onFinished: saveSession,
  onCompleted: (result) async {
    // Same session ID; an optional, user-reported feeling is now available.
    await updateSessionFeeling(result.sessionId, result.feeling);
  },
)
```

Preview loops the existing video without advancing the training engine, speaking
preparation cues, starting the foreground training service or saving a workout.
Start contracts the primary button for 300 ms (`easeOutCubic`), fades the training
controls in for 250 ms, then starts preparation. The media subtree and player
instance remain mounted. Leaving preview, including during this transition,
does not save an unstarted workout. No camera, video crop, asset or rotation
change is included in this work.

`PoseHubSinglePracticePage.startMode` also defaults to `training`. The bundled
action browser explicitly requests preview; its single-action preparation is
10 seconds after Start. Both surfaces forward `onStartTraining` and
`onCompleted` when supplied by the host.

## Instruction data

Supply `TrainerDrill.cues` as a list, and `precautions` separately. The legacy
single `cue` remains supported and is split at sentence/semicolon boundaries.
Optional `targetMuscles`, `equipment` and `thumbnailAsset` provide the preview
labels and completion list images. No content is invented when these are absent.

`TrainerCueCarousel` measures the real text at 16 sp, then 14 sp. Long clauses
split at commas, with a grapheme-safe fallback for text without punctuation.
Each page fits two lines without an ellipsis. It advances after 4.5 seconds;
manual swipes suppress automatic advance for 8 seconds. Preparation pins page 1.
The half-height instruction sheet shows all original steps and a separate
precaution strip. Opening it pauses a running training session; dismissing it
restores that prior state unless an audio interruption has occurred. Existing
host/voice feedback subtitles can temporarily occupy the card while the sheet
continues to show the full instructions.

## Results and compatibility

The existing `onFinished` automatic save still occurs when training ends, once
per session with the original retry behavior. Optional `onCompleted` is the
completion-page event: it receives the selected `SessionResult.feeling` when
Finish or Train again is tapped. Hosts that need this feedback upsert it under
the same `sessionId`. It is not a second workout. Navigation returns this final
receipt. A failed completion callback remains on screen and retries the same
receipt. Leaving the optional feeling unselected is valid.

`TrainingFeeling` values are `easy`, `justRight`, `tired`, `uncomfortable`.
The optional JSON field is omitted when absent; old `ugk-session-result@1`
records remain readable. `ItemResult.completedReps` is also optional. Clocked
repetitions count complete rhythm cycles actually visited, including partial
and skipped work; self-paced repetitions count only after Complete set. These
are player rhythm/user-confirmed counts, not sensor measurements. Duration
comes from recorded active time; the third metric uses repetitions when
available, otherwise recorded work duration. No calorie estimate is shown.

## Theme and fixed values

New `TrainerTheme.cardSurface`, `cardBorder`, `primaryForeground` tokens provide
the requested continuous card surface and white primary foreground. Defaults
are white / `#E3E8E6` in light mode and `#1A2324` / white at 8% in dark mode.
Existing theme constructors and `copyWith` remain valid. Training transport
uses `accent` in both playing and paused states. The shared play/pause widget
still accepts an explicit paused palette outside the training page.

Preview, completion and cue dimensions/timings follow the approved specification.
System text scaling and reduced-motion settings remain supported; reduced
motion removes the entrance animation and particle burst.

Matched light/dark screenshots and validation are in the repository
[training UX review](../../../docs/visuals/training-ux-1/README.md).
