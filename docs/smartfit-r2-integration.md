# SmartFit r2 SDK candidate integration

This branch is for local integration and device acceptance. It does not publish tags or change main.

## Temporary dependency resolution

The trainer's release manifest points to the future `ugk_coach-v0.8.0` tag, which does not exist until the approved release. In the SmartFit checkout use a local, uncommitted `pubspec_overrides.yaml` and replace `<candidate-sha>` with the verified SDK commit. All three packages must resolve to the same commit:

```yaml
dependency_overrides:
  ugk_coach:
    git:
      url: file:///E:/AII-3D/3D-Pose-SDK-worktrees/smartfit-feedback-r2
      ref: <candidate-sha>
  ugk_coach_ui:
    git:
      url: file:///E:/AII-3D/3D-Pose-SDK-worktrees/smartfit-feedback-r2
      path: packages/ugk_coach_ui
      ref: <candidate-sha>
  ugk_trainer:
    git:
      url: file:///E:/AII-3D/3D-Pose-SDK-worktrees/smartfit-feedback-r2
      path: packages/ugk_trainer
      ref: <candidate-sha>
```

The local checkout must remain accessible. Remove the temporary override when the three approved tags are published. Git references resolve a committed snapshot; uncommitted review screenshots and logs are not part of that snapshot.

## Host mapping

- Map `AskUserQuestion.isConfirmation`, `focus`, `defaultSelections` and each field's `preselected`, `previousSelections`, `optionsByScene` into the corresponding `CoachQuestionData` / `CoachQuestionField` fields. Map `CoachConversationMessage.answeredForm` and `questionAnswered` back on every state update. Use `answerForm` for selections and `skipQuestion` for “按默认来”.
- Render a `CoachFailureBubble` for `message.isPlanningFailure`; use `send('重试')` for retry. Only show its preset action if `controller.canOfferPreset(candidate)` is true; call `controller.requestPreset(candidate)` when tapped. Do not surface `state.error` diagnostics to users.
- Build routine metadata from the admitted `TrainingPlan.equipment`, whose values are validated against actual executed actions. Translate catalog equipment labels including chair, wall and mat; do not classify those items as bodyweight merely because they are common furniture.
- Route trusted PoseHub `standing/<id>.webp` assets from `ugk_trainer` into `CoachExercise.stillCutout` and the host media builder. Map CoachAgent progress events to `CoachTypingEvent`, and do not pass a nonempty legacy `progressLabel` when phase rotation is enabled.
- The floor geometry uses an approximate default; calibrated per-action values can be supplied with `TrainerDrill.floorGeometry`.

The screenshots in `.review-artifacts` are local widget renders, not native media or device acceptance. The scripted multi-turn evaluation uses fake model responses; the real-model runner's dry mode validates fixtures only.
