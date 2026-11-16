import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

PoseHubMediaTheme poseHubMediaThemeOf(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? PoseHubMediaTheme.dark
    : PoseHubMediaTheme.light;
