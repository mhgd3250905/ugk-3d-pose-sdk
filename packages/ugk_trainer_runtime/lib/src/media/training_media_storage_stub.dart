import 'dart:typed_data';
import 'training_media_models.dart';
import 'training_media_storage.dart';

Future<TrainingMediaStorage> createStorage(
  String version,
  String? directory,
  Duration downloadTimeout,
) async => _BundledOnlyStorage();

/// Web/stub use bundled media only; no unverified remote URL is played.
class _BundledOnlyStorage implements TrainingMediaStorage {
  @override
  Future<TrainingMediaCacheEntry?> cached(TrainingMediaFile file) async => null;
  @override
  Future<TrainingMediaCacheEntry> download(
    TrainingMediaFile file,
    List<Uri> urls, {
    required Future<void> Function() checkPolicy,
    required void Function(int) onProgress,
  }) async => throw UnsupportedError('Downloads require a native app');
  @override
  Future<Uint8List> read(TrainingMediaCacheEntry entry) async =>
      throw UnsupportedError('No native cache');
  @override
  Future<int> bytes() async => 0;
  @override
  Future<void> clear() async {}
  @override
  void cancel() {}
  @override
  void dispose() {}
}
