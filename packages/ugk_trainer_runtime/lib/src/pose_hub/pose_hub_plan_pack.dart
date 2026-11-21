import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'pose_hub_catalog_channel.dart';
import 'pose_hub_catalog_io_types.dart';
import 'pose_hub_plan_voice.dart';

const _planRoot = 'channel-plans';
const _maximumDocumentBytes = 64 * 1024 * 1024;
final _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
final _catalogPackPattern = RegExp(r'^r[0-9]{1,9}-v[0-9]{1,9}$');

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Map<String, Object?> _object(Object? raw, String label) {
  if (raw is! Map<String, Object?>) {
    throw FormatException('$label must be a JSON object');
  }
  return raw;
}

String _label(Object? raw, String field) {
  if (raw is! String || raw.trim().isEmpty || raw.length > 128) {
    throw FormatException('Invalid $field');
  }
  return raw;
}

String _sdkVersion(String version) {
  comparePoseHubSdkVersions(version, version);
  return version;
}

Object? _immutableJson(Object? value) => switch (value) {
  final Map<String, Object?> fields => Map<String, Object?>.unmodifiable({
    for (final entry in fields.entries) entry.key: _immutableJson(entry.value),
  }),
  final List<Object?> items => List<Object?>.unmodifiable(
    items.map(_immutableJson),
  ),
  _ => value,
};

/// Integrity metadata for the voice manifest declared by a channel plan pack.
final class PoseHubPlanAssetReference {
  const PoseHubPlanAssetReference._(this.uri, this.bytes, this.sha256);

  factory PoseHubPlanAssetReference._fromJson(Object? raw) {
    final fields = _object(raw, 'voice_manifest');
    final url = fields['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException(
        'voice_manifest.url must be a public HTTPS URL',
      );
    }
    final size = fields['bytes'];
    if (size is! int || size < 1 || size > _maximumDocumentBytes) {
      throw const FormatException('Invalid voice_manifest.bytes');
    }
    final sha = fields['sha256'];
    if (sha is! String || !_sha256Pattern.hasMatch(sha)) {
      throw const FormatException('Invalid voice_manifest.sha256');
    }
    return PoseHubPlanAssetReference._(uri, size, sha);
  }

  final Uri uri;
  final int bytes;
  final String sha256;
}

/// The schema-1 plan envelope. Only the envelope is interpreted by the SDK.
final class PoseHubPlanPack {
  const PoseHubPlanPack._({
    required this.app,
    required this.version,
    required this.minCatalogPack,
    required this.voiceManifest,
    required this.raw,
    required this.plans,
    required this.jsonBytes,
  });

  factory PoseHubPlanPack.fromBytes(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > _maximumDocumentBytes) {
      throw const FormatException('Invalid plan pack size');
    }
    final source = Uint8List.fromList(bytes).asUnmodifiableView();
    final fields = _object(jsonDecode(utf8.decode(source)), 'Plan pack');
    if (fields['schema'] is! int || fields['schema'] != 1) {
      throw const FormatException('Unsupported plan pack schema');
    }
    final app = _label(fields['app'], 'plan pack app');
    final version = _label(fields['version'], 'plan pack version');
    final minCatalogPack = _label(
      fields['min_catalog_pack'],
      'plan pack min_catalog_pack',
    );
    if (!_catalogPackPattern.hasMatch(minCatalogPack)) {
      throw const FormatException('Invalid plan pack min_catalog_pack');
    }
    final voiceManifest = PoseHubPlanAssetReference._fromJson(
      fields['voice_manifest'],
    );
    if (fields['plans'] is! List<Object?>) {
      throw const FormatException('Plan pack plans must be a JSON array');
    }
    final immutable = _immutableJson(fields)! as Map<String, Object?>;
    return PoseHubPlanPack._(
      app: app,
      version: version,
      minCatalogPack: minCatalogPack,
      voiceManifest: voiceManifest,
      raw: immutable,
      plans: immutable['plans']! as List<Object?>,
      jsonBytes: source,
    );
  }

  final String app;
  final String version;
  final String minCatalogPack;
  final PoseHubPlanAssetReference voiceManifest;

  /// Parsed JSON with the original keys and values, including unknown fields.
  final Map<String, Object?> raw;

  /// The App owns these records. Their fields and contents are never rewritten.
  final List<Object?> plans;

  /// Original bytes, including the formatting used by the producer.
  final Uint8List jsonBytes;
  int get byteLength => jsonBytes.length;
}

