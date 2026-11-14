import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

class _PackVoice extends ManifestVoiceSource {
  _PackVoice(this.guides, {this.switchSeconds = const {}})
    : super(const {}, const {}, const {}, const {});

  final Map<String, Map<String, Object?>> guides;
  final Map<String, int> switchSeconds;

  @override
  PoseHubVoiceGuide? voiceGuide(String exerciseId) =>
      PoseHubVoiceGuide.tryParse(guides[exerciseId]);

  @override
  int? sideSwitchSecondsFor(String exerciseId) => switchSeconds[exerciseId];

  @override
  bool has(String key, {required String lang}) => true;

  @override
  double seconds(String key, {required String lang}) => .4;

  @override
  String? voiceGuideClipKey(
    String exerciseId,
    String clipId, {
    required String lang,
  }) => clipId;
}

Map<String, Object?> _guide(String mode, Map<String, Object?> data) => {
  'format': 'pose-hub-voice-guide@1',
  'status': 'ready',
  'mode': mode,
  ...data,
};

Map<String, Object?> _authored(String id, Map<String, Object?> at) => {
  ...at,
  'clipId': id,
  'zh': '保持住',
  'en': 'Hold steady',
};

final _hold = _guide('hold', {
  'set': [
    {'at': 0, 'key': 'p.go'},
    _authored('g.set.1', {'at': 4}),
    _authored('g.set.2', {'at': 11}),
    {'at': 17, 'key': 'n.3'},
    {'at': 18, 'key': 'n.2'},
    {'at': 19, 'key': 'n.1'},
  ],
  'afterSet': {
    'moreSets': ['p.release', 'p.rest', 'sec.45'],
    'allDone': ['p.release', 'p.nice'],
  },
});

final _lungeRhythm = Rhythm.fromJson({
  'kind': 'rep_alternate',
  'leadSeconds': 1,
  'repUnit': 'left+right',
  'startingSide': 'right',
  'phases':
      'go=1.5s@phase.start; hold=0.5s@phase.peak; back=1.2s@phase.end; rest=0.3s',
});

const _lunge = 'h-forward-lunge';
const _pigeon = 's-pigeon';

List<VoiceCue> _workCues(_PackVoice voice, SessionPhase work) =>
    SessionScript(source: voice).cues(work, planSeconds: 0);

