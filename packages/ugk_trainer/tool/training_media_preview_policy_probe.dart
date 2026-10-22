import 'dart:convert';
import 'dart:io';

import 'package:ugk_trainer/src/media/training_media_preview_policy.dart';

void main() {
  stdout.writeln(
    jsonEncode({
      'product': const bool.fromEnvironment('dart.vm.product'),
      'profile': const bool.fromEnvironment('dart.vm.profile'),
      'flavor': const String.fromEnvironment('FLUTTER_APP_FLAVOR'),
      'optIn': const bool.fromEnvironment('UGK_INTERNAL_MEDIA_PREVIEW'),
      'enabled': TrainingMediaPreviewPolicy.enabled,
    }),
  );
}