/// A verified plan document and voice manifest. Persist [id] with a workout or
/// resume record so later updates cannot select a different set of plans.
final class PoseHubPlanSnapshot {
  const PoseHubPlanSnapshot._(
    this.id,
    this.minSdk,
    this.planPack,
    this.voiceManifest,
    this._voiceBytes,
  );

  factory PoseHubPlanSnapshot.fromBytes(
    List<int> planBytes,
    List<int> voiceManifestBytes, {
    required String minSdk,
  }) {
    final pack = PoseHubPlanPack.fromBytes(planBytes);
    final reference = pack.voiceManifest;
    if (voiceManifestBytes.length != reference.bytes) {
      throw const FormatException('Voice manifest size mismatch');
    }
    final voiceBytes = Uint8List.fromList(voiceManifestBytes)
        .asUnmodifiableView();
    if (_sha(voiceBytes) != reference.sha256) {
      throw const FormatException('Voice manifest SHA-256 mismatch');
    }
    return PoseHubPlanSnapshot._(
      _sha(pack.jsonBytes),
      _sdkVersion(minSdk),
      pack,
      PoseHubPlanVoiceManifest.fromBytes(
        voiceBytes,
        manifestUri: reference.uri,
      ),
      voiceBytes,
    );
  }

  final String id;
  final String minSdk;
  final PoseHubPlanPack planPack;
  final PoseHubPlanVoiceManifest voiceManifest;
  final Uint8List _voiceBytes;

  String get app => planPack.app;
  String get version => planPack.version;
  String get minCatalogPack => planPack.minCatalogPack;
  List<Object?> get plans => planPack.plans;

  /// Applies a channel's SDK gate when it references already verified bytes.
  PoseHubPlanSnapshot withMinSdk(String version) => PoseHubPlanSnapshot._(
    id,
    _sdkVersion(version),
    planPack,
    voiceManifest,
    _voiceBytes,
  );

  bool isCompatible({required String catalogPack, required String sdkVersion}) {
    final catalogOrder = comparePoseHubPacks(catalogPack, minCatalogPack);
    return catalogOrder != null &&
        catalogOrder >= 0 &&
        comparePoseHubSdkVersions(sdkVersion, minSdk) >= 0;
  }
}

/// Immutable, content-addressed snapshots with a separate active history for
/// each channel and App. The supplied [store] should be durable in production.
final class PoseHubChannelPlanStore {
  PoseHubChannelPlanStore({required this.store, required Uri channelUri})
    : _channelId = _sha(utf8.encode(channelUri.toString()));

  final PoseHubCatalogStore store;
  final String _channelId;
  static final _pendingWrites = Expando<Future<void>>();

  String _activePath(String app) =>
      '$_planRoot/channels/$_channelId/${_sha(utf8.encode(app))}.json';

  static String _snapshotPath(String id) => '$_planRoot/snapshots/$id';

  /// Saves a verified snapshot for future resumption without selecting it.
  /// An App can use this when starting a workout from its bundled plan.
  Future<void> retain(PoseHubPlanSnapshot snapshot) =>
      _write(() => _retain(snapshot));

  /// Commits the new selection only after its exact documents are durable.
  Future<void> install(PoseHubPlanSnapshot snapshot) => _write(() async {
    await _retain(snapshot);
    final history = await _history(snapshot.app);
    if (history.isNotEmpty &&
        history.first.id == snapshot.id &&
        history.first.minSdk == snapshot.minSdk) {
      return;
    }
    final entries = [
      (id: snapshot.id, minSdk: snapshot.minSdk),
      ...history.where((entry) => entry.id != snapshot.id),
    ];
    await store.writeAtomic(
      _activePath(snapshot.app),
      utf8.encode(
        jsonEncode([
          for (final entry in entries)
            {'id': entry.id, 'min_sdk': entry.minSdk},
        ]),
      ),
    );
  });

