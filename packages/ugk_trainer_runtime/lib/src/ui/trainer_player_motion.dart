import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Motion for the opt-in training player.
abstract final class PlayerMotion {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 380);
  static const emphasis = Duration(milliseconds: 480);
  static const count = Duration(milliseconds: 600);
  static const reducedFade = Duration(milliseconds: 150);
  static const stagger = Duration(milliseconds: 50);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;
  static const morph = Curves.easeInOutCubic;
  static const small = 8.0;
  static const normal = 12.0;
  static const large = 16.0;

  static const heroFlight = Duration(milliseconds: 420);
  static const dockDelay = Duration(milliseconds: 80);
  static const prepEnter = Duration(milliseconds: 280);
  static const prepHold = Duration(milliseconds: 800);
  static const sideHalf = Duration(milliseconds: 180);
  static const sideHold = Duration(milliseconds: 1200);
  static const actionOut = Duration(milliseconds: 200);
  static const actionIn = Duration(milliseconds: 280);
  static const controlsFade = Duration(milliseconds: 200);
  static const trackFill = Duration(milliseconds: 300);
  static const checkDraw = Duration(milliseconds: 400);
  static const finishGlow = Duration(milliseconds: 800);
  static const manualSlide = 24.0;
  static const phaseCueDelay = Duration(milliseconds: 200);
  static const phaseCapsuleGap = Duration(milliseconds: 60);
  static const phaseCapsuleIn = Duration(milliseconds: 220);
  static const phaseCapsuleSlide = 6.0;
  static const phaseStagger = Duration(milliseconds: 40);
  static const phaseShrinkDelay = Duration(milliseconds: 80);
  static const ringFill = Duration(milliseconds: 80);
  static const ringFade = Duration(milliseconds: 120);
  static const press = Duration(milliseconds: 120);

  static final spring = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: .7 * 2 * math.sqrt(180),
  );
}
