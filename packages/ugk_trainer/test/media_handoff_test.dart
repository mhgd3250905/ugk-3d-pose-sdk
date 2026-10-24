import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/media/media_view.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _NamedScript extends SessionScript {
  _NamedScript(VoiceSource source) : super(source: source);

  @override
  List<VoiceCue> cues(
    SessionPhase phase, {
    double planSeconds = 0,
    bool bySkip = false,
  }) {
    return [
      if (phase.exerciseId case final id?)
        VoiceCue(0, [?source.drill(id, DrillLine.name)], CuePriority.call),
    ];
  }
}

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';

DrillMedia _media(String id, {String poster = ''}) => DrillMedia(
  id: id,
  videoAsset: '$id-dark.mp4',
  lightVideoAsset: '$id-light.mp4',
  posterAsset: poster,
  lightPosterAsset: poster.isEmpty ? '' : 'light-$poster',
  duration: 30,
);

Widget _view(
  DrillMedia media, {
  Brightness brightness = Brightness.dark,
  bool handoff = true,
  bool paused = false,
  bool mirrored = false,
}) {
  Widget child = Center(
    child: SizedBox.square(
      dimension: 200,
      child: DrillMediaView(media: media, paused: paused, mirrored: mirrored),
    ),
  );
  if (handoff) child = DrillMediaHandoff(child: child);
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    themeAnimationDuration: Duration.zero,
    home: child,
  );
}

DrillMediaPlatformView _surface(WidgetTester tester) =>
    tester.widget<DrillMediaPlatformView>(find.byType(DrillMediaPlatformView));

void _decoded(DrillMediaController controller) {
  // Desktop widget tests have no native decoder. Drive the real host protocol.
  controller.failed = false;
  controller.receive({'source': 'drill-media', 'type': 'first-frame'});
}

