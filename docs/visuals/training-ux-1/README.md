# SDK training UX review

Branch: `codex/training-ux-1`, based on main
`1532f0825b93777139be0e92e715ebec144a73b9`.

Scope follows the approved card, video preview, completion and cue specifications.
The user subsequently removed camera/rotation and all video framing/crop work;
the existing media fit and assets are unchanged. Pose-Hub owns the reported
source-media offset.

## Screenshots

Open the [side-by-side gallery](index.html). These are actual Flutter widget
renders in matched light/dark viewports, with a locally loaded Chinese font.
No generated mockups or edited screenshot pixels are used. Training/showcase
figures are the existing transparent vector layout fixture, **not a live video
or native-device acceptance result**. Library and recommendation cards use
bundled PoseHub stills. Result fixtures use short genuine engine visits, hence
their recorded duration is below one second and rounds to zero.

| Item | Before light / dark | After light / dark |
| --- | --- | --- |
| Recommendation cards | [light](before-recommend-light.png) / [dark](before-recommend-dark.png) | [light](after-recommend-light.png) / [dark](after-recommend-dark.png) |
| Action library | [light](before-library-light.png) / [dark](before-library-dark.png) | [light](after-library-light.png) / [dark](after-library-dark.png) |
| Training and cue text | [light](before/training-light.png) / [dark](before/training-dark.png) | [light](after/training-light.png) / [dark](after/training-dark.png) |
| Rest | [light](before/rest-light.png) / [dark](before/rest-dark.png) | [light](after/rest-light.png) / [dark](after/rest-dark.png) |
| Side transition | [light](before/transition-light.png) / [dark](before/transition-dark.png) | [light](after/transition-light.png) / [dark](after/transition-dark.png) |
| Completion | [light](before/result-light.png) / [dark](before/result-dark.png) | [light](after/result-light.png) / [dark](after/result-dark.png) |
| New video preview | No previous stage | [light](after/preview-light.png) / [dark](after/preview-dark.png) |
| Start transition at 150 ms | No previous transition | [light](after/start-morph-light.png) / [dark](after/start-morph-dark.png) |
| Preparation after preview | Existing preparation behavior | [light](after/preparation-light.png) / [dark](after/preparation-dark.png) |
| Manual cue change | Previously a static subtitle | [light](after/cue-manual-light.png) / [dark](after/cue-manual-dark.png) |
| Full instructions sheet | No previous sheet | [light](after/cue-sheet-light.png) / [dark](after/cue-sheet-dark.png) |

Completion screenshots wait for the one-shot 1700 ms celebration timeline to
finish. The example tests also verify the 150 ms intermediate button morph,
label/card separation, preparation page 1 and full precautions sheet. Unit
tests verify 600 ms metric counters, single playback, recorded data, feedback,
theme overrides and small-screen layout. The painter fixes the circle/check
timeline and finite 24-particle burst directly in source. The showcase controls above the SDK
viewport are included only in the full-sheet screenshots.

## Compatibility

`startMode` defaults to training. Preview is opt-in for existing hosts; the
bundled action browser explicitly enters preview. `onStartTraining` reports the
button action. Existing `onFinished` automatic persistence remains unchanged;
new optional `onCompleted` delivers the same session ID with optional feeling,
and navigation returns that receipt. Callback failures retry the same receipt.
No tags, package references, lockfiles or default model configuration change.

## Validation

| Package | Full suite | Static analysis |
| --- | --- | --- |
| `ugk_coach` | `dart test`: 1210 passed | `dart analyze --fatal-infos`: no issues |
| `ugk_coach_ui` | `flutter test`: 91 passed | `dart analyze --fatal-infos`: no issues |
| `ugk_trainer` | `flutter test`: 365 passed | `dart analyze --fatal-infos`: no issues |
| Trainer showcase | `flutter test test/showcase_test.dart`: 5 passed | Included in trainer analysis |

Regression coverage includes default training, preview time exclusion, preserved
media state and button center, closing during the start transition, instruction
pause/resume, a manually paused session, preserved host subtitles, full steps,
completion feedback retries, empty sessions and actual repetition cycles for
partial/custom/self-paced work. Existing voice, media, engine and host-slot
tests remain in the full trainer suite. Source and screenshot review do not
replace the user's visual acceptance or SmartFit/native-device testing.

See the [host API guide](../../../packages/ugk_trainer/docs/training-ux.md).

## Implementation research

Before implementing the fixed celebration, we compared the controller/emitter
design of [flutter_confetti](https://github.com/funwithflutter/flutter_confetti)
(MIT; Flutter and vector_math) and the bounded burst/lifetime model of
[canvas-confetti](https://github.com/catdad/canvas-confetti) (ISC; JavaScript).
The former also has a reported [scroll/lifecycle issue](https://github.com/funwithflutter/flutter_confetti/issues/59).
This SDK uses an original, session-owned Flutter `CustomPainter` with exactly
24 particles and a finite controller; it adds no dependency and copies no
third-party implementation.
