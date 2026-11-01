import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_theme.dart';
import 'pose_hub_pack_image_platform.dart' as platform;

/// The unchanged, bundled alpha-WebP cover. It never requests the network.
/// Covers authored at a later source frame retain their original pose; media
/// QA records these exceptions rather than silently replacing source assets.
class PoseHubStandingImage extends StatelessWidget {
  const PoseHubStandingImage({
    super.key,
    required this.action,
    this.theme = TrainerTheme.light,
  });

  final PoseHubPackAction action;
  final TrainerTheme theme;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/pose_hub/app-test-pack-r1/standing/${action.id}.webp',
    package: 'ugk_trainer',
    fit: BoxFit.contain,
    gaplessPlayback: true,
    semanticLabel: '${action.nameZh}站位图',
    errorBuilder: (_, _, _) => ColoredBox(color: theme.mediaStage),
  );
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
