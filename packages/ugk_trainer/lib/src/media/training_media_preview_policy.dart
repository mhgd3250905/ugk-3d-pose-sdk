/// Compile-time permission to preview pending training media.
///
/// Debug builds keep the existing developer preview behavior. A non-debug
/// build must be an explicitly opted-in `internal` flavor; either define alone
/// leaves the normal release/profile gate intact. Hosts must still request
/// `TrainingMediaRepository.allowPending` separately.
///
/// This file deliberately has no Flutter imports so the same constants can be
/// checked in standalone AOT executables as well as Flutter builds.
abstract final class TrainingMediaPreviewPolicy {
  // These are the same compile-time mode conditions used by kDebugMode.
  static const bool _debugMode =
      !bool.fromEnvironment('dart.vm.product') &&
      !bool.fromEnvironment('dart.vm.profile');

  static const bool enabled =
      _debugMode ||
      (String.fromEnvironment('FLUTTER_APP_FLAVOR') == 'internal' &&
          bool.fromEnvironment('UGK_INTERNAL_MEDIA_PREVIEW'));
}