void main() {
  test(
    'capture uses a matching request and ignores late replies after dispose',
    () async {
      final controller = DrillMediaController();
      _decoded(controller);
      final commands = <Map<String, Object?>>[];
      controller.attach((command) {
        commands.add(command);
        if (command['type'] == 'capture-and-pause') {
          controller.receive({
            'source': 'drill-media',
            'type': 'frame',
            'captureId': command['captureId'],
            'frame': _png,
          });
        }
      });
      expect(await controller.captureFrameAndPause(), base64Decode(_png));
      expect(commands.single['type'], 'capture-and-pause');
      expect(controller.wantsPlay, isFalse);
      controller.dispose();
      controller.receive({'source': 'drill-media', 'type': 'ready'});
      expect(controller.ready, isFalse);
    },
  );

  test(
    'missing or mismatched snapshot reply has a bounded retirement',
    () async {
      final controller = DrillMediaController();
      _decoded(controller);
      controller.attach((command) {
        controller.receive({
          'source': 'drill-media',
          'type': 'frame',
          'captureId': -1,
          'frame': _png,
        });
      });
      expect(await controller.captureFrameAndPause(), isNull);
      expect(controller.frameBytes, isNull);
      controller.dispose();
      controller.dispose();
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name}: rapid changes load only the last target and reveal after a real first frame',
      (tester) async {
        await tester.pumpWidget(
          _view(_media('a', poster: 'a.png'), brightness: brightness),
        );
        expect(find.byType(DrillMediaPlatformView), findsNothing);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpWidget(
          _view(_media('b', poster: 'b.png'), brightness: brightness),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpWidget(
          _view(_media('c', poster: 'c.png'), brightness: brightness),
        );
        await tester.pump(const Duration(milliseconds: 149));
        expect(find.byType(DrillMediaPlatformView), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        final surface = _surface(tester);
        expect(surface.media.id, 'c');
        expect(surface.videoAsset, 'c-${brightness.name}.mp4');
        final reveal = find.byKey(
          ValueKey(('drill-video-reveal', surface.controller)),
        );
        expect(tester.widget<AnimatedOpacity>(reveal).opacity, 1 / 255);
        final paintedOpacity = tester
            .widget<FadeTransition>(
              find.descendant(
                of: reveal,
                matching: find.byType(FadeTransition),
              ),
            )
            .opacity
            .value;
        expect(
          (paintedOpacity * 255).round(),
          greaterThan(0),
          reason: 'first-frame waiting must still composite the platform view',
        );
        expect(
          find.byKey(
            ValueKey(
              'drill-poster-${brightness == Brightness.light ? 'light-' : ''}c.png',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(DrillMediaView),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );
        _decoded(surface.controller);
        await tester.pump();
        expect(tester.widget<AnimatedOpacity>(reveal).opacity, 1);
        expect(
          tester.widget<AnimatedOpacity>(reveal).duration,
          const Duration(milliseconds: 120),
        );
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '${brightness.name}: missing target poster uses the captured current frame and releases the old player',
      (tester) async {
        await tester.pumpWidget(_view(_media('a'), brightness: brightness));
        await tester.pump(const Duration(milliseconds: 150));
        final owner = tester.state(find.byType(DrillMediaView));
        final old = _surface(tester).controller;
        _decoded(old);
        final commands = <Map<String, Object?>>[];
        old.attach((command) {
          commands.add(command);
          if (command['type'] == 'capture-and-pause') {
            old.receive({
              'source': 'drill-media',
              'type': 'frame',
              'captureId': command['captureId'],
              'frame': _png,
            });
          }
        });
        await tester.pumpWidget(_view(_media('b'), brightness: brightness));
        expect(tester.state(find.byType(DrillMediaView)), same(owner));
        expect(commands.first['type'], 'capture-and-pause');
        await tester.pump(const Duration(milliseconds: 45));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('drill-static-frame')),
          findsOneWidget,
        );
        expect(find.byType(DrillMediaPlatformView), findsNothing);
        expect(commands.last['type'], 'pause');
        old.receive({'source': 'drill-media', 'type': 'error'});
        expect(
          old.failed,
          isFalse,
          reason: 'retired controller rejects late events',
        );
        await tester.pump(const Duration(milliseconds: 105));
        expect(_surface(tester).media.id, 'b');
        expect(find.byType(DrillMediaPlatformView), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('dark snapshot is never reused as a light-theme frame', (
    tester,
  ) async {
    await tester.pumpWidget(_view(_media('a')));
    await tester.pump(const Duration(milliseconds: 150));
    final old = _surface(tester).controller;
    _decoded(old);
    old.attach((command) {
      if (command['type'] == 'capture-and-pause') {
        old.receive({
          'source': 'drill-media',
          'type': 'frame',
          'captureId': command['captureId'],
          'frame': _png,
        });
      }
    });
    await tester.pumpWidget(_view(_media('b'), brightness: Brightness.light));
    await tester.pump(const Duration(milliseconds: 45));
    await tester.pump();
    expect(find.byKey(const ValueKey('drill-static-frame')), findsNothing);
    await tester.pump(const Duration(milliseconds: 105));
    expect(_surface(tester).videoAsset, 'b-light.mp4');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'mirror-only updates flip the current video once and preserve its captured orientation',
    (tester) async {
      await tester.pumpWidget(_view(_media('a')));
      await tester.pump(const Duration(milliseconds: 150));
      final old = _surface(tester).controller;
      _decoded(old);
      await tester.pumpWidget(_view(_media('a'), mirrored: true));
      expect(_surface(tester).controller, same(old));
      double orientation(Finder child) => tester
          .widgetList<Transform>(
            find.ancestor(of: child, matching: find.byType(Transform)),
          )
          .fold(
            1.0,
            (value, transform) => value * transform.transform.entry(0, 0),
          );
      expect(orientation(find.byType(DrillMediaPlatformView)), -1);
      old.attach((command) {
        if (command['type'] == 'capture-and-pause') {
          old.receive({
            'source': 'drill-media',
            'type': 'frame',
            'captureId': command['captureId'],
            'frame': _png,
          });
        }
      });
      await tester.pumpWidget(_view(_media('b')));
      await tester.pump(const Duration(milliseconds: 45));
      await tester.pump();
      expect(orientation(find.byKey(const ValueKey('drill-static-frame'))), -1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a stalled native capture releases the retired surface within its timeout',
    (tester) async {
      await tester.pumpWidget(_view(_media('a')));
      await tester.pump(const Duration(milliseconds: 150));
      final old = _surface(tester).controller;
      _decoded(old);
      final commands = <Map<String, Object?>>[];
      old.attach(commands.add);
      await tester.pumpWidget(_view(_media('b')));
      expect(commands.single['type'], 'capture-and-pause');
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(find.byType(DrillMediaPlatformView), findsNothing);
      expect(commands.last['type'], 'pause');
      await tester.pump(const Duration(milliseconds: 100));
      expect(_surface(tester).media.id, 'b');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standalone manual preview stays immediate and pause keeps its owner',
    (tester) async {
      await tester.pumpWidget(_view(_media('a'), handoff: false));
      final owner = _surface(tester).controller;
      _decoded(owner);
      await tester.pumpWidget(_view(_media('a'), handoff: false, paused: true));
      expect(_surface(tester).controller, same(owner));
      expect(owner.wantsPlay, isFalse);
      await tester.pumpWidget(_view(_media('a'), handoff: false));
      expect(_surface(tester).controller, same(owner));
      expect(owner.wantsPlay, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final custom in [false, true]) {
    testWidgets(
      '${custom ? 'custom' : 'default'} training builder keeps one State across rapid skips',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: TrainerPlayer(
              plan: planOf([timed('a', 30), timed('b', 30), timed('c', 30)]),
              drillOf: (id) =>
                  TrainerDrill(id: id, name: id, media: _media(id)),
              strings: TrainerStrings.en(),
              prepSeconds: 0,
              transitionSeconds: 0,
              keepAlive: false,
              mediaBuilder: custom
                  ? (_, req) => DrillMediaView(
                      key: const ValueKey('custom-media'),
                      media: req.drill.media!,
                      paused: req.paused,
                    )
                  : null,
              onFinished: (_) async {},
            ),
          ),
        );
        await tester.pump();
        final owner = tester.state(find.byType(DrillMediaView));
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byKey(const ValueKey('skip')));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(DrillMediaView), findsOneWidget);
          expect(tester.state(find.byType(DrillMediaView)), same(owner));
          expect(find.byType(DrillMediaPlatformView), findsNothing);
        }
        await tester.pump(const Duration(milliseconds: 150));
        expect(_surface(tester).media.id, 'c');
        expect(find.byType(DrillMediaPlatformView), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'rapid navigation speaks only the final target and does not wait the training clock',
    (tester) async {
      final output = RecordingOutput();
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: planOf([
              timed('h-squat', 30, rest: 0),
              timed('w-dead-bug', 30, rest: 0),
              timed('h-couch-stretch', 30, rest: 0),
            ]),
            drillOf: (id) => TrainerDrill(id: id, name: id),
            strings: TrainerStrings.en(),
            prepSeconds: 0,
            transitionSeconds: 0,
            keepAlive: false,
            voice: TrainerVoice(
              source: smartSource(),
              output: output,
              scriptBuilder: (source, _) => _NamedScript(source),
            ),
            mediaBuilder: (_, _) => const SizedBox.expand(),
            onFinished: (_) async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      output.spoken.clear();
      output.chimes.clear();
      await tester.tap(find.byKey(const ValueKey('skip')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(output.spoken, isEmpty);
      expect(output.chimes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('skip')));
      await tester.pump(const Duration(milliseconds: 149));
      expect(output.spoken, isEmpty);
      expect(output.chimes, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(output.spoken, isNotEmpty);
      expect(
        output.spoken.expand((clips) => clips).join(' '),
        contains('h-couch-stretch'),
      );
      expect(
        output.spoken.expand((clips) => clips).join(' '),
        isNot(contains('w-dead-bug')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('29'),
        findsWidgets,
        reason: 'navigation did not stop the engine clock',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
