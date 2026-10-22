import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  test(
    'shared preview policy agrees with Flutter build mode and both opt-ins',
    () {
      const expected =
          kDebugMode ||
          (String.fromEnvironment('FLUTTER_APP_FLAVOR') == 'internal' &&
              bool.fromEnvironment('UGK_INTERNAL_MEDIA_PREVIEW'));
      expect(TrainingMediaPreviewPolicy.enabled, expected);
    },
  );
}
