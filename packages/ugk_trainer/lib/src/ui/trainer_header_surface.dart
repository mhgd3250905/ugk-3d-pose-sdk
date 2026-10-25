import 'package:flutter/material.dart';

import 'trainer_control_surface.dart';
import 'trainer_glass.dart';
import 'trainer_stage.dart';
import 'trainer_theme.dart';

/// Optical accessory material for the fixed training header.
class TrainerHeaderSurface extends StatelessWidget {
  const TrainerHeaderSurface({
    super.key,
    required this.theme,
    required this.height,
    required this.padding,
    required this.child,
  });

  final TrainerTheme theme;
  final double height;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Existing hosts that deliberately supply their own painted material keep
    // that contract. The SDK presets use the optical accessory below.
    if (theme.glassStyle != null) {
      return TrainerHover(
        theme: theme,
        lift: 8,
        child: TrainerGlass(
          theme: theme,
          overMedia: true,
          radius: 24,
          height: height,
          padding: padding,
          child: child,
        ),
      );
    }
    return TrainerControlSurface(
      theme: theme,
      // Match the library's default continuous card corners.
      radius: 16,
      height: height,
      padding: padding,
      child: child,
    );
  }
}
