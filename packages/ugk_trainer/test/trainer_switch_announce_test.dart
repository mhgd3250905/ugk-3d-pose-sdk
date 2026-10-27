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

/// [_NamedScript] plus each exercise's first coaching line, which waits
/// behind the name as a pending coach cue.
class _NamedCoachScript extends SessionScript {
  _NamedCoachScript(VoiceSource source) : super(source: source);

  @override
  List<VoiceCue> cues(
    SessionPhase phase, {
    double planSeconds = 0,
    bool bySkip = false,
  }) {
    final id = phase.exerciseId;
    if (id == null) return [];
    return [
      VoiceCue(0, [?source.drill(id, DrillLine.name)], CuePriority.call),
      VoiceCue(0, [?source.drill(id, DrillLine.cue1)], CuePriority.coach),
    ];
  }
}

const _ids = ['h-squat', 'w-dead-bug', 'h-couch-stretch', 's-figure4'];

/// Records each line asked for in [spoken] but cannot confirm a start, so
/// nothing it plays is ever treated as announced.
class _UnconfirmedOutput implements VoiceOutput {
  final spoken = <List<String>>[];
  @override
  Future<void> begin() async {}
  @override
  Future<void> end() async {}
  @override
  Future<void> speak(List<String> assets) async => spoken.add([...assets]);
  @override
  Future<void> stopSpeech() async {}
  @override
  Future<void> chime(String asset) async {}
  @override
  set volume(double v) {}
}

/// What [output] really played (a [SerialVoiceProbe] only counts lines that
/// started).
List<List<String>> _heard(VoiceOutput output) => switch (output) {
  SerialVoiceProbe() => output.started,
  RecordingOutput() => output.spoken,
  _UnconfirmedOutput() => output.spoken,
  _ => throw ArgumentError(output),
};

List<String> _chimes(VoiceOutput output) => switch (output) {
  SerialVoiceProbe() => output.chimes,
  RecordingOutput() => output.chimes,
  _ => throw ArgumentError(output),
};

void _clear(VoiceOutput output) {
  switch (output) {
    case SerialVoiceProbe():
      output.started.clear();
      output.submitted.clear();
      output.chimes.clear();
    case RecordingOutput():
      output.spoken.clear();
      output.chimes.clear();
    case _UnconfirmedOutput():
      output.spoken.clear();
  }
}

Future<void> _pumpPlayer(
  WidgetTester tester,
  VoiceOutput output, {
  List<PlanItem>? items,
  Map<String, Rhythm> rhythms = const {},
  SessionScript Function(VoiceSource source, String lang)? scriptBuilder =
      _namedScript,
  bool showSoundToggle = false,
}) async {
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
  _clear(output);
}

SessionScript _namedScript(VoiceSource source, String _) =>
    _NamedScript(source);

/// Which exercises were announced, in order, one entry per line heard.
List<String> _announced(VoiceOutput output) => [
  for (final clips in _heard(output))
    for (final id in _ids)
      if (clips.join(' ').contains(id)) id,
];

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

/// The review-3 rhythm: a catalog rep rhythm whose first count (0.1 s in)
/// is queued behind the start call (`p.go`, 673 ms) by tailGrace.
const _catalogRhythm = Rhythm(
  kind: ActionKind.repUpdown,
  lead: .1,
  phases: [KitPhase('go', 3, [])],
  source: RhythmSource.catalog,
);

final _outputs = <String, VoiceOutput Function()>{
  'recording output': RecordingOutput.new,
  'serial probe': () => SerialVoiceProbe.forSource(smartSource()),
};

void main() {
  for (final MapEntry(key: label, value: make) in _outputs.entries) {
    group(label, () => _regressions(make));
  }

  testWidgets(
    'serial probe: a tail-queued first count cancelled by the next switch '
    'still plays on return, and the start call starts once (review 3)',
    (tester) async {
      final source = smartSource();
      final output = SerialVoiceProbe.forSource(source);
      await _pumpPlayer(
        tester,
        output,
        items: [for (final id in _ids) reps(id, 10, rest: 0)],
        rhythms: {'w-dead-bug': _catalogRhythm},
        scriptBuilder: null,
      );
      final go = source.asset('p.go', lang: 'zh');
      final one = source.asset('n.1', lang: 'zh');
      int starts(String asset) =>
          output.started.where((clips) => clips.contains(asset)).length;
      await _tap(tester, 'skip'); // A → B: start call plays at once
      await tester.pump(const Duration(milliseconds: 120));
      expect(starts(go), 1);
      expect(
        output.submitted.any((clips) => clips.contains(one)),
        isTrue,
        reason: 'the first count was handed to the output, behind p.go',
      );
      expect(starts(one), 0, reason: 'but it has not started yet');
      await _tap(tester, 'skip'); // B → C: cancels the waiting count
      await tester.pump(const Duration(milliseconds: 20));
      await _tap(tester, 'prev'); // C → B
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        starts(one),
        greaterThanOrEqualTo(1),
        reason: "B's first count must really start after the return",
      );
      expect(starts(go), 1, reason: "B's start call is not said twice");
      await _close(tester);
    },
  );

  testWidgets(
    'an output that cannot confirm a start never makes the return silent',
    (tester) async {
      final output = _UnconfirmedOutput();
      await _pumpPlayer(tester, output);
      await _tap(tester, 'skip'); // → w-dead-bug, asked for at once
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'skip'); // → h-couch-stretch, merged
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'prev'); // back to w-dead-bug
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(
        _announced(output),
        ['w-dead-bug', 'w-dead-bug'],
        reason: 'unconfirmed means not played: the name is said again',
      );
      await _close(tester);
    },
  );
}

