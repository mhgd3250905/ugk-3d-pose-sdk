import 'dart:convert';

/// Network transport is a policy hint; HTTP errors/timeouts are still handled.
enum TrainingMediaNetwork { wifi, mobile, offline, other }

typedef TrainingMediaNetworkProbe = Future<TrainingMediaNetwork> Function();

enum TrainingMediaPhase {
  idle,
  queued,
  downloading,
  ready,
  waitingForWifi,
  offline,
  failed,
}

class TrainingMediaState {
  const TrainingMediaState(
    this.phase, {
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });
  final TrainingMediaPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final String? error;
}

class TrainingMediaAction {
  TrainingMediaAction(Map<String, dynamic> json)
    : id = json['id'] as String,
      nameZh = json['nameZh'] as String,
      releaseEligible = json['releaseEligible'] == true,
      metadata = Map.unmodifiable(json) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Invalid action id');
    }
  }
  final String id;
  final String nameZh;
  final bool releaseEligible;
  final Map<String, dynamic> metadata;
}

class TrainingMediaFile {
  TrainingMediaFile(Map<String, dynamic> json)
    : path = json['path'] as String,
      bytes = json['bytes'] as int,
      sha256 = json['sha256'] as String {
    if (bytes <= 0 ||
        bytes > 128 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException('Invalid media integrity metadata');
    }
  }
  final String path;
  final int bytes;
  final String sha256;
}

class TrainingMediaPackage {
  TrainingMediaPackage(this.id, Map<String, dynamic> json)
    : kind = json['kind'] as String,
      actionIds = List<String>.unmodifiable(json['actionIds'] as List),
      totalBytes = json['totalBytes'] as int,
      fileCount = json['fileCount'] as int,
      manifest = TrainingMediaFile(json['manifest'] as Map<String, dynamic>) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(id) ||
        !['video', 'images', 'keyframes'].contains(kind) ||
        fileCount <= 0 ||
        totalBytes <= 0 ||
        actionIds.isEmpty ||
        actionIds.toSet().length != actionIds.length) {
      throw const FormatException('Invalid package metadata');
    }
  }
  final String id;
  final String kind;
  final List<String> actionIds;
  final int totalBytes;
  final int fileCount;
  final TrainingMediaFile manifest;
}

class TrainingMediaManifest {
  TrainingMediaManifest.fromBytes(List<int> bytes)
    : this.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
  TrainingMediaManifest.fromJson(Map<String, dynamic> json)
    : version = json['version'] as String,
      actions = List.unmodifiable(
        (json['actions'] as List).map(
          (e) => TrainingMediaAction(e as Map<String, dynamic>),
        ),
      ),
      packages = Map.unmodifiable(
        (json['packages'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(
            key,
            TrainingMediaPackage(key, value as Map<String, dynamic>),
          ),
        ),
      ) {
    if (!RegExp(r'^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$').hasMatch(version)) {
      throw const FormatException('Invalid media version');
    }
    final ids = actions.map((action) => action.id).toSet();
    if (ids.length != actions.length ||
        packages.values.any(
          (p) => p.actionIds.any((id) => !ids.contains(id)),
        )) {
      throw const FormatException('Package action index mismatch');
    }
  }
  final String version;
  final List<TrainingMediaAction> actions;
  final Map<String, TrainingMediaPackage> packages;

  /// Only this release's adjacent video/keyframe directory is permitted.
  bool permitsPath(String path) {
    if (path.contains('%') ||
        path.contains('\\') ||
        path.contains(':') ||
        path.contains('?') ||
        path.contains('#') ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(path)) {
      return false;
    }
    final safe = path.startsWith('../v$version/')
        ? path.substring('../v$version/'.length)
        : path;
    return safe.split('/').every((s) => s.isNotEmpty && !s.startsWith('.'));
  }
}
