import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/src/ui/trainer_completion.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

const _duration = Duration(milliseconds: 280);

class _ChromeFixture {
  final gate = Completer<void>();
  final requests = <TrainerMediaRequest>[];
  final saves = <SessionResult>[];
  int mediaBuilds = 0;
  int mediaMounts = 0;
  int mediaDisposals = 0;
  int discomforts = 0;
}

class _MediaProbe extends StatefulWidget {
  const _MediaProbe(this.fixture);
  final _ChromeFixture fixture;

  @override
  State<_MediaProbe> createState() => _MediaProbeState();
}

class _MediaProbeState extends State<_MediaProbe> {
  @override
  void initState() {
    super.initState();
    widget.fixture.mediaMounts++;
  }

  @override
  void dispose() {
    widget.fixture.mediaDisposals++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: ValueKey('chrome-media'), color: Colors.grey);
}

AnimationController _controller(WidgetTester tester, {double value = 1}) {
  final controller = AnimationController(
    vsync: tester,
    duration: _duration,
    value: value,
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<_ChromeFixture> _mount(
  WidgetTester tester, {
  Animation<double>? animation,
  bool gated = true,
  bool reduced = false,
  TrainerStartMode startMode = TrainerStartMode.training,
  TrainingPlan? plan,
  int prepSeconds = 10,
  Future<void> Function(SessionResult)? save,
  VoidCallback? onExitStarted,
}) async {
  final fixture = _ChromeFixture();
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: TrainerPlayer(
        plan: plan ?? planOf([timed('a', 60), timed('b', 60)]),
        drillOf: (id) => TrainerDrill(
          id: id,
          name: 'Move $id',
          cues: const ['Move slowly.', 'Keep breathing.'],
        ),
        strings: TrainerStrings.en(),
        theme: TrainerTheme.light,
        prepSeconds: prepSeconds,
        keepAlive: false,
        startMode: startMode,
        startGate: gated ? fixture.gate.future : null,
        chromeAnimation: animation,
        onExitStarted: onExitStarted,
        onDiscomfort: (_, _) async {
          fixture.discomforts++;
          return null;
        },
        mediaBuilder: (_, request) {
          fixture.requests.add(request);
          fixture.mediaBuilds++;
          return _MediaProbe(fixture);
        },
        onFinished: (result) async {
          fixture.saves.add(result);
          await save?.call(result);
        },
      ),
    ),
  );
  await tester.pump();
  return fixture;
}

Finder _layer(String name) => find.byKey(ValueKey('trainer-chrome-$name'));

Opacity _opacity(String name) => testerWidget<Opacity>(
  find.descendant(of: _layer(name), matching: find.byType(Opacity)).first,
);

// Read the controlled wrapper itself, before the control's own animations.
T testerWidget<T extends Widget>(Finder finder) =>
    finder.evaluate().single.widget as T;

Transform _transform(String name) => _opacity(name).child! as Transform;

double _progress(double value, double start, double end, bool reverse) {
  final local = ((value - start) / (end - start)).clamp(0.0, 1.0);
  return (reverse ? Curves.easeInCubic : Curves.easeOutCubic).transform(local);
}

void _expectLayers(double value, {bool reverse = false, bool reduced = false}) {
  const layers = <String, (double, double, double)>{
    'info': (0, 200 / 280, -12),
    'hud': (20 / 280, 220 / 280, -8),
    'cues': (40 / 280, 240 / 280, 16),
    'transport-digits': (60 / 280, 260 / 280, 16),
    'previous': (60 / 280, 260 / 280, 16),
    'next': (60 / 280, 260 / 280, 16),
  };
  for (final entry in layers.entries) {
    final (start, end, offset) = entry.value;
    final progress = _progress(value, start, end, reverse);
    expect(_layer(entry.key), findsOneWidget, reason: entry.key);
    expect(
      _opacity(entry.key).opacity,
      closeTo(progress, .00001),
      reason: entry.key,
    );
    expect(testerWidget<IgnorePointer>(_layer(entry.key)).ignoring, value < 1);
    if (reduced) {
      expect(
        _opacity(entry.key).child,
        isNot(isA<Transform>()),
        reason: entry.key,
      );
    } else {
      expect(
        _transform(entry.key).transform.storage[13],
        closeTo(offset * (1 - progress), .00001),
        reason: entry.key,
      );
      expect(_transform(entry.key).transform.storage[12], 0, reason: entry.key);
    }
  }
  final local = ((value - 60 / 280) / (1 - 60 / 280)).clamp(0.0, 1.0);
  final opacity = (reverse ? Curves.easeInCubic : Curves.easeOutCubic)
      .transform(local);
  expect(_opacity('pause').opacity, closeTo(opacity, .00001));
  expect(testerWidget<IgnorePointer>(_layer('pause')).ignoring, value < 1);
  if (reduced) {
    expect(_opacity('pause').child, isNot(isA<Transform>()));
  } else {
    final curve = reverse ? Curves.easeInCubic : Curves.easeOutBack;
    final scale = .85 + .15 * curve.transform(local);
    expect(_transform('pause').transform.storage[0], closeTo(scale, .00001));
    expect(_transform('pause').transform.storage[5], closeTo(scale, .00001));
  }
}

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  for (var left = milliseconds; left > 0;) {
    final step = left < 16 ? left : 16;
    await tester.pump(Duration(milliseconds: step));
    left -= step;
  }
}

