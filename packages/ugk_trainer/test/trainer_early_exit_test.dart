import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/src/ui/trainer_completion.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _ExitFixture {
  final saves = <SessionResult>[];
  final receipts = <SessionResult>[];
  final popped = <SessionResult>[];
  final order = <String>[];
  final media = <TrainerMediaRequest>[];
  int mediaMounts = 0;
  int mediaDisposals = 0;
}

class _MediaProbe extends StatefulWidget {
  const _MediaProbe(this.fixture);
  final _ExitFixture fixture;
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
      const SizedBox(key: ValueKey('probe-media'), height: 50);
}

class _ExitVoiceSource extends VoiceSource {
  const _ExitVoiceSource();

  @override
  Set<String> get languages => const {'en'};
  @override
  String asset(String key, {required String lang}) => key;
  @override
  String? call(VoiceCall call) => 'call.${call.name}';
  @override
  String? drill(String exerciseId, DrillLine line) => null;
  @override
  bool has(String key, {required String lang}) => true;
  @override
  String? line(String key, {required String lang}) => key;
  @override
  List<String> minutesPhrase(int n) => const [];
  @override
  List<String> secondsPhrase(int n) => const [];
  @override
  double seconds(String key, {required String lang}) =>
      key.startsWith('chime.') ? 0 : .08;
}

Future<_ExitFixture> _mount(
  WidgetTester tester, {
  TrainingPlan? plan,
  Future<void> Function(SessionResult)? save,
  Future<void> Function(SessionResult)? receipt,
  RecordingOutput? output,
  TrainerStartMode startMode = TrainerStartMode.training,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final fixture = _ExitFixture();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final result = await Navigator.of(context).push<SessionResult>(
                MaterialPageRoute(
                  builder: (_) => TrainerPlayer(
                    plan: plan ?? planOf([timed('a', 60), timed('b', 60)]),
                    drillOf: (id) => TrainerDrill(
                      id: id,
                      name: 'Move $id',
                      cues: const [
                        'Keep the shoulders relaxed.',
                        'Move slowly.',
                      ],
                    ),
                    strings: TrainerStrings.en(),
                    theme: TrainerTheme.light,
                    startMode: startMode,
                    keepAlive: false,
                    prepSeconds: 2,
                    sessionId: 'early-exit',
                    voice: output == null
                        ? null
                        : TrainerVoice(
                            source: const _ExitVoiceSource(),
                            output: output,
                            settings: const VoiceSettings(language: 'en'),
                          ),
                    mediaBuilder: (_, request) {
                      fixture.media.add(request);
                      return _MediaProbe(fixture);
                    },
                    onFinished: (result) async {
                      fixture.saves.add(result);
                      fixture.order.add('save');
                      await save?.call(result);
                      fixture.order.add('saved');
                    },
                    onCompleted: (result) async {
                      fixture.receipts.add(result);
                      fixture.order.add('receipt');
                      await receipt?.call(result);
                      fixture.order.add('received');
                    },
                  ),
                ),
              );
              if (result != null) fixture.popped.add(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return fixture;
}

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  for (var remaining = milliseconds; remaining > 0;) {
    final step = remaining < 16 ? remaining : 16;
    await tester.pump(Duration(milliseconds: step));
    remaining -= step;
  }
}

Future<({String counter, double progress})> _confirmExit(
  WidgetTester tester, {
  bool systemBack = false,
}) async {
  if (systemBack) {
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
  } else {
    await tester.tap(find.byKey(const ValueKey('close')));
  }
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('close-confirm')), findsOneWidget);
  final frame = (
    counter: tester
        .widget<TrainerCountdownDigits>(find.byType(TrainerCountdownDigits))
        .value,
    progress: tester
        .widget<UgkPlayPauseButton>(find.byType(UgkPlayPauseButton))
        .progress
        .value,
  );
  await tester.tap(find.byKey(const ValueKey('close-confirm')));
  await tester.pump();
  return frame;
}

double _opacity(Finder finder) {
  var opacity = 1.0;
  finder.evaluate().single.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Opacity) opacity *= widget.opacity;
    if (widget is FadeTransition) opacity *= widget.opacity.value;
    return true;
  });
  return opacity;
}

