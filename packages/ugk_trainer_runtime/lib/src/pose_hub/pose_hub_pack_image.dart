import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../media/catalog_media_repository.dart';
import '../ui/trainer_theme.dart';
import 'pose_hub_action_library.dart';
import 'pose_hub_image_cache.dart';
import 'pose_hub_media_theme.dart';
import 'pose_hub_pack_image_platform.dart' as platform;

export 'pose_hub_image_cache.dart';

/// Uses a bundled standing frame only for the video it was generated from.
/// Newer media uses the catalogue's verified cover/thumbnail, keeping the
/// bundled frame underneath until a replacement has decoded successfully.
class PoseHubStandingImage extends StatelessWidget {
  const PoseHubStandingImage({
    super.key,
    required this.action,
    this.theme = TrainerTheme.light,
    this.thumbnail = false,
    this.preferCatalogArtwork = false,
    this.fit = BoxFit.contain,
    this.mediaBaseUri,
    this.cache,
    this.repository,
    this.legacyFallback,
  });

  final PoseHubPackAction action;
  final TrainerTheme theme;

  /// Lists request the small catalogue thumbnail; large cards use the cover.
  final bool thumbnail;

  /// Prefers current catalogue artwork even if the bundled video still matches.
  final bool preferCatalogArtwork;
  final BoxFit fit;
  final Uri? mediaBaseUri;
  final PoseHubImageCache? cache;

  /// Uses the host's verified media repository when one is already in scope.
  final CatalogMediaRepository? repository;

  /// An existing poster to keep visible until the selected image is ready.
  final Widget? legacyFallback;

  @override
  Widget build(BuildContext context) => PoseHubCatalogImage(
    id: action.id,
    name: action.nameZh,
    video: action.video,
    cover: action.cover,
    thumbnailFile: action.thumbnail,
    standingFile: action.mediaFor(null).standing,
    themedMedia: action.themedMedia,
    thumbnail: thumbnail,
    preferCatalogArtwork: preferCatalogArtwork,
    fit: fit,
    theme: theme,
    mediaBaseUri: mediaBaseUri,
    cache: cache,
    repository: repository,
    legacyFallback: legacyFallback,
  );
}

/// Shared entry for cards whose lightweight AI catalogue carries file
/// descriptors rather than the complete [PoseHubPackAction].
class PoseHubCatalogImage extends StatefulWidget {
  const PoseHubCatalogImage({
    super.key,
    required this.id,
    required this.name,
    required this.video,
    required this.cover,
    required this.thumbnailFile,
    this.standingFile,
    this.themedMedia = const {},
    this.theme = TrainerTheme.light,
    this.thumbnail = false,
    this.preferCatalogArtwork = false,
    this.fit = BoxFit.contain,
    this.mediaBaseUri,
    this.cache,
    this.repository,
    this.legacyFallback,
  });

  final String id;
  final String name;
  final PoseHubPackFile video;
  final PoseHubPackFile cover;
  final PoseHubPackFile thumbnailFile;
  final PoseHubPackFile? standingFile;
  final Map<PoseHubMediaTheme, PoseHubPackMediaFiles> themedMedia;
  final TrainerTheme theme;
  final bool thumbnail;

  /// Prefers current catalogue artwork even if the bundled video still matches.
  final bool preferCatalogArtwork;
  final BoxFit fit;
  final Uri? mediaBaseUri;
  final PoseHubImageCache? cache;

  /// Uses the host's verified media repository when one is already in scope.
  final CatalogMediaRepository? repository;

  /// An existing poster to keep visible until the selected image is ready.
  final Widget? legacyFallback;

  @override
  State<PoseHubCatalogImage> createState() => _PoseHubCatalogImageState();
}

typedef _ArtworkSelection = ({
  PoseHubMediaTheme? theme,
  PoseHubPackFile video,
  PoseHubPackFile image,
  PoseHubPackFile? fallbackImage,
});

