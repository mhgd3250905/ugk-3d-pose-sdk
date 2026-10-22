// Ported from SmartFit@e8981ee lib/core/media/drill_media.dart (3D-Body
// DrillMedia value class). Added the light-stage render and the clip's
// asset path is what the player page plays (no fixed pack layout).

/// One prerecorded drill clip played by the WebView / iframe player.
class DrillMedia {
  const DrillMedia({
    required this.id,
    required this.videoAsset,
    required this.posterAsset,
    required this.duration,
    this.posterTime = 0,
    this.lightVideoAsset,
    this.lightPosterAsset,
    this.actionId,
    this.skin = 'realistic',
    this.theme = 'dark',
  });

  final String id;

  /// Optional manifest id when an app's own drill id differs.
  final String? actionId;
  final String skin;
  final String theme;

  /// Flutter asset keys (`assets/packs/h-squat/demo.mp4`).
  final String videoAsset;
  final String posterAsset;
  final double duration;
  final double posterTime;

  /// Same clip baked on a light stage, for light themes.
  final String? lightVideoAsset;
  final String? lightPosterAsset;

  String videoFor({required bool light}) =>
      light ? (lightVideoAsset ?? videoAsset) : videoAsset;
  String posterFor({required bool light}) =>
      light ? (lightPosterAsset ?? posterAsset) : posterAsset;
}
