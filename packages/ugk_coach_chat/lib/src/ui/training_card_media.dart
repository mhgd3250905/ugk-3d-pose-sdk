import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/chat_theme.dart';

/// Warms the first training poster when an entry is built. The SDK card keeps
/// its normal layout, expanded state, and media builders without interception.
class TrainingCardMedia extends StatefulWidget {
  const TrainingCardMedia({
    super.key,
    required this.actionId,
    required this.child,
  });

  final String actionId;
  final Widget child;

  @override
  State<TrainingCardMedia> createState() => _TrainingCardMediaState();
}

class _TrainingCardMediaState extends State<TrainingCardMedia> {
  String? _warmed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warm();
  }

  @override
  void didUpdateWidget(TrainingCardMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.actionId, oldWidget.actionId)) _warm();
  }

  void _warm() {
    final signature =
        '${widget.actionId}/${Theme.of(context).brightness}/'
        '${(MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round()}';
    if (_warmed == signature) return;
    _warmed = signature;
    final preload = ChatTheme.of(context).visual.preloadPoster;
    if (preload != null) unawaited(preload(context, widget.actionId));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