void main() {
  test(
    'abs-A recomputes the countdown and crops coaching to the edited dose',
    () {
      final voice = _PackVoice({'abs-A': _hold});
      final builder = SessionBuilder(voiceGuideFor: voice.voiceGuide);
      final phases = builder.phases(
        planOf([timed('abs-A', 12, sets: 2, rest: 45)]),
      );
      final work = phases.where((phase) => phase.isWork).toList();
      final cues = _workCues(voice, work.first);
      expect(
        cues
            .where((cue) => cue.priority == CuePriority.count)
            .map((cue) => cue.at),
        [9, 10, 11],
      );
      expect(cues.expand((cue) => cue.clips), contains('g.set.1'));
      expect(cues.expand((cue) => cue.clips), isNot(contains('g.set.2')));
      expect(cues.last.clips, ['p.release', 'p.rest', 'sec.45']);
      expect(_workCues(voice, work.last).last.clips, ['p.release', 'p.nice']);
    },
  );

  test(
    'forward lunge counts pairs after both sides and moves the last reminder',
    () {
      final voice = _PackVoice({
        _lunge: _guide('reps', {
          'repSeconds': 7,
          'repUnit': 'left+right',
          'phaseCues': 'first-2-reps',
          'count': {'key': 'n.{rep}', 'at': 'rep-end'},
          'before': ['p.right_first'],
          'reminders': [
            _authored('g.rem.0', {'afterRep': 2}),
            {'afterRep': 7, 'key': 'p.last_rep'},
          ],
          'afterSet': {
            'allDone': ['p.nice'],
          },
        }),
      });
      final builder = SessionBuilder(
        rhythms: {_lunge: _lungeRhythm},
        voiceGuideFor: voice.voiceGuide,
      );
      final phases = builder.phases(planOf([reps(_lunge, 5, perSide: true)]));
      expect(phases.where((p) => p.kind == PhaseKind.switchSide), isEmpty);
      final script = SessionScript(source: voice);
      expect(
        script.cues(phases.first, planSeconds: 40).expand((cue) => cue.clips),
        contains('p.right_first'),
      );
      final work = phases.singleWhere((phase) => phase.isWork);
      final cues = _workCues(voice, work);
      final counts = cues
          .where((cue) => cue.priority == CuePriority.count)
          .toList();
      expect(counts.map((cue) => cue.at), [8, 15, 22, 29, 36]);
      expect(counts.map((cue) => cue.clips.single), [
        'n.1',
        'n.2',
        'n.3',
        'n.4',
        'n.5',
      ]);
      expect(counts.last.atWorkEnd, isTrue);
      final phasesSpoken = cues.where(
        (cue) => cue.clips.first.startsWith('phase.'),
      );
      expect(phasesSpoken, hasLength(12));
      expect(phasesSpoken.last.at, lessThan(15));
      final last = cues.singleWhere((cue) => cue.clips.contains('p.last_rep'));
      expect(last.at, greaterThan(29));
      expect(last.at, lessThan(36));
      expect(cues.last.clips, ['p.nice']);
    },
  );

  test('pigeon finishes every set on one side before one 10-second switch', () {
    final voice = _PackVoice(
      {
        _pigeon: _guide('hold', {
          ..._hold,
          'afterSet': {
            'moreSetsSameSide': ['p.rest', 'sec.15'],
            'sideDone': ['p.release', 'p.switch_left'],
            'allDone': ['p.nice'],
          },
          'sides': {
            'order': ['right', 'left'],
            'perSide': 'each-side-separately',
          },
        }),
      },
      switchSeconds: {_pigeon: 10},
    );
    final builder = SessionBuilder(
      prepSeconds: 0,
      voiceGuideFor: voice.voiceGuide,
      guideSideSwitchSecondsFor: voice.sideSwitchSecondsFor,
    );
    final phases = builder.phases(
      planOf([timed(_pigeon, 30, sets: 2, perSide: true, rest: 15)]),
    );
    final work = phases.where((p) => p.isWork).toList();
    expect(work.map((p) => (p.side, p.set)), [
      (Side.right, 1),
      (Side.right, 2),
      (Side.left, 1),
      (Side.left, 2),
    ]);
    expect(
      phases.singleWhere((p) => p.kind == PhaseKind.switchSide).seconds,
      10,
    );
    expect(_workCues(voice, work[1]).last.clips, [
      'p.release',
      'p.switch_left',
    ]);
    final engine = SessionEngine(phases);
    engine.update(75);
    expect(engine.phase.kind, PhaseKind.switchSide);
    engine.update(85, waitForGuideSpeech: true);
    expect(engine.phase.kind, PhaseKind.switchSide);
    engine.update(86.25);
    expect(engine.phase.side, Side.left);
    expect(engine.phaseStart, 86.25);
  });

  test('long reps repeat each authored step and still count on rep end', () {
    const id = 'deltoids-B';
    final voice = _PackVoice({
      id: _guide('reps', {
        'repSeconds': 14,
        'phaseCues': 'steps',
        'count': {'key': 'n.{rep}', 'at': 'rep-end'},
        'steps': [
          _authored('g.step.0', {'at': 1.5}),
          _authored('g.step.1', {'at': 3.4}),
          _authored('g.step.2', {'at': 5.3}),
          _authored('g.step.3', {'at': 6.9}),
          _authored('g.step.4', {'at': 8.5}),
          _authored('g.step.5', {'at': 10.3}),
          _authored('g.step.6', {'at': 12.3}),
        ],
        'reminders': [
          {'afterRep': 2, 'key': 'p.last_rep'},
        ],
      }),
    });
    final builder = SessionBuilder(
      rhythms: {id: Rhythm.fromRepSeconds(14)},
      voiceGuideFor: voice.voiceGuide,
    );
    final work = builder
        .phases(planOf([reps(id, 3)]))
        .singleWhere((p) => p.isWork);
    final cues = _workCues(voice, work);
    expect(cues.where((c) => c.clips.contains('g.step.0')).map((c) => c.at), [
      1.5,
      15.5,
      29.5,
    ]);
    expect(
      cues.where((c) => c.priority == CuePriority.count).map((c) => c.at),
      [14, 28, 42],
    );
    expect(cues.where((c) => c.clips.contains('p.last_rep')), hasLength(1));
  });

  test(
    'non-ready and missing guides keep the same legacy timeline and cues',
    () {
      final voice = _PackVoice({
        'abs-A': {..._hold, 'status': 'script-only'},
      });
      final baseline = _PackVoice({});
      final plan = planOf([timed('abs-A', 20, sets: 2)]);
      final phases = SessionBuilder(
        voiceGuideFor: voice.voiceGuide,
      ).phases(plan);
      final original = SessionBuilder().phases(plan);
      expect(
        phases.map((p) => p.toString()),
        original.map((p) => p.toString()),
      );
      for (final phase in phases.where((p) => p.isWork)) {
        final oldCues = _workCues(baseline, phase);
        final newCues = _workCues(voice, phase);
        expect(
          newCues.map((c) => c.toString()),
          oldCues.map((c) => c.toString()),
        );
        expect(newCues.every((c) => !c.queueWithoutCutting), isTrue);
      }
    },
  );
}
