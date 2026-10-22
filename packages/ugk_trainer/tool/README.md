# Training media preview policy checks

Run from the trainer package:

```powershell
dart run tool/check_training_media_preview_policy.dart
flutter test --no-pub
flutter analyze --no-pub
```

The standalone checker compiles and executes 18 native AOT programs using the
actual shared policy source. It supplies each compile-time mode, flavor and
opt-in combination, then verifies both the echoed environment constants and the
result. It does not infer release behavior from a Flutter debug test runner.
The mode constants are explicitly set for this matrix; host Flutter APK builds
must additionally verify that their real flavors provide the expected values.

Expected `TrainingMediaPreviewPolicy.enabled`:

| Mode constants | Flavor | Opt-in false | Opt-in true |
|---|---|---|---|
| debug | absent | true | true |
| debug | production | true | true |
| debug | internal | true | true |
| profile | absent | false | false |
| profile | production | false | false |
| profile | internal | false | true |
| release | absent | false | false |
| release | production | false | false |
| release | internal | false | true |

The repository also requires its existing caller-controlled `allowPending`
switch, which defaults to false. Enabling this compile-time capability alone
does not reveal or download pending actions. This policy does not configure
Android cleartext traffic, make pending content approved, or constitute a
physical-device playback result.

Validation for trainer 0.1.6 on 2026-10-22: the matrix passed all 18 compiled
cases, the trainer suite passed all 145 tests, and the trainer analyzer reported
no issues. Host production/internal release APK verification and continuous
physical-device training remain separate host-app checks.
