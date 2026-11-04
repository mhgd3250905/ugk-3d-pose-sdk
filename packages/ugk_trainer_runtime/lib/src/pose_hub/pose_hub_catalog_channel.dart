import 'dart:convert';

import 'package:ugk_coach/ugk_coach.dart' as coach;

/// Fallback pack version for a catalogue without a `pack` field.
const poseHubLegacyPackVersion = 'r1-v3';

/// The SDK version a pointer's `min_sdk` is compared against: the release
/// that ships the action-library hot update (see CHANGELOG); hosts may
/// override it through [PoseHubCatalogUpdateConfig.sdkVersion].
const poseHubCatalogSdkVersion = '0.8.0';

/// Media root of one immutable pack: `https://media.uuugk.win/pack/<pack>/`.
Uri poseHubMediaBaseUriForPack(String pack) {
  _checkPack(pack);
  return Uri.parse('https://media.uuugk.win/pack/$pack/');
}

/// The pack version of a catalogue: its `pack` field, or
/// [poseHubLegacyPackVersion] when absent (catalogues older than `pack`).
String poseHubPackVersionOf(coach.PoseHubAppTestCatalog catalog) {
  final pack = catalog.raw['pack'];
  if (pack == null) return poseHubLegacyPackVersion;
  if (pack is! String) {
    throw const FormatException('catalog.pack must be a string');
  }
  _checkPack(pack);
  return pack;
}

final _packPattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final _shaPattern = RegExp(r'^[a-f0-9]{64}$');
final _semverPattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');

void _checkPack(String pack) {
  if (pack.length > 64 || !_packPattern.hasMatch(pack)) {
    throw FormatException('Invalid pack version: $pack');
  }
}

/// Build-time release channel of a host App.
enum PoseHubCatalogChannel { dev, beta, stable }

/// Optional build-time configuration. Null anywhere keeps today's behavior:
/// the bundled catalogue only, no network check.
class PoseHubCatalogUpdateConfig {
  const PoseHubCatalogUpdateConfig({
    required this.channel,
    this.channelBaseUri = 'https://media.uuugk.win/pack/channels/',
    this.sdkVersion = poseHubCatalogSdkVersion,
    this.checkInterval = const Duration(hours: 24),
  });

  final PoseHubCatalogChannel channel;
  final String channelBaseUri;
  final String sdkVersion;
  final Duration checkInterval;

  Uri get pointerUri {
    final base = channelBaseUri.endsWith('/')
        ? channelBaseUri
        : '$channelBaseUri/';
    return Uri.parse(base).resolve('${channel.name}.json');
  }
}

/// One channel pointer file (`pack/channels/<channel>.json`).
class PoseHubCatalogPointer {
  const PoseHubCatalogPointer({
    required this.schema,
    required this.pack,
    required this.catalog,
    required this.catalogSha256,
    required this.catalogBytes,
    required this.minSdk,
    required this.publishedAt,
  });

  static const supportedSchema = 1;

  final int schema;
  final String pack;
  final Uri catalog;
  final String catalogSha256;
  final int catalogBytes;
  final String minSdk;
  final DateTime publishedAt;

  factory PoseHubCatalogPointer.fromBytes(List<int> bytes) =>
      PoseHubCatalogPointer.fromJson(jsonDecode(utf8.decode(bytes)));

  factory PoseHubCatalogPointer.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Pointer must be an object');
    final schema = json['schema'];
    if (schema != supportedSchema) {
      throw FormatException('Unsupported pointer schema: $schema');
    }
    final pack = json['pack'];
    if (pack is! String) throw const FormatException('pointer.pack missing');
    _checkPack(pack);
    final catalogText = json['catalog'];
    final catalog = catalogText is String ? Uri.tryParse(catalogText) : null;
    if (catalog == null ||
        catalog.scheme != 'https' ||
        catalog.host.isEmpty ||
        !catalog.path.endsWith('.json')) {
      throw const FormatException('pointer.catalog must be an https JSON URL');
    }
    final sha = json['catalog_sha256'];
    if (sha is! String || !_shaPattern.hasMatch(sha)) {
      throw const FormatException('pointer.catalog_sha256 invalid');
    }
    final size = json['catalog_bytes'];
    if (size is! int || size < 1 || size > 64 * 1024 * 1024) {
      throw const FormatException('pointer.catalog_bytes invalid');
    }
    final minSdk = json['min_sdk'];
    if (minSdk is! String || !_semverPattern.hasMatch(minSdk)) {
      throw const FormatException('pointer.min_sdk invalid');
    }
    final published = json['published_at'];
    final publishedAt = published is String
        ? DateTime.tryParse(published)
        : null;
    if (publishedAt == null) {
      throw const FormatException('pointer.published_at invalid');
    }
    return PoseHubCatalogPointer(
      schema: schema as int,
      pack: pack,
      catalog: catalog,
      catalogSha256: sha,
      catalogBytes: size,
      minSdk: minSdk,
      publishedAt: publishedAt,
    );
  }
}

/// Compares `x.y.z` versions; negative when [a] < [b].
int comparePoseHubSdkVersions(String a, String b) {
  final ma = _semverPattern.firstMatch(a);
  final mb = _semverPattern.firstMatch(b);
  if (ma == null || mb == null) {
    throw FormatException('Invalid SDK version: ${ma == null ? a : b}');
  }
  for (var i = 1; i <= 3; i++) {
    final d = int.parse(ma.group(i)!).compareTo(int.parse(mb.group(i)!));
    if (d != 0) return d;
  }
  return 0;
}
