// sdk-stage-r6: page / phase changes must not move the subtitle chip or
// shift the tone of the HUD chips while the new clip loads.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

/// A clip that "loads": a short placeholder first, a taller frame later.
class _LoadingMedia extends StatefulWidget {
  const _LoadingMedia({super.key});
  @override
  State<_LoadingMedia> createState() => _LoadingMediaState();
}

class _LoadingMediaState extends State<_LoadingMedia> {
  bool _loaded = false;
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _loaded
      ? const ColoredBox(color: Colors.black, child: SizedBox(height: 400))
      : const ColoredBox(color: Colors.white, child: SizedBox(height: 40));
}

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TrainerPlayer(
          plan: planOf([timed('a', 2, rest: 10), timed('b', 5)]),
          drillOf: (id) =>
              TrainerDrill(id: id, name: 'name-$id', cue: 'cue-$id'),
          strings: TrainerStrings.en(),
          keepAlive: false,
          prepSeconds: 2,
          transitionSeconds: 10,
          mediaBuilder: (_, req) => _LoadingMedia(key: ValueKey(req.drill.id)),
          onFinished: (_) async {},
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> until(WidgetTester tester, Finder f) async {
    for (var i = 0; i < 100 && f.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(f, findsOneWidget);
  }

  testWidgets('subtitle chip keeps one position across phases and loading', (
    tester,
  ) async {
    await pump(tester);
    final prepChip = find.byKey(const ValueKey('sub-cue-a'));
    await until(tester, prepChip);
    await tester.pump(const Duration(milliseconds: 700));
    final prep = tester.getBottomLeft(prepChip).dy;
    // r7: the subtitle hangs below the pendant slot, lowest on the stage.
    expect(
      tester.getTopLeft(prepChip).dy,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('pendant-slot'))).bottom,
      ),
    );

    // Work (next-up pendant), then rest: the chip appears while the old
    // pendant is still fading out and the next clip is still "loading".
    await until(tester, find.byKey(const ValueKey('next-b')));
    final pendantSlot = tester.getRect(
      find.byKey(const ValueKey('pendant-slot')),
    );
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('next-b'))).dy,
      lessThanOrEqualTo(pendantSlot.bottom),
    );
    final restChip = find.byKey(const ValueKey('sub-cue-b'));
    await until(tester, restChip);
    await tester.pump(const Duration(milliseconds: 200));
    final midFade = tester.getBottomLeft(restChip).dy;
    await tester.pump(const Duration(milliseconds: 900));
    final settled = tester.getBottomLeft(restChip).dy;

    expect(midFade, settled);
    expect(settled, prep);
  });

  test('media chips: light frost in light mode, dark smoke in dark', () {
    expect(TrainerGlassStyle.light.overMediaIsLight, isTrue);
    expect(TrainerGlassStyle.dark.overMediaIsLight, isFalse);
    expect(TrainerTheme.light.glass.overMediaIsLight, isTrue);
    expect(TrainerTheme.dark.glass.overMediaIsLight, isFalse);
  });

  testWidgets('HUD chips on the clip take no backdrop sample', (tester) async {
    await pump(tester);
    await until(tester, find.byKey(const ValueKey('discomfort')));
    final onMedia = find.byWidgetPredicate(
      (w) => w is TrainerGlass && w.overMedia,
    );
    expect(onMedia, findsWidgets);
    expect(
      find.descendant(of: onMedia, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
  });

  // sdk-stage-r8: 完成本组 sits in the transport, below the clip's bottom
  // edge on phones, and keeps one position from set to set.
  for (final (w, h) in [(360.0, 780.0), (390.0, 844.0)]) {
    testWidgets('完成本组 below the clip, fixed across sets ${w.toInt()}x'
        '${h.toInt()}', (tester) async {
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: planOf([reps('a', 8, rest: 3), reps('b', 8)]),
            rhythms: {'a': Rhythm.selfPacedReps, 'b': Rhythm.selfPacedReps},
            drillOf: (id) =>
                TrainerDrill(id: id, name: 'name-$id', cue: 'cue-$id'),
            strings: TrainerStrings.zh(),
            keepAlive: false,
            prepSeconds: 0,
            mediaBuilder: (_, _) => const SizedBox.expand(),
            onFinished: (_) async {},
          ),
        ),
      );
      final done = find.byKey(const ValueKey('complete-set-button'));
      await until(tester, done);
      await tester.pump(const Duration(seconds: 1));
      final first = tester.getRect(done);
      final clip = tester.getRect(find.byKey(const ValueKey('media-a')));
      final pause = tester.getRect(find.byKey(const ValueKey('pause')));
      expect(first.top, greaterThanOrEqualTo(clip.bottom));
      expect(first.bottom, lessThan(pause.top));
      expect(first.height, greaterThanOrEqualTo(44));
      // The next-up chip stays in its slot, also under the figure's middle.
      final next = tester.getRect(find.byKey(const ValueKey('next-b')));
      expect(next.top, greaterThan(clip.center.dy));

      await tester.tap(done);
      await tester.pump(const Duration(milliseconds: 100));
      expect(done, findsNothing);
      // Rest, then the next set's lead-in, then its 完成本组.
      for (var i = 0; i < 400 && done.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done, findsOneWidget);
      expect(find.byKey(const ValueKey('media-b')), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getRect(done), first);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
