// Ported from SmartFit@e8981ee lib/core/media/media_view_stub.dart.
import 'package:flutter/widgets.dart';

import 'drill_media.dart';
import 'media_controller.dart';

class DrillMediaPlatformView extends StatefulWidget {
  const DrillMediaPlatformView({
    super.key,
    required this.media,
    required this.controller,
    required this.videoAsset,
    this.labels = const {},
    this.fit = 'contain',
    this.align = Alignment.center,
  });
  final DrillMedia media;
  final DrillMediaController controller;

  /// The clip to play (dark or light render of [media]).
  final String videoAsset;
  final Map<String, String> labels;
  final String fit;
  final Alignment align;
  @override
  State<DrillMediaPlatformView> createState() => _UnsupportedState();
}

class _UnsupportedState extends State<DrillMediaPlatformView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.reportError();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
