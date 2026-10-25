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
    this.videoAvailable = true,
    this.actionId,
    this.skin = 'realistic',
    this.theme = 'dark',
    this.packedAlphaVideoAsset,
    this.packedAlphaPosterAsset,
    this.bundledOnly = false,
  });

  final String id;

  /// Optional manifest id when an app's own drill id differs.
  final String? actionId;
  final String skin;
  final String theme;

  /// Optional H.264 frame with RGB above a same-size grayscale alpha plane.
  /// The waiting image must be frame zero of this exact clip, not its cover.
  /// Existing opaque assets remain the fallback on unsupported/error backends.
  final String? packedAlphaVideoAsset;
  final String? packedAlphaPosterAsset;

  /// The host has verified and bundled these assets; do not resolve/download
  /// them through an inherited repository for an unrelated catalog version.
  final bool bundledOnly;

  bool get hasPackedAlpha =>
      packedAlphaVideoAsset?.isNotEmpty == true &&
      packedAlphaPosterAsset?.isNotEmpty == true;

  /// Flutter asset keys (`assets/packs/h-squat/demo.mp4`).
  final String videoAsset;
  final String posterAsset;
  final double duration;
  final double posterTime;

  /// Same clip baked on a light stage, for light themes.
  final String? lightVideoAsset;
  final String? lightPosterAsset;

  /// False when the host's media index explicitly has no clip for this move.
  /// A missing/broken clip that was declared available remains a real error.
  final bool videoAvailable;

  String videoFor({required bool light}) =>
      light ? (lightVideoAsset ?? videoAsset) : videoAsset;
  String posterFor({required bool light}) =>
      light ? (lightPosterAsset ?? posterAsset) : posterAsset;
}