void _regressions(VoiceOutput Function() make) {
  testWidgets('a single manual switch announces immediately, once', (
    tester,
  ) async {
    final output = make();
    await _pumpPlayer(tester, output);
    await _tap(tester, 'skip');
    expect(_announced(output), ['w-dead-bug']);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _announced(output),
      ['w-dead-bug'],
      reason: 'the quiet window must not replay the leading announcement',
    );
    await _close(tester);
  });

  testWidgets(
    'a rapid burst announces the first switch now and only the final stop',
    (tester) async {
      final output = make();
      await _pumpPlayer(tester, output);
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
      await _close(tester);
    },
  );

  testWidgets(
    'returning to the already announced exercise inside the window stays quiet',
    (tester) async {
      final output = make();
      await _pumpPlayer(tester, output);
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
      await _close(tester);
    },
  );

  testWidgets('disposing mid-window cancels the pending announcement', (
    tester,
  ) async {
    final output = make();
    await _pumpPlayer(tester, output);
    await _tap(tester, 'skip');
    await tester.pump(const Duration(milliseconds: 50));
    await _tap(tester, 'skip'); // window still pending
    await _close(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_announced(output), ['w-dead-bug']);
    // flutter_test also fails the test if the window Timer outlived dispose.
  });

  testWidgets(
    'returning to the announced action keeps its first count (default script)',
    (tester) async {
      final output = make();
      await _pumpPlayer(
        tester,
        output,
        items: [for (final id in _ids) reps(id, 10, rest: 0)],
        rhythms: {'w-dead-bug': _catalogRhythm},
        scriptBuilder: null,
      );
      final one = smartSource().asset('n.1', lang: 'zh');
      bool counted() => _heard(output).any((clips) => clips.contains(one));
      await _tap(tester, 'skip'); // → w-dead-bug, leading announcement
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'skip'); // → h-couch-stretch, merged
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'prev'); // back to w-dead-bug
      expect(counted(), isFalse);
      // A serial output still finishes the call it starts on return first.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        counted(),
        isTrue,
        reason: 'the first count was never spoken and must not be dropped',
      );
      await _close(tester);
    },
  );

  testWidgets('returning to the announced action keeps a pending chime', (
    tester,
  ) async {
    final output = make();
    await _pumpPlayer(
      tester,
      output,
      scriptBuilder: (source, _) => _NamedTickScript(source),
    );
    final tick = smartSource().asset('chime.tick', lang: 'zh');
    await _tap(tester, 'skip'); // → w-dead-bug, leading announcement
    await tester.pump(const Duration(milliseconds: 50));
    await _tap(tester, 'skip'); // → h-couch-stretch, merged
    await tester.pump(const Duration(milliseconds: 50));
    await _tap(tester, 'prev'); // back to w-dead-bug
    expect(_chimes(output), isNot(contains(tick)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(_announced(output), ['w-dead-bug'], reason: 'name stays deduped');
    expect(_chimes(output), contains(tick));
    await _close(tester);
  });

  testWidgets('a switch made while muted is not treated as announced', (
    tester,
  ) async {
    final output = make();
    await _pumpPlayer(tester, output, showSoundToggle: true);
    await _tap(tester, 'sound-toggle'); // sound off
    await _tap(tester, 'skip'); // → w-dead-bug, silent
    await tester.pump(const Duration(milliseconds: 20));
    await _tap(tester, 'sound-toggle'); // sound on
    await _tap(tester, 'skip'); // → h-couch-stretch, merged
    await _tap(tester, 'prev'); // back to w-dead-bug
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(_announced(output), ['w-dead-bug']);
    await _close(tester);
  });

  testWidgets(
    'a coaching line still waiting when the burst moved on is not lost',
    (tester) async {
      final output = make();
      await _pumpPlayer(
        tester,
        output,
        scriptBuilder: (source, _) => _NamedCoachScript(source),
      );
      final cue1 = smartSource().drill('w-dead-bug', DrillLine.cue1);
      final cue1Asset = smartSource().asset(cue1!, lang: 'zh');
      await _tap(tester, 'skip'); // → w-dead-bug: name plays, cue1 waits
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'skip'); // → h-couch-stretch, cancels waiting cue1
      await tester.pump(const Duration(milliseconds: 50));
      await _tap(tester, 'prev'); // back to w-dead-bug
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        _heard(output).any((clips) => clips.contains(cue1Asset)),
        isTrue,
        reason: 'cue1 never reached the output and must not be deduplicated',
      );
      final name = smartSource().asset(
        smartSource().drill('w-dead-bug', DrillLine.name)!,
        lang: 'zh',
      );
      expect(
        _heard(output).where((clips) => clips.contains(name)).length,
        1,
        reason: 'the name the leading switch spoke stays deduplicated',
      );
      await _close(tester);
    },
  );
}
