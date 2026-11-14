import 'package:flutter/widgets.dart';

/// Presentation shared by SDK media views inside the V1 player stage.
class TrainerV1MediaScope extends InheritedWidget {
  const TrainerV1MediaScope({required super.child, super.key});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrainerV1MediaScope>() != null;

  @override
  bool updateShouldNotify(TrainerV1MediaScope oldWidget) => false;
}
