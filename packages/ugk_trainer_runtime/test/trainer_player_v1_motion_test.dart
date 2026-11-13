import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/ui/countdown_ring.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_motion.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_strings.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_theme.dart';
import 'package:ugk_trainer_runtime/src/ui/ugk_play_pause_button.dart';

void main() {
  Future<void> showPhase(
    WidgetTester tester, {
    required int identity,
    required String value,
    bool reduced = false,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: Center(
            child: TrainerPhaseSwitcher(
              identity: identity,
              enterOffset: 12,
              exitOffset: 12,
              child: Text(value),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('phase snapshots keep only the latest outgoing text and unit', (
    tester,
  ) async {
    await showPhase(tester, identity: 1, value: '12 sec');
    final initial = tester.element(find.text('12 sec'));
    await showPhase(tester, identity: 1, value: '11 sec');
    expect(tester.element(find.text('11 sec')), same(initial));
    expect(find.text('12 sec'), findsNothing);

    await showPhase(tester, identity: 2, value: '3 reps');
    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('11 sec'), findsOneWidget);
    expect(find.text('3 reps'), findsOneWidget);
    await showPhase(tester, identity: 3, value: '20 sec');
    expect(find.text('11 sec'), findsNothing);
    expect(find.text('3 reps'), findsOneWidget);
    expect(find.text('20 sec'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.text('3 reps'), findsNothing);
    expect(find.text('20 sec'), findsOneWidget);
  });

  testWidgets('reduced phase transition uses a 150 ms fade without motion', (
    tester,
  ) async {
    await showPhase(tester, identity: 1, value: 'One', reduced: true);
    await showPhase(tester, identity: 2, value: 'Two', reduced: true);
    await tester.pump(const Duration(milliseconds: 75));
    final switcher = find.byType(TrainerPhaseSwitcher);
    final transforms = tester.widgetList<Transform>(
      find.descendant(of: switcher, matching: find.byType(Transform)),
    );
    expect(transforms, isNotEmpty);
    expect(transforms.every((widget) => widget.transform.isIdentity()), isTrue);
    final fades = tester.widgetList<Opacity>(
      find.descendant(of: switcher, matching: find.byType(Opacity)),
    );
    expect(
      fades.map((widget) => widget.opacity),
      everyElement(closeTo(.5, .01)),
    );
    await tester.pump(const Duration(milliseconds: 75));
    expect(find.text('One'), findsNothing);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('V1 ring finishes the old sweep and retains the same control', (
    tester,
  ) async {
    final progress = ValueNotifier<double>(.65);
    addTearDown(progress.dispose);
    var taps = 0;
    Future<void> show(int phase, {bool playing = true}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: UgkPlayPauseButton(
              key: const ValueKey('pause'),
              isPlaying: playing,
              progress: progress,
              onTap: () => taps++,
              theme: TrainerTheme.playerV1,
              strings: TrainerStrings.en(),
              remaining: true,
              ringPhase: phase,
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('pause'));
    final outgoing = find.byKey(const ValueKey('ring-outgoing'));
    final ring = find.byKey(const ValueKey('ring'));
    TrainerRingPainter painter(Finder finder) =>
        tester.widget<CustomPaint>(finder).painter! as TrainerRingPainter;
    double sweep(Finder finder) {
      final visual = painter(finder);
      return visual.remaining
          ? 1 - visual.progress.value
          : visual.progress.value;
    }

    await show(1);
    final original = tester.state(button);
    progress.value = .75;
    await tester.pump();
    expect(sweep(ring), closeTo(.25, .01));
    // The live notifier can be reset before the new generation rebuilds.
    progress.value = .1;
    await show(2);
    expect(tester.state(button), same(original));
    expect(sweep(outgoing), closeTo(.25, .01));
    expect(sweep(ring), 0);
    await tester.pump(const Duration(milliseconds: 80));
    expect(sweep(outgoing), closeTo(1, .01));
    await tester.pump(const Duration(milliseconds: 120));
    expect(outgoing, findsNothing);
    expect(sweep(ring), closeTo(0, .01));
    await tester.tap(button);
    expect(taps, 1);
    final glyph = tester.widget<AnimatedIcon>(find.byType(AnimatedIcon));
    expect(glyph.icon, AnimatedIcons.play_pause);
    await show(2, playing: false);
    await tester.pump(const Duration(milliseconds: 240));
    expect(sweep(ring), closeTo(.9, .01));
    expect(painter(ring).progress, same(progress));
    expect(tester.state(button), same(original));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