void main() {
  for (final systemBack in [false, true]) {
    testWidgets(
      '${systemBack ? 'system back' : 'close button'} saves once and never mounts completion before pop',
      (tester) async {
        final save = Completer<void>();
        final receipt = Completer<void>();
        final output = RecordingOutput();
        final fixture = await _mount(
          tester,
          save: (_) => save.future,
          receipt: (_) => receipt.future,
          output: output,
        );
        await _advance(tester, 2500);
        var watching = true;
        var frames = 0;
        void checkFrame(Duration _) {
          if (!watching) return;
          frames++;
          expect(
            find.byType(TrainerCompletion, skipOffstage: false),
            findsNothing,
          );
          tester.binding.addPostFrameCallback(checkFrame);
        }

        addTearDown(() => watching = false);
        tester.binding.addPostFrameCallback(checkFrame);
        final mounts = fixture.mediaMounts;
        final disposals = fixture.mediaDisposals;
        final frame = await _confirmExit(tester, systemBack: systemBack);
        expect(fixture.saves, hasLength(1));
        expect(fixture.saves.single.endedEarly, isTrue);
        expect(fixture.receipts, isEmpty);
        expect(fixture.media.last.paused, isTrue);
        final drill = fixture.media.last.drill.id;
        final counter = tester
            .widget<TrainerCountdownDigits>(find.byType(TrainerCountdownDigits))
            .value;
        expect(
          counter,
          frame.counter,
          reason: 'the confirmation must preserve the last displayed counter',
        );
        expect(
          tester
              .widget<UgkPlayPauseButton>(find.byType(UgkPlayPauseButton))
              .progress
              .value,
          frame.progress,
        );
        expect(fixture.mediaMounts, mounts);
        expect(fixture.mediaDisposals, disposals);
        List<String?> cueText() => tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(TrainerCueCarousel),
                matching: find.byType(Text),
              ),
            )
            .map((text) => text.data)
            .toList();
        final cues = cueText();
        final spoken = output.spoken.length;
        final chimes = output.chimes.length;
        expect(output.stops, greaterThan(0));
        await _advance(tester, 5000);
        expect(fixture.popped, isEmpty);
        expect(fixture.media.last.drill.id, drill);
        expect(fixture.media.last.paused, isTrue);
        expect(
          tester
              .widget<TrainerCountdownDigits>(
                find.byType(TrainerCountdownDigits),
              )
              .value,
          counter,
        );
        expect(
          cueText(),
          cues,
          reason: 'saving must not advance the cue carousel',
        );
        expect(
          fixture.mediaMounts,
          mounts,
          reason: 'the paused media keeps its State',
        );
        expect(fixture.mediaDisposals, disposals);
        expect(
          tester
              .widget<UgkPlayPauseButton>(find.byType(UgkPlayPauseButton))
              .progress
              .value,
          frame.progress,
        );
        expect(output.spoken, hasLength(spoken));
        expect(output.chimes, hasLength(chimes));
        expect(output.chimes, isNot(contains('chime.finish')));
        expect(
          output.spoken.expand((clips) => clips),
          isNot(contains('call.finish')),
        );

        // Repeated route back and close taps cannot start a second save.
        for (var i = 0; i < 3; i++) {
          await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
          await tester.tap(
            find.byKey(const ValueKey('close')),
            warnIfMissed: false,
          );
          await tester.pump();
        }
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.saves, hasLength(1));
        save.complete();
        await tester.pump();
        expect(fixture.order, ['save', 'saved', 'receipt']);
        expect(fixture.receipts, hasLength(1));
        expect(fixture.popped, isEmpty);
        await _advance(tester, 320);
        receipt.complete();
        await tester.pump();
        await _advance(tester, 500);
        watching = false;
        expect(frames, greaterThan(30));
        expect(find.text('open'), findsOneWidget);
        expect(fixture.order, ['save', 'saved', 'receipt', 'received']);
        expect(fixture.saves, hasLength(1));
        expect(fixture.receipts, hasLength(1));
        expect(fixture.popped, hasLength(1));
        expect(
          identical(fixture.popped.single, fixture.receipts.single),
          isTrue,
        );
        expect(identical(fixture.popped.single, fixture.saves.single), isTrue);
      },
    );
  }

  testWidgets(
    'save failure fades into completion and retries the same result',
    (tester) async {
      final firstSave = Completer<void>();
      var attempts = 0;
      final fixture = await _mount(
        tester,
        save: (_) => attempts++ == 0 ? firstSave.future : Future<void>.value(),
      );
      await _advance(tester, 2500);
      await _confirmExit(tester);
      await _advance(tester, 600);
      expect(find.byType(TrainerCompletion), findsNothing);
      firstSave.completeError(StateError('disk full'));
      await tester.pump();
      expect(find.byType(TrainerCompletion), findsOneWidget);
      expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(_opacity(find.byType(TrainerCompletion)), closeTo(0, .001));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        _opacity(find.byType(TrainerCompletion)),
        closeTo(Curves.easeOutCubic.transform(.5), .015),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacity(find.byType(TrainerCompletion)), closeTo(1, .001));
      expect(fixture.popped, isEmpty);
      expect(fixture.receipts, isEmpty);
      await tester.ensureVisible(find.byKey(const ValueKey('save-retry')));
      await tester.tap(find.byKey(const ValueKey('save-retry')));
      await tester.pumpAndSettle();
      expect(fixture.saves, hasLength(2));
      expect(identical(fixture.saves[0], fixture.saves[1]), isTrue);
      expect(find.byKey(const ValueKey('save-retry')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.pumpAndSettle();
      expect(fixture.popped.single.sessionId, fixture.saves.first.sessionId);
      expect(fixture.receipts, hasLength(1));
      expect(fixture.saves, hasLength(2));
    },
  );

  testWidgets(
    'receipt failure shows retry without repeating the initial save',
    (tester) async {
      var attempts = 0;
      final fixture = await _mount(
        tester,
        receipt: (_) async {
          if (attempts++ == 0) throw StateError('receipt offline');
        },
      );
      await _advance(tester, 2500);
      await _confirmExit(tester);
      await tester.pumpAndSettle();
      expect(find.byType(TrainerCompletion), findsOneWidget);
      expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
      expect(fixture.popped, isEmpty);
      expect(fixture.saves, hasLength(1));
      expect(fixture.receipts, hasLength(1));
      await tester.ensureVisible(find.byKey(const ValueKey('save-retry')));
      await tester.tap(find.byKey(const ValueKey('save-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('save-retry')), findsNothing);
      expect(fixture.receipts, hasLength(2));
      expect(identical(fixture.receipts[0], fixture.receipts[1]), isTrue);
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.pumpAndSettle();
      expect(fixture.popped, hasLength(1));
      expect(fixture.saves, hasLength(1));
      expect(fixture.receipts, hasLength(2));
    },
  );

  testWidgets('saving within 400ms never creates the progress indicator', (
    tester,
  ) async {
    final save = Completer<void>();
    final fixture = await _mount(tester, save: (_) => save.future);
    await _confirmExit(tester);
    await _advance(tester, 399);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(TrainerCompletion), findsNothing);
    save.complete();
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TrainerCompletion), findsNothing);
    }
    expect(fixture.popped, hasLength(1));
  });

  testWidgets(
    'the 400ms progress deadline also covers a pending completion receipt',
    (tester) async {
      final receipt = Completer<void>();
      final fixture = await _mount(tester, receipt: (_) => receipt.future);
      await _confirmExit(tester);
      expect(fixture.order, ['save', 'saved', 'receipt']);
      await tester.pump(const Duration(milliseconds: 399));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(TrainerCompletion), findsNothing);
      expect(fixture.media.last.paused, isTrue);
      receipt.complete();
      await tester.pumpAndSettle();
      expect(fixture.popped, hasLength(1));
      expect(fixture.saves, hasLength(1));
      expect(fixture.receipts, hasLength(1));
      expect(identical(fixture.popped.single, fixture.receipts.single), isTrue);
    },
  );

  testWidgets(
    'slow save shows a centered 24px spinner after 400ms and fades for 150ms',
    (tester) async {
      final save = Completer<void>();
      final fixture = await _mount(tester, save: (_) => save.future);
      await _confirmExit(tester);
      await tester.pump(const Duration(milliseconds: 399));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      final spinner = find.byType(CircularProgressIndicator);
      expect(spinner, findsOneWidget);
      expect(_opacity(spinner), closeTo(0, .001));
      expect(tester.getSize(spinner), const Size(24, 24));
      expect(tester.widget<CircularProgressIndicator>(spinner).strokeWidth, 2);
      final indicator = tester.widget<CircularProgressIndicator>(spinner);
      expect(
        indicator.color ?? indicator.valueColor?.value,
        TrainerTheme.light.accent,
      );
      expect(
        tester.getCenter(spinner),
        tester.getCenter(find.byType(Scaffold).last),
      );
      await tester.pump(const Duration(milliseconds: 75));
      expect(_opacity(spinner), greaterThan(0));
      expect(_opacity(spinner), lessThan(1));
      await tester.pump(const Duration(milliseconds: 75));
      expect(_opacity(spinner), closeTo(1, .001));
      expect(find.byType(TrainerCompletion), findsNothing);
      expect(fixture.media.last.paused, isTrue);
      save.complete();
      await tester.pumpAndSettle();
      expect(fixture.popped, hasLength(1));
      expect(fixture.saves, hasLength(1));
    },
  );

  testWidgets(
    'natural completion still displays completion until Finish is tapped',
    (tester) async {
      final save = Completer<void>();
      final output = RecordingOutput();
      final fixture = await _mount(
        tester,
        plan: planOf([timed('a', 1)]),
        save: (_) => save.future,
        output: output,
      );
      await _advance(tester, 6000);
      expect(find.byType(TrainerCompletion), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(fixture.popped, isEmpty);
      expect(fixture.saves, hasLength(1));
      expect(fixture.saves.single.endedEarly, isFalse);
      expect(output.chimes, contains('chime.finish'));
      expect(output.spoken.expand((clips) => clips), contains('call.finish'));
      save.complete();
      await tester.pumpAndSettle();
      expect(find.byType(TrainerCompletion), findsOneWidget);
      expect(fixture.popped, isEmpty);
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.pumpAndSettle();
      expect(fixture.popped, hasLength(1));
      expect(fixture.saves, hasLength(1));
      expect(fixture.receipts, hasLength(1));
    },
  );

  testWidgets(
    'preview close still pops directly without saving or completion',
    (tester) async {
      final fixture = await _mount(tester, startMode: TrainerStartMode.preview);
      await tester.tap(find.byKey(const ValueKey('close')));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(find.byType(TrainerCompletion), findsNothing);
      expect(fixture.saves, isEmpty);
      expect(fixture.receipts, isEmpty);
      expect(fixture.popped, isEmpty);
    },
  );
}
