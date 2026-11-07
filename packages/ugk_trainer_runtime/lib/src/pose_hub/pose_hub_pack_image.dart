import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_theme.dart';
import 'pose_hub_action_library.dart';
import 'pose_hub_image_cache.dart';
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
    this.mediaBaseUri,
    this.cache,
  });

  final PoseHubPackAction action;
  final TrainerTheme theme;

  /// Lists request the small catalogue thumbnail; large cards use the cover.
  final bool thumbnail;
  final Uri? mediaBaseUri;
  final PoseHubImageCache? cache;

  @override
  Widget build(BuildContext context) => PoseHubCatalogImage(
    id: action.id,
    name: action.nameZh,
    video: action.video,
    cover: action.cover,
    thumbnailFile: action.thumbnail,
    thumbnail: thumbnail,
    theme: theme,
    mediaBaseUri: mediaBaseUri,
    cache: cache,
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
    this.theme = TrainerTheme.light,
    this.thumbnail = false,
    this.mediaBaseUri,
    this.cache,
  });

  final String id;
  final String name;
  final PoseHubPackFile video;
  final PoseHubPackFile cover;
  final PoseHubPackFile thumbnailFile;
  final TrainerTheme theme;
  final bool thumbnail;
  final Uri? mediaBaseUri;
  final PoseHubImageCache? cache;

  @override
  State<PoseHubCatalogImage> createState() => _PoseHubCatalogImageState();
}

class _PoseHubCatalogImageState extends State<PoseHubCatalogImage> {
  static final _indices = Expando<Future<Map<String, Object?>>>();
  AssetBundle? _bundle;
  Uri? _verified;
  var _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    if (identical(bundle, _bundle)) return;
    _bundle = bundle;
    _start();
  }

  @override
  void didUpdateWidget(PoseHubCatalogImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldFile = oldWidget.thumbnail
        ? oldWidget.thumbnailFile
        : oldWidget.cover;
    final file = widget.thumbnail ? widget.thumbnailFile : widget.cover;
    if (oldWidget.id != widget.id ||
        oldWidget.video.path != widget.video.path ||
        oldWidget.video.sha256 != widget.video.sha256 ||
        oldFile.path != file.path ||
        oldFile.sha256 != file.sha256 ||
        oldFile.bytes != file.bytes ||
        oldWidget.mediaBaseUri != widget.mediaBaseUri ||
        !identical(oldWidget.cache, widget.cache)) {
      _start();
    }
  }

  void _start() {
    final generation = ++_generation;
    _verified = null;
    final bundle = _bundle!;
    final index = _indices[bundle] ??= _readIndex(bundle);
    unawaited(_resolve(index, generation));
  }

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
  ) async {
    try {
      final entries = await index;
      if (!mounted || generation != _generation) return;
      final entry = entries[widget.id];
      if (entry is Map<String, dynamic> &&
          entry['videoPath'] == widget.video.path &&
          entry['videoSha256'] == widget.video.sha256) {
        return;
      }
      final file = widget.thumbnail ? widget.thumbnailFile : widget.cover;
      final uri = await (widget.cache ?? PoseHubImageCache.shared).ensureFile(
        file,
        mediaBaseUri: widget.mediaBaseUri,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _verified = uri);
    } catch (_) {
      // Offline, unavailable and corrupt images all keep the quiet fallback.
    }
  }

  Widget _fallback() => Image.asset(
    '${PoseHubActionLibrary.standingAssetRoot}${widget.id}.webp'.replaceFirst(
      'packages/ugk_trainer/',
      '',
    ),
    key: ValueKey('standing-${widget.id}'),
    package: 'ugk_trainer',
    fit: BoxFit.contain,
    gaplessPlayback: true,
    semanticLabel: '${widget.name}站位图',
    errorBuilder: (_, _, _) => ColoredBox(color: widget.theme.mediaStage),
  );

  @override
  Widget build(BuildContext context) {
    final uri = _verified;
    if (uri == null) return _fallback();
    final file = widget.thumbnail ? widget.thumbnailFile : widget.cover;
    return platform.packImage(
      uri,
      key: ValueKey('${widget.id}/${file.sha256}'),
      fit: BoxFit.contain,
      semanticLabel: '${widget.name}站位图',
      errorBuilder: (_, _, _) => _fallback(),
      frameBuilder: (_, child, frame, synchronous) =>
          synchronous || frame != null ? child : _fallback(),
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