void main() {
  for (final value in [0.0, .25, .5, 1.0]) {
    testWidgets(
      'chrome forward value $value follows the fixed layer intervals',
      (tester) async {
        final animation = _controller(tester, value: value);
        await _mount(tester, animation: animation);
        _expectLayers(value);
      },
    );
  }

  testWidgets('reverse uses easeInCubic for every layer and pause scale', (
    tester,
  ) async {
    final animation = _controller(tester);
    await _mount(tester, animation: animation);
    for (final value in [.5, .25, 0.0]) {
      animation.reverse(from: 1);
      await tester.pump();
      await tester.pump(Duration(microseconds: ((1 - value) * 280000).round()));
      expect(animation.value, closeTo(value, .00001));
      _expectLayers(value, reverse: true);
    }
    animation.stop();
  });

  testWidgets(
    'reduced motion retains alpha without layer translation or scale',
    (tester) async {
      final animation = _controller(tester, value: .5);
      await _mount(tester, animation: animation, reduced: true);
      _expectLayers(.5, reduced: true);
      animation.reverse(from: 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      _expectLayers(.5, reverse: true, reduced: true);
      animation.stop();
    },
  );

  testWidgets(
    'transition layers ignore pointer input until the raw value reaches one',
    (tester) async {
      final animation = _controller(tester, value: .5);
      final fixture = await _mount(tester, animation: animation, gated: false);
      final paused = fixture.requests.last.paused;
      for (final key in ['pause', 'close', 'prev', 'skip', 'discomfort']) {
        await tester.tap(find.byKey(ValueKey(key)), warnIfMissed: false);
        await tester.pump();
      }
      await tester.tap(find.byType(TrainerCueCarousel), warnIfMissed: false);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(fixture.discomforts, 0);
      expect(fixture.requests.last.drill.id, 'a');
      expect(fixture.requests.last.paused, paused);
      animation.value = 1;
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump();
      expect(fixture.requests.last.paused, isNot(paused));
    },
  );

  testWidgets(
    'chrome values never fade the media or floor or rebuild the media',
    (tester) async {
      final animation = _controller(tester, value: 0);
      final fixture = await _mount(tester, animation: animation);
      final builds = fixture.mediaBuilds;
      final mediaState = tester.state(find.byType(_MediaProbe));
      for (final value in [.25, .5, 1.0, 0.0]) {
        animation.value = value;
        await tester.pump();
        expect(fixture.mediaBuilds, builds);
        expect(fixture.mediaMounts, 1);
        expect(fixture.mediaDisposals, 0);
        expect(tester.state(find.byType(_MediaProbe)), same(mediaState));
        for (final finder in [
          find.byKey(const ValueKey('chrome-media')),
          find.byType(TrainerStageFloor),
        ]) {
          finder.evaluate().single.visitAncestorElements((element) {
            if (element.widget case final Opacity opacity) {
              expect(opacity.opacity, 1);
            }
            if (element.widget case final FadeTransition fade) {
              expect(fade.opacity.value, 1);
            }
            return true;
          });
        }
      }
    },
  );

  testWidgets('null chrome adds no layer wrappers to the existing player', (
    tester,
  ) async {
    await _mount(tester, gated: false);
    for (final name in [
      'info',
      'hud',
      'cues',
      'transport-digits',
      'previous',
      'next',
      'pause',
      'done',
    ]) {
      expect(_layer(name), findsNothing);
    }
    expect(find.byKey(const ValueKey('close')), findsOneWidget);
    expect(find.byKey(const ValueKey('pause')), findsOneWidget);
    expect(find.byType(TrainerCueCarousel), findsOneWidget);
  });

  testWidgets(
    'preview ignores a zero chrome animation and a pending start gate',
    (tester) async {
      final animation = _controller(tester, value: 0);
      final fixture = await _mount(
        tester,
        animation: animation,
        startMode: TrainerStartMode.preview,
      );
      for (final name in [
        'info',
        'hud',
        'cues',
        'transport-digits',
        'previous',
        'next',
        'pause',
      ]) {
        expect(_layer(name), findsNothing);
      }
      expect(find.byKey(const ValueKey('start-training')), findsOneWidget);
      expect(fixture.requests.last.paused, isFalse);
      expect(find.byType(TrainerCueCarousel), findsOneWidget);
    },
  );

  testWidgets(
    'natural completion uses the same animation for whole-page exit',
    (tester) async {
      final animation = _controller(tester);
      await _mount(
        tester,
        animation: animation,
        gated: false,
        prepSeconds: 0,
        plan: planOf([timed('a', 1)]),
      );
      await _advance(tester, 1600);
      expect(find.byType(TrainerCompletion), findsOneWidget);
      animation.reverse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      final progress = Curves.easeInCubic.transform(.5);
      expect(_opacity('done').opacity, closeTo(progress, .00001));
      expect(
        _transform('done').transform.storage[13],
        closeTo(12 * (1 - progress), .00001),
      );
      expect(testerWidget<IgnorePointer>(_layer('done')).ignoring, isTrue);
      animation.stop();
    },
  );

  testWidgets(
    'failed exit leaves the completion page fully visible despite chrome zero',
    (tester) async {
      final animation = _controller(tester);
      final save = Completer<void>();
      await _mount(
        tester,
        animation: animation,
        gated: false,
        save: (_) => save.future,
        onExitStarted: () => animation.value = 0,
      );
      await tester.tap(find.byKey(const ValueKey('close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('close-confirm')));
      await tester.pump();
      expect(animation.value, 0);
      expect(find.byType(TrainerCompletion), findsNothing);
      save.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.byType(TrainerCompletion), findsOneWidget);
      expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
      expect(_layer('done'), findsNothing);
      find.byType(TrainerCompletion).evaluate().single.visitAncestorElements((
        element,
      ) {
        if (element.widget case final Opacity opacity) {
          expect(opacity.opacity, 1);
        }
        if (element.widget case final FadeTransition fade) {
          expect(fade.opacity.value, 1);
        }
        return true;
      });
    },
  );
}
