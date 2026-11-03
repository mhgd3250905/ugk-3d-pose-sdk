// SessionBuilder.sideSwitchMarginSeconds: estimate allowance for unilateral
// side switches; the played phases never change.
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  final rhythms = smartRhythms();
  final plan = planOf([
    reps('h-squat', 10, sets: 2, rest: 30),
    timed('s-figure4', 30, sets: 2, perSide: true, rest: 10),
  ]);
  final bilateral = planOf([reps('h-squat', 10, sets: 2, rest: 30)]);

  test('default margin is 0 and estimates equal the played timeline', () {
    final b = SessionBuilder(rhythms: rhythms);
    expect(b.sideSwitchMarginSeconds, 0);
    final played = b
        .phases(plan)
        .where((p) => p.kind != PhaseKind.prep)
        .fold(0.0, (s, p) => s + p.seconds);
    expect(b.planSeconds(plan), played);
    expect(b.sideSwitchCount(plan), 2);
  });

  test('a configured margin is added once per side switch', () {
    final base = SessionBuilder(rhythms: rhythms);
    final widened = SessionBuilder(
      rhythms: rhythms,
      sideSwitchMarginSeconds:
          SessionBuilder.recommendedSideSwitchMarginSeconds,
    );
    expect(
      widened.planSeconds(plan),
      base.planSeconds(plan) +
          2 * SessionBuilder.recommendedSideSwitchMarginSeconds,
    );
    expect(
      base.planSeconds(plan, sideSwitchMargin: 4),
      base.planSeconds(plan) + 8,
    );
    expect(
      widened.planSeconds(plan, sideSwitchMargin: 0),
      base.planSeconds(plan),
    );
    // Played phases are untouched.
    expect(
      widened.phases(plan).map((p) => p.seconds).toList(),
      base.phases(plan).map((p) => p.seconds).toList(),
    );
  });

  test('bilateral plans get no margin', () {
    final widened = SessionBuilder(
      rhythms: rhythms,
      sideSwitchMarginSeconds: 5,
    );
    expect(widened.sideSwitchCount(bilateral), 0);
    expect(
      widened.planSeconds(bilateral),
      SessionBuilder(rhythms: rhythms).planSeconds(bilateral),
    );
  });
}
