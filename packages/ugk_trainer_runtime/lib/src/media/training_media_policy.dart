import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../pose_hub/pose_hub_catalog_channel.dart';
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

  /// The bundled catalogue's media root (r2-v2 reuses r2-v1 media); other
  /// packs use [poseHubMediaBaseUriForPack] with [poseHubMediaPackOf].
  static const publicBaseUrl = 'https://media.uuugk.win/pack/r2-v1/';
  final CatalogMediaRepository repository;
  final String posterAssetRoot;

  /// Enables the single next-action lookahead. Preparing the current action
  /// does not depend on this speculative-prefetch switch.
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
    CatalogMediaTimingCallback? onTiming,
  }) async {
    final data = await (bundle ?? rootBundle).load(manifestAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final catalog = PoseHubAppTestCatalog.fromBytes(bytes);
    final repository = await CatalogMediaRepository.create(
      catalog: catalog,
      catalogRevision: sha256.convert(bytes).toString(),
      mediaBaseUrls:
          mediaBaseUrls ??
          [poseHubMediaBaseUriForPack(poseHubMediaPackOf(catalog))],
      rootDirectory: rootDirectory,
      maxVideoCacheBytes: maxVideoCacheBytes,
      onTiming: onTiming,
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

  /// Prepare the current video immediately, then at most the next video.
  /// Lookahead never competes with the current video's download. The optional
  /// guard drops stale lookahead after a session jumps to another action.
  /// No download failure gates training's clock, voice or route.
  Future<void> prefetchActions(
    Iterable<String> ids, {
    bool Function()? isCurrent,
  }) async {
    final actions = [
      for (final id in ids.toSet()) ?actionFor(id),
    ].take(2).toList();
    if (actions.isEmpty) return;
    try {
      await repository.ensureFileWithPriority(actions.first.video);
      if (!prefetchBeforeTraining ||
          actions.length < 2 ||
          isCurrent?.call() == false) {
        return;
      }
      await repository.ensureFileWithPriority(
        actions[1].video,
        priority: CatalogMediaPriority.prefetch,
      );
    } catch (_) {
      // File state exposes a retryable failure; the training clock continues.
    }
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