  /// Returns the most recently installed, intact snapshot that this App and
  /// catalogue can use. Unavailable or corrupt entries leave the old fallback.
  Future<PoseHubPlanSnapshot?> latestCompatible(
    String app, {
    required String catalogPack,
    required String sdkVersion,
  }) async {
    for (final entry in await _history(app)) {
      final stored = await restore(app, entry.id);
      if (stored == null) continue;
      final snapshot = stored.withMinSdk(entry.minSdk);
      if (snapshot.isCompatible(
        catalogPack: catalogPack,
        sdkVersion: sdkVersion,
      )) {
        return snapshot;
      }
    }
    return null;
  }

  /// Reads the exact pinned snapshot regardless of the active choice. A
  /// missing or damaged snapshot returns null instead of substituting a plan.
  Future<PoseHubPlanSnapshot?> restore(String app, String snapshotId) async {
    final snapshot = await lookup(snapshotId);
    return snapshot?.app == app ? snapshot : null;
  }

  /// Looks up locally verified documents by digest, independent of channel.
  Future<PoseHubPlanSnapshot?> lookup(String snapshotId) async {
    if (!_sha256Pattern.hasMatch(snapshotId)) return null;
    final prefix = _snapshotPath(snapshotId);
    try {
      final receiptBytes = await store.read('$prefix/receipt.json');
      if (receiptBytes == null) return null;
      final receipt = _object(
        jsonDecode(utf8.decode(receiptBytes)),
        'Stored plan receipt',
      );
      final minSdk = receipt['min_sdk'];
      if (minSdk is! String) return null;
      final pack = await store.read('$prefix/plan.json');
      if (pack == null || _sha(pack) != snapshotId) return null;
      final voice = await store.read('$prefix/voice.json');
      if (voice == null) return null;
      return PoseHubPlanSnapshot.fromBytes(pack, voice, minSdk: minSdk);
    } on Object {
      return null;
    }
  }

  Future<void> _retain(PoseHubPlanSnapshot snapshot) async {
    if (await lookup(snapshot.id) != null) return;
    final prefix = _snapshotPath(snapshot.id);
    await store.writeAtomic('$prefix/plan.json', snapshot.planPack.jsonBytes);
    await store.writeAtomic('$prefix/voice.json', snapshot._voiceBytes);
    await store.writeAtomic(
      '$prefix/receipt.json',
      utf8.encode(jsonEncode({'min_sdk': snapshot.minSdk})),
    );
  }

  Future<List<({String id, String minSdk})>> _history(String app) async {
    try {
      final bytes = await store.read(_activePath(app));
      if (bytes == null) return const [];
      final Object? history = jsonDecode(utf8.decode(bytes));
      if (history is! List<Object?>) return const [];
      final entries = <({String id, String minSdk})>[];
      for (final item in history) {
        if (item is! Map<String, Object?>) continue;
        final id = item['id'];
        final minSdk = item['min_sdk'];
        if (id is! String ||
            !_sha256Pattern.hasMatch(id) ||
            minSdk is! String) {
          continue;
        }
        try {
          entries.add((id: id, minSdk: _sdkVersion(minSdk)));
        } on FormatException {
          continue;
        }
      }
      return entries;
    } on Object {
      return const [];
    }
  }

  Future<void> _write(Future<void> Function() operation) {
    // Updaters and bundle readers sharing one store serialize publications.
    final previous = _pendingWrites[store] ?? Future<void>.value();
    final write = previous.then((_) => operation());
    final tail = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pendingWrites[store] = tail;
    return write.whenComplete(() {
      if (identical(_pendingWrites[store], tail)) _pendingWrites[store] = null;
    });
  }
}
