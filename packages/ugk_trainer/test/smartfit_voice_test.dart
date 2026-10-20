// Ported from SmartFit@e8981ee test/voice_session_test.dart (group
// 'drill-pack timelines'), on the drill-pack fixtures through
// DrillPackVoiceSource. The template generator is SmartFit's, so the
// "every template × level" sweep runs a fixed plan set here.
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  final voices = smartSource();
  final script = SessionScript(source: voices);
  final rhythms = smartRhythms();

  /// Lines of one phase never overlap, flexible lines end before the
  /// countdown (with margin), and nothing runs past the phase.
  void checkPhase(String where, SessionPhase phase, List<VoiceCue> cues) {
    final spans = [
      for (final c in cues) (c, c.at, c.at + voices.total(c.clips, lang: 'zh')),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    for (var i = 1; i < spans.length; i++) {
      expect(
        spans[i].$2,
        greaterThanOrEqualTo(spans[i - 1].$3 - 1e-9),
        reason: '$where: ${spans[i - 1].$1} overlaps ${spans[i].$1}',
      );
    }
    if (phase.kind == PhaseKind.done) return;
    final countdown = cues
        .where(
          (c) =>
              c.priority == CuePriority.count && c.clips.contains('chime.tick'),
        )
        .map((c) => c.at)
        .fold<double?>(null, (m, t) => m == null || t < m ? t : m);
    for (final (c, _, end) in spans) {
      expect(
        end,
        lessThanOrEqualTo(phase.seconds + 1e-9),
        reason: '$where: $c runs past the phase',
      );
      if (countdown != null &&
          !c.clips.contains('chime.tick') &&
          (c.priority == CuePriority.coach || c.priority == CuePriority.info)) {
        expect(
          end,
          lessThanOrEqualTo(countdown - countdownMargin + 1e-9),
          reason: '$where: $c would be cut by the countdown',
        );
      }
    }
  }

  test('plans with sets, sides and a circuit: no overlap, no cut, pack lines '
      'used, every clip exists', () {
    final plans = [
      smartSim().plan,
      planOf([
        reps('w-dead-bug', 12, sets: 3, rest: 20),
        timed('h-couch-stretch', 45, perSide: true, sets: 2),
        reps('h-squat', 15, sets: 2),
      ]),
    ];
    final used = <String>{};
    for (final (n, plan) in plans.indexed) {
      final b = SessionBuilder(
        rhythms: rhythms,
        switchSecondsFor: script.switchSecondsFor,
      );
      final phases = b.phases(plan);
      for (var i = 0; i < phases.length; i++) {
        for (final bySkip in [false, true]) {
          final cues = script.cues(
            phases[i],
            planSeconds: b.planSeconds(plan),
            bySkip: bySkip,
          );
          checkPhase('plan $n #$i ${phases[i]}', phases[i], cues);
          for (final c in cues) {
            for (final k in c.clips) {
              expect(voices.has(k, lang: 'zh'), isTrue, reason: k);
              if (k.contains('/')) used.add(k.substring(k.indexOf('/') + 1));
            }
          }
        }
      }
    }
    expect(
      used,
      containsAll(['intro', 'cue1', 'cue2', 'rest', 'finish', 'side_switch']),
    );
  });

  test('round rest: 这一轮完成, 第 N 轮; set rest: 第 N 组 / 最后一组', () {
    final b = SessionBuilder(rhythms: rhythms);
    final phases = b.phases(smartSim().plan);
    final rr = phases.firstWhere((p) => p.kind == PhaseKind.roundRest);
    final said = [
      for (final c in script.cues(rr, planSeconds: 600)) ...c.clips,
    ];
    expect(said, containsAll(['p.round_done', 'p.di', 'u.rounds']));
    final setRest = phases.firstWhere(
      (p) => p.kind == PhaseKind.rest && p.nextExerciseId == null,
    );
    expect([
      for (final c in script.cues(setRest, planSeconds: 600)) ...c.clips,
    ], contains('p.last_set'));
  });

  test('second side of a timed move speaks its side_switch line', () {
    final item = timed('h-couch-stretch', 30, perSide: true, rest: 10);
    List<String> said(Side side) => [
      for (final c in script.cues(
        SessionPhase(
          kind: PhaseKind.work,
          seconds: 30,
          exerciseId: item.exerciseId,
          item: item,
          set: 1,
          sets: 1,
          side: side,
          rhythm: Rhythm.timedHold,
        ),
        planSeconds: 300,
      ))
        ...c.clips,
    ];
    expect(said(Side.right), contains('h-couch-stretch/cue1'));
    expect(said(Side.right), isNot(contains('h-couch-stretch/side_switch')));
    expect(said(Side.right).take(2), ['chime.start', 'p.go_right']);
    expect(said(Side.left), contains('h-couch-stretch/side_switch'));
    expect(said(Side.left).first, 'chime.start');
  });

  test('the rest after a move names it as finished, unless it was skipped', () {
    final next = timed('w-dead-bug', 30, rest: 10);
    final rest = SessionPhase(
      kind: PhaseKind.rest,
      seconds: 15,
      exerciseId: 'w-dead-bug',
      item: next,
      nextExerciseId: 'w-dead-bug',
      nextItem: next,
      doneExerciseId: 'h-squat',
      sets: 1,
      set: 1,
    );
    List<String> said({required bool bySkip}) => [
      for (final c in script.cues(rest, planSeconds: 300, bySkip: bySkip))
        ...c.clips,
    ];
    expect(said(bySkip: false), contains('h-squat/finish'));
    expect(said(bySkip: false), contains('p.next'));
    expect(said(bySkip: true), isNot(contains('h-squat/finish')));
    expect(said(bySkip: true), contains('p.rest'));
  });

  test('repSeconds reps are counted on the beat end, like SmartFit', () {
    final w = SessionBuilder(
      rhythms: rhythms,
    ).phases(planOf([reps('h-squat', 10)])).firstWhere((p) => p.isWork);
    expect(w.seconds, 40);
    final counts = script
        .cues(w, planSeconds: 60)
        .where((c) => c.priority == CuePriority.count)
        .toList();
    expect(counts.first.clips, ['n.1']);
    expect(counts.first.at, closeTo(4 - .45, 1e-9));
    expect(counts.length, 10);
    expect(w.repAt(0), 1);
    expect(w.repAt(39.9), 10);
  });

  test('the side-switch gap stays 5 s for SmartFit lines', () {
    final b = SessionBuilder(
      rhythms: rhythms,
      switchSecondsFor: script.switchSecondsFor,
    );
    final sw = b
        .phases(planOf([timed('s-figure4', 30, perSide: true)]))
        .firstWhere((p) => p.kind == PhaseKind.switchSide);
    expect(sw.seconds, 5);
  });

  test('a whole SmartFit session through the queue: never two voices', () {
    final sim = smartSim()..run();
    final lines = sim.lines;
    for (var i = 1; i < lines.length; i++) {
      expect(lines[i].start, greaterThanOrEqualTo(lines[i - 1].end - 1e-9));
    }
    expect(sim.engine.done, isTrue);
    expect(sim.engine.completedExercises, 7);
  });

  test('DrillPackVoiceSource: keys, assets and units', () {
    expect(voices.supports('zh'), isTrue);
    expect(voices.supports('en'), isFalse);
    expect(
      voices.asset('h-squat/cue1', lang: 'zh'),
      'assets/packs/h-squat/voice/zh/cue1.m4a',
    );
    expect(
      voices.asset('chime.tick', lang: 'zh'),
      'assets/packs/_common/chime/tick.m4a',
    );
    expect(voices.secondsPhrase(30), ['n.30', 'u.sec']);
    expect(voices.secondsPhrase(90), isEmpty);
    expect(script.dose(reps('h-squat', 12, sets: 3, perSide: true)), [
      'n.3',
      'u.sets',
      'p.per_side',
      'n.12',
      'u.reps',
    ]);
  });

  test('ManifestVoiceSource: HipLab keys', () {
    final hip = hipSource();
    expect(hip.supports('zh') && hip.supports('en'), isTrue);
    expect(hip.call(VoiceCall.tenLeft), 'p.last10');
    expect(hip.call(VoiceCall.perSide), 'p.each_side');
    expect(hip.drill('h-squat', DrillLine.cue1), 'point.h-squat');
    expect(hip.asset('n.3', lang: 'en'), 'assets/voice/en/n.3.m4a');
    expect(hip.asset('chime.end', lang: 'en'), 'assets/voice/chime/end.m4a');
    expect(hip.kitVoice('h-squat')?.go, 'p.go');
  });
}
