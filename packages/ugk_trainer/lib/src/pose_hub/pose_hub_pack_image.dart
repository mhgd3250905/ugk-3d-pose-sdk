import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_theme.dart';
import 'pose_hub_pack_image_platform.dart' as platform;

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
