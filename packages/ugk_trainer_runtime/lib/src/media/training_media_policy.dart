import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'catalog_media_repository.dart';

/// Opt-in delivery of the shared action package. Only its frame-zero posters
/// are bundled; videos are verified and cached by the SDK repository.
/// The host owns the repository and disposes it with its application services.
class TrainingMediaPolicy {
  const TrainingMediaPolicy({
    required this.repository,
    this.posterAssetRoot = 'assets/public_posters/',
    this.prefetchBeforeTraining = true,
  });

  static const publicBaseUrl = 'https://media.uuugk.win/pack/r1-v3/';
  final CatalogMediaRepository repository;
  final String posterAssetRoot;
  final bool prefetchBeforeTraining;
  PoseHubAppTestCatalog get catalog => repository.catalog;

  /// Reads the bundled public manifest. No video is downloaded during setup.
  static Future<TrainingMediaPolicy> load({
    required String manifestAsset,
    String posterAssetRoot = 'assets/public_posters/',
    List<Uri>? mediaBaseUrls,
    AssetBundle? bundle,
    String? rootDirectory,
    int maxVideoCacheBytes = 300000000,
    bool prefetchBeforeTraining = true,
  }) async {
    final data = await (bundle ?? rootBundle).load(manifestAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final repository = await CatalogMediaRepository.create(
      catalog: PoseHubAppTestCatalog.fromBytes(bytes),
      catalogRevision: sha256.convert(bytes).toString(),
      mediaBaseUrls: mediaBaseUrls ?? [Uri.parse(publicBaseUrl)],
      rootDirectory: rootDirectory,
      maxVideoCacheBytes: maxVideoCacheBytes,
    );
    return TrainingMediaPolicy(
      repository: repository,
      posterAssetRoot: posterAssetRoot,
      prefetchBeforeTraining: prefetchBeforeTraining,
    );
  }

  PoseHubPackAction? actionFor(String id) => catalog.tryGet(id);

  /// This root contains the public package's standing frame-zero images,
  /// never the legacy App posters or the later-pose catalogue covers.
  String? posterAssetFor(String id) {
    if (actionFor(id) == null) return null;
    final root = posterAssetRoot.endsWith('/')
        ? posterAssetRoot
        : '$posterAssetRoot/';
    return '$root$id.webp';
  }

  /// Start before training, without gating its clock, voice or route.
  /// Individual failures remain visible through repository.watchFile(video).
  Future<void> prefetchActions(Iterable<String> ids) async {
    if (!prefetchBeforeTraining) return;
    await Future.wait([
      for (final id in ids.toSet())
        if (actionFor(id) case final action?)
          repository
              .ensureFile(action.video)
              .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
  }
}

class TrainingMediaPolicyScope extends InheritedWidget {
  const TrainingMediaPolicyScope({
    super.key,
    required this.policy,
    required super.child,
  });
  final TrainingMediaPolicy policy;
  static TrainingMediaPolicy? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TrainingMediaPolicyScope>()
      ?.policy;
  static TrainingMediaPolicy? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TrainingMediaPolicyScope>()?.policy;
  @override
  bool updateShouldNotify(TrainingMediaPolicyScope oldWidget) =>
      oldWidget.policy != policy;
}
