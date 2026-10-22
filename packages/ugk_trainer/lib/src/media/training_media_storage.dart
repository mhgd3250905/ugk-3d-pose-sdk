import 'dart:typed_data';
import 'training_media_models.dart';
import 'training_media_storage_stub.dart'
    if (dart.library.io) 'training_media_storage_native.dart'
    as platform;

class TrainingMediaCacheEntry {
  const TrainingMediaCacheEntry(this.path);
  final String path;
}

abstract class TrainingMediaStorage {
  static Future<TrainingMediaStorage> create(
    String version,
    String? directory,
    Duration downloadTimeout,
  ) => platform.createStorage(version, directory, downloadTimeout);
  Future<TrainingMediaCacheEntry?> cached(TrainingMediaFile file);
  Future<TrainingMediaCacheEntry> download(
    TrainingMediaFile file,
    List<Uri> urls, {
    required Future<void> Function() checkPolicy,
    required void Function(int) onProgress,
  });
  Future<Uint8List> read(TrainingMediaCacheEntry entry);
  Future<int> bytes();
  Future<void> clear();
  void cancel();
  void dispose();
}