class _PoseHubCatalogImageState extends State<PoseHubCatalogImage> {
  static final _indices = Expando<Future<Map<String, Object?>>>();
  AssetBundle? _bundle;
  _ArtworkSelection? _selected;
  PoseHubMediaTheme? _bundledTheme;
  ({PoseHubPackFile file, Uri uri})? _verified;
  var _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateArtwork();
  }

  @override
  void didUpdateWidget(PoseHubCatalogImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateArtwork(
      force:
          oldWidget.id != widget.id ||
          oldWidget.preferCatalogArtwork != widget.preferCatalogArtwork ||
          oldWidget.mediaBaseUri != widget.mediaBaseUri ||
          !identical(oldWidget.cache, widget.cache) ||
          !identical(oldWidget.repository, widget.repository),
    );
  }

  void _updateArtwork({bool force = false}) {
    final bundle = DefaultAssetBundle.of(context);
    final theme = poseHubMediaThemeOf(context);
    final media = widget.themedMedia[theme];
    final ordinary = widget.thumbnail
        ? widget.thumbnailFile
        : widget.standingFile ?? widget.cover;
    final selected = (
      theme: media == null ? null : theme,
      video: media?.video ?? widget.video,
      image: media == null
          ? ordinary
          : widget.thumbnail
          ? media.thumbnail
          : media.standing ?? media.cover,
      fallbackImage: media != null && widget.preferCatalogArtwork
          ? ordinary
          : null,
    );
    final previous = _selected;
    if (!force &&
        identical(bundle, _bundle) &&
        previous != null &&
        previous.theme == selected.theme &&
        previous.video.path == selected.video.path &&
        previous.video.sha256 == selected.video.sha256 &&
        _sameFile(previous.image, selected.image) &&
        _sameFile(previous.fallbackImage, selected.fallbackImage)) {
      return;
    }
    _bundle = bundle;
    _selected = selected;
    _bundledTheme = null;
    _verified = null;
    final generation = ++_generation;
    final index = _indices[bundle] ??= _readIndex(bundle);
    unawaited(_resolve(index, generation, selected));
  }

  static bool _sameFile(PoseHubPackFile? a, PoseHubPackFile? b) =>
      a?.path == b?.path &&
      a?.sha256 == b?.sha256 &&
      a?.bytes == b?.bytes &&
      a?.downloadUri == b?.downloadUri;

  static Future<Map<String, Object?>> _readIndex(AssetBundle bundle) async {
    try {
      final raw = jsonDecode(
        await bundle.loadString(
          '${PoseHubActionLibrary.standingAssetRoot}index.json',
        ),
      );
      if (raw is Map<String, dynamic> && raw['schema'] == 1) {
        final actions = raw['actions'];
        if (actions is Map<String, dynamic>) return actions;
      }
    } catch (_) {
      // Missing old-host metadata never breaks a card or opens an error UI.
    }
    return const {};
  }

  Future<void> _resolve(
    Future<Map<String, Object?>> index,
    int generation,
    _ArtworkSelection selected,
  ) async {
    final entries = await index;
    if (!mounted || generation != _generation) return;
    final action = entries[widget.id];
    final themes = action is Map<String, Object?> ? action['themes'] : null;
    final entry = selected.theme == null
        ? action
        : themes is Map<String, Object?>
        ? themes[selected.theme!.name]
        : null;
    final standing = selected.theme == null
        ? widget.standingFile
        : widget.themedMedia[selected.theme]?.standing;
    if (standing == null &&
        entry is Map<String, Object?> &&
        entry['videoPath'] == selected.video.path &&
        entry['videoSha256'] == selected.video.sha256) {
      if (selected.theme != null) {
        setState(() => _bundledTheme = selected.theme);
      }
      if (!widget.preferCatalogArtwork) return;
    }

    for (final file in [selected.image, ?selected.fallbackImage]) {
      try {
        final repository = widget.repository;
        final uri = await (repository != null
            ? repository.ensureFile(file)
            : (widget.cache ?? PoseHubImageCache.shared).ensureFile(
                file,
                mediaBaseUri: widget.mediaBaseUri,
              ));
        if (!mounted || generation != _generation) return;
        setState(() => _verified = (file: file, uri: uri));
        return;
      } catch (_) {
        if (!mounted || generation != _generation) return;
        // Try ordinary catalogue art when the theme's file is unavailable.
      }
    }
  }

  Widget _fallback([PoseHubMediaTheme? theme]) {
    if (theme == null) {
      if (widget.legacyFallback case final fallback?) return fallback;
    }
    final basename = theme == null ? widget.id : '${widget.id}.${theme.name}';
    return Image.asset(
      '${PoseHubActionLibrary.standingAssetRoot}$basename.webp'.replaceFirst(
        'packages/ugk_trainer/',
        '',
      ),
      key: ValueKey('standing-$basename'),
      package: 'ugk_trainer',
      fit: widget.fit,
      gaplessPlayback: true,
      semanticLabel: '${widget.name}站位图',
      errorBuilder: (_, _, _) => theme == null
          ? ColoredBox(color: widget.theme.mediaStage)
          : _fallback(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final verified = _verified;
    if (verified == null) return _fallback(_bundledTheme);
    return platform.packImage(
      verified.uri,
      key: ValueKey('${widget.id}/${verified.file.sha256}'),
      fit: widget.fit,
      semanticLabel: '${widget.name}站位图',
      errorBuilder: (_, _, _) => _fallback(_bundledTheme),
      frameBuilder: (_, child, frame, synchronous) =>
          synchronous || frame != null ? child : _fallback(_bundledTheme),
    );
  }
}

/// A catalog-referenced original cover/thumbnail, from one complete installed
/// pack or its same-origin Web mount. No asset is renamed or recompressed.
class PoseHubPackImage extends StatelessWidget {
  const PoseHubPackImage({
    super.key,
    required this.file,
    required this.baseUri,
    this.fit = BoxFit.contain,
    this.semanticLabel,
    this.theme = TrainerTheme.light,
  });
  final PoseHubPackFile file;
  final Uri baseUri;
  final BoxFit fit;
  final String? semanticLabel;
  final TrainerTheme theme;

  @override
  Widget build(BuildContext context) => platform.packImage(
    file.resolve(baseUri),
    fit: fit,
    semanticLabel: semanticLabel,
    errorBuilder: (_, _, _) => Semantics(
      label: semanticLabel ?? '动作图片暂不可用',
      child: ColoredBox(
        color: theme.surfaceHigh,
        child: Center(
          child: Icon(Icons.broken_image_outlined, color: theme.muted),
        ),
      ),
    ),
  );
}
