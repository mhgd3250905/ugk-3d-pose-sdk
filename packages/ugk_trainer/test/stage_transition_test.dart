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

    // Work (next-up pendant), then rest: the chip appears while the old
    // pendant is still fading out and the next clip is still "loading".
    await until(tester, find.byKey(const ValueKey('next-b')));
    final restChip = find.byKey(const ValueKey('sub-cue-b'));
    await until(tester, restChip);
    await tester.pump(const Duration(milliseconds: 200));
    final midFade = tester.getBottomLeft(restChip).dy;
    await tester.pump(const Duration(milliseconds: 900));
    final settled = tester.getBottomLeft(restChip).dy;

    expect(midFade, settled);
    expect(settled, prep);
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
}
