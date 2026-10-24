import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Git package manifests are ASCII for Windows system decoding', () {
    final manifests = <File>[
      File('pubspec.yaml'),
      for (final entry in Directory('packages').listSync())
        if (entry is Directory &&
            File('${entry.path}/pubspec.yaml').existsSync())
          File('${entry.path}/pubspec.yaml'),
    ];
    expect(manifests.length, greaterThan(1));
    for (final manifest in manifests) {
      final bytes = manifest.readAsBytesSync();
      expect(
        bytes.every((byte) => byte < 128),
        isTrue,
        reason:
            '${manifest.path} is read from git show using the host system '
            'encoding by Dart Pub. Keep the entire manifest ASCII so a '
            'description cannot swallow the following version field.',
      );
    }
  });
}
