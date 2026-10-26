import 'package:flutter/widgets.dart';

import '../media/media_controller.dart';

bool get supportsPoseHubPackPlayback => false;

class PoseHubPackSurface extends StatelessWidget {
  const PoseHubPackSurface({
    super.key,
    required this.sourceUri,
    required this.controller,
  });
  final Uri sourceUri;
  final DrillMediaController controller;
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
