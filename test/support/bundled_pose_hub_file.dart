import 'dart:io';

/// The SDK replaces its sole bundled pack on every catalog sync.
File bundledPoseHubFile(String relativePath) {
  final pack = Directory('packages/ugk_trainer/assets/pose_hub')
      .listSync(followLinks: false)
      .whereType<Directory>()
      .singleWhere((dir) => File('${dir.path}/catalog.json').existsSync());
  return File('${pack.path}/$relativePath');
}
