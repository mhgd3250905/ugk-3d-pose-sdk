import 'package:flutter/widgets.dart';

import '../media/media_controller.dart';
import '../media/packed_alpha_video.dart';

bool get supportsPoseHubPackPlayback => UgkPackedAlphaVideo.isSupported;

class PoseHubPackSurface extends StatelessWidget {
  const PoseHubPackSurface({
    super.key,
    required this.sourceUri,
    required this.controller,
  });
  final Uri sourceUri;
  final DrillMediaController controller;
  @override
  Widget build(BuildContext context) =>
      UgkPackedAlphaVideo.source(sourceUri: sourceUri, controller: controller);
}
