import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Adds deterministic themed descriptors to one row of a catalogue fixture.
Map<String, Object?> addFixtureThemes(
  Map<String, Object?> catalog,
  String actionId,
) {
  final distribution = catalog['mediaDistribution'] as Map<String, Object?>?;
  final base = distribution == null
      ? null
      : Uri.parse(distribution['baseUrl']! as String);
  final actions = List<Object?>.of(catalog['actions']! as List<Object?>);
  final index = actions.indexWhere(
    (action) => (action! as Map<String, Object?>)['id'] == actionId,
  );
  final action = actions[index]! as Map<String, Object?>;
  final files = action['files']! as Map<String, Object?>;
  var addedBytes = 0;
  Map<String, Object?> themedFiles(String theme, String skin) {
    return {
      'skin': skin,
      for (final role in ['video', 'cover', 'thumbnail'])
        role: () {
          final original = files[role]! as Map<String, Object?>;
          final extension = role == 'video' ? 'mp4' : 'webp';
          final name = '$actionId.$theme.$role.$extension';
          final path = 'media/$actionId/theme-r1/$name';
          addedBytes += original['bytes']! as int;
          return {
            ...original,
            'path': path,
            'sha256': sha256.convert(utf8.encode(path)).toString(),
            if (original.containsKey('assetName')) 'assetName': name,
            if (base != null)
              'downloadUrl': base
                  .resolve(
                    distribution!['kind'] == 'github-release-assets@1'
                        ? name
                        : path,
                  )
                  .toString(),
          };
        }(),
    };
  }

  actions[index] = {
    ...action,
    'files': {
      ...files,
      'themes': {
        'light': themedFiles('light', 'tech-white'),
        'dark': themedFiles('dark', 'neon-night'),
      },
    },
  };
  return {
    ...catalog,
    'actions': actions,
    if (distribution != null)
      'mediaDistribution': {
        ...distribution,
        'mediaFiles': (distribution['mediaFiles']! as int) + 6,
        'mediaBytes': (distribution['mediaBytes']! as int) + addedBytes,
      },
  };
}
