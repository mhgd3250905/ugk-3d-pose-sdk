import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' show PlanItem;
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

/// Speaks only each exercise's name at phase start, so every spoken line
/// identifies the phase that announced it.
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

/// [_NamedScript] plus a standalone `chime.tick` 0.1 s into every phase.
class _NamedTickScript extends _NamedScript {
  _NamedTickScript(super.source);

  @override
  List<VoiceCue> cues(
    SessionPhase phase, {
    double planSeconds = 0,
    bool bySkip = false,
  }) {
    return [
      ...super.cues(phase, planSeconds: planSeconds, bySkip: bySkip),
      if (phase.exerciseId != null)
        const VoiceCue(.1, ['chime.tick'], CuePriority.count),
    ];
  }
}

const _ids = ['h-squat', 'w-dead-bug', 'h-couch-stretch', 's-figure4'];

Future<RecordingOutput> _pumpPlayer(
  WidgetTester tester, {
  List<PlanItem>? items,
  Map<String, Rhythm> rhythms = const {},
  SessionScript Function(VoiceSource source, String lang)? scriptBuilder =
      _namedScript,
  bool showSoundToggle = false,
}) async {
  final output = RecordingOutput();
  await tester.pumpWidget(
    MaterialApp(
      home: TrainerPlayer(
        plan: planOf(items ?? [for (final id in _ids) timed(id, 30, rest: 0)]),
        drillOf: (id) => TrainerDrill(id: id, name: id),
        strings: TrainerStrings.en(),
        prepSeconds: 0,
        transitionSeconds: 0,
        keepAlive: false,
        rhythms: rhythms,
        showSoundToggle: showSoundToggle,
        voice: TrainerVoice(
          source: smartSource(),
          output: output,
          scriptBuilder: scriptBuilder,
        ),
        mediaBuilder: (_, _) => const SizedBox.expand(),
        onFinished: (_) async {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  output.spoken.clear();
  output.chimes.clear();
  return output;
}

SessionScript _namedScript(VoiceSource source, String _) =>
    _NamedScript(source);

/// Which exercises were announced, in order, one entry per spoken line.
List<String> _announced(RecordingOutput output) => [
  for (final clips in output.spoken)
    for (final id in _ids)
      if (clips.join(' ').contains(id)) id,
];

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

void main() {
  testWidgets('a single manual switch announces immediately, once', (
    tester,
  ) async {
    final output = await _pumpPlayer(tester);
    await _tap(tester, 'skip');
    expect(_announced(output), ['w-dead-bug']);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _announced(output),
      ['w-dead-bug'],
      reason: 'the quiet window must not replay the leading announcement',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a rapid burst announces the first switch now and only the final stop',
    (tester) async {
      final output = await _pumpPlayer(tester);
      await _tap(tester, 'skip'); // → w-dead-bug, spoken at once
      expect(_announced(output), ['w-dead-bug']);
      await tester.pump(const Duration(milliseconds: 100));
      await _tap(tester, 'skip'); // → h-couch-stretch, merged
      await tester.pump(const Duration(milliseconds: 100));
      await _tap(tester, 'skip'); // → s-figure4, window restarts here
      // 200 ms after the second tap, but the window follows the last tap.
      await tester.pump(const Duration(milliseconds: 148));
      expect(_announced(output), ['w-dead-bug']);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(_announced(output), ['w-dead-bug', 's-figure4']);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_announced(output), ['w-dead-bug', 's-figure4']);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('29'),
        findsWidgets,
        reason: 'navigation did not stop the engine clock',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'returning to the already announced exercise inside the window stays quiet',
    (tester) async {
      final output = await _pumpPlayer(tester);
      await _tap(tester, 'skip'); // → w-dead-bug, spoken at once
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'skip'); // → h-couch-stretch, merged
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'prev'); // back to w-dead-bug
      await tester.pump(const Duration(milliseconds: 300));
      expect(_announced(output), ['w-dead-bug']);
      // Once the window has closed the next switch leads again.
      await _tap(tester, 'skip');
      expect(_announced(output), ['w-dead-bug', 'h-couch-stretch']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('disposing mid-window cancels the pending announcement', (
    tester,
  ) async {
    final output = await _pumpPlayer(tester);
    await _tap(tester, 'skip');
    await tester.pump(const Duration(milliseconds: 50));
    await _tap(tester, 'skip'); // window still pending
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    expect(_announced(output), ['w-dead-bug']);
    // flutter_test also fails the test if the window Timer outlived dispose.
  });

  testWidgets(
    'returning to the announced action keeps its first count (default script)',
    (tester) async {
      final output = await _pumpPlayer(
        tester,
        items: [for (final id in _ids) reps(id, 10, rest: 0)],
        rhythms: {
          'w-dead-bug': const Rhythm(
            kind: ActionKind.repUpdown,
            lead: .1,
            phases: [KitPhase('go', 3, [])],
            source: RhythmSource.catalog,
          ),
        },
        scriptBuilder: null,
      );
      final one = smartSource().asset('n.1', lang: 'zh');
      bool counted() => output.spoken.any((clips) => clips.contains(one));
      await _tap(tester, 'skip'); // → w-dead-bug, leading announcement
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'skip'); // → h-couch-stretch, merged
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'prev'); // back to w-dead-bug
      expect(counted(), isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(
        counted(),
        isTrue,
        reason: 'the first count was never spoken and must not be dropped',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('returning to the announced action keeps a pending chime', (
    tester,
  ) async {
    final output = await _pumpPlayer(
      tester,
      scriptBuilder: (source, _) => _NamedTickScript(source),
    );
    final tick = smartSource().asset('chime.tick', lang: 'zh');
    await _tap(tester, 'skip'); // → w-dead-bug, leading announcement
    await tester.pump(const Duration(milliseconds: 50));
    await _tap(tester, 'skip'); // → h-couch-stretch, merged
    await tester.pump(const Duration(milliseconds: 50));
    await _tap(tester, 'prev'); // back to w-dead-bug
    expect(output.chimes, isNot(contains(tick)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(_announced(output), ['w-dead-bug'], reason: 'name stays deduped');
    expect(output.chimes, contains(tick));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a switch made while muted is not treated as announced', (
    tester,
  ) async {
    final output = await _pumpPlayer(tester, showSoundToggle: true);
    await _tap(tester, 'sound-toggle'); // sound off
    await _tap(tester, 'skip'); // → w-dead-bug, silent
    await tester.pump(const Duration(milliseconds: 20));
    await _tap(tester, 'sound-toggle'); // sound on
    await _tap(tester, 'skip'); // → h-couch-stretch, merged
    await _tap(tester, 'prev'); // back to w-dead-bug
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(_announced(output), ['w-dead-bug']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
