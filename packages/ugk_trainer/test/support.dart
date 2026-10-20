// Test helpers. RecordingOutput and Sim are ported from HipLab@99fcc83
// test/hip/hip_voice_test.dart (and SmartFit@e8981ee test/voice_session_test.dart
// RecordingVoiceOutput); fixtures are copies of HipLab assets/voice/manifest.json,
// five HipLab action kits and five SmartFit drill packs (pack.json only).
import 'dart:convert';
import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

Map<String, dynamic> loadJson(String path) =>
    jsonDecode(File('test/fixtures/$path').readAsStringSync())
        as Map<String, dynamic>;

const hipKits = [
  'h-squat',
  'h-sumo-pry',
  'h-couch-stretch',
  'h-hip-gate',
  'h-quad-cars',
];
const smartPacks = ['h-squat', 'w-dead-bug', 'h-couch-stretch', 's-figure4'];

Map<String, Map<String, dynamic>> _kits() => {
  for (final k in hipKits) k: loadJson('hiplab/action_kits/$k.json'),
};

ManifestVoiceSource hipSource() => ManifestVoiceSource.fromJson(
  loadJson('hiplab/manifest.json'),
  kitVoices: {
    for (final e in _kits().entries) e.key: KitVoice.fromActionKitJson(e.value),
  },
);

Map<String, Rhythm> hipRhythms() => {
  for (final e in _kits().entries) e.key: Rhythm.fromActionKitJson(e.value),
};

DrillPackVoiceSource smartSource() => DrillPackVoiceSource.fromPacks(
  common: loadJson('smartfit/packs/_common/pack.json'),
  packs: {
    for (final p in smartPacks) p: loadJson('smartfit/packs/$p/pack.json'),
  },
);

Map<String, Rhythm> smartRhythms() => {
  for (final p in smartPacks)
    if ((loadJson('smartfit/packs/$p/pack.json')['media'] as Map)['repSeconds']
        case final num r)
      p: Rhythm.fromRepSeconds(r.toDouble()),
};

TrainingPlan planOf(
  List<PlanItem> items, {
  BlockType type = BlockType.main,
  int rounds = 1,
  int restBetweenRounds = 40,
  List<PlanBlock> more = const [],
}) => TrainingPlan(
  id: 'p',
  source: 'template',
  title: 't',
  goal: 'core',
  scene: 'home',
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(
      id: 'b',
      name: '主训练',
      type: type,
      rounds: rounds,
      restBetweenRoundsSeconds: restBetweenRounds,
      items: items,
    ),
    ...more,
  ],
);

PlanItem reps(
  String id,
  int n, {
  int sets = 1,
  bool perSide = false,
  int rest = 20,
}) => PlanItem(
  exerciseId: id,
  mode: DoseMode.reps,
  sets: sets,
  reps: n,
  perSide: perSide,
  restSeconds: rest,
);

PlanItem timed(
  String id,
  int seconds, {
  int sets = 1,
  bool perSide = false,
  int rest = 20,
}) => PlanItem(
  exerciseId: id,
  mode: DoseMode.time,
  sets: sets,
  workSeconds: seconds,
  perSide: perSide,
  restSeconds: rest,
);

class RecordingOutput implements VoiceOutput {
  final spoken = <List<String>>[];
  final chimes = <String>[];
  int stops = 0;
  @override
  Future<void> begin() async {}
  @override
  Future<void> end() async {}
  @override
  Future<void> speak(List<String> assets) async => spoken.add([...assets]);
  @override
  Future<void> stopSpeech() async => stops++;
  @override
  Future<void> chime(String asset) async => chimes.add(asset);
  @override
  set volume(double v) {}
}

/// Runs a whole session at 20 Hz through engine, script and queue. A
/// self-paced set is completed [selfPacedAfter] seconds in.
class Sim {
  Sim(
    this.plan, {
    required this.source,
    this.rhythms = const {},
    this.lang = 'zh',
    this.selfPacedAfter = 12,
    VoiceSettings? settings,
  }) : output = RecordingOutput() {
    script = SessionScript(source: source, lang: lang);
    builder = SessionBuilder(
      rhythms: rhythms,
      switchSecondsFor: script.switchSecondsFor,
    );
    runner = SessionRunner(SessionEngine(builder.phases(plan)), script);
    queue = VoiceQueue(
      output: output,
      lib: source,
      settings: settings ?? VoiceSettings(language: lang),
    );
  }

  final TrainingPlan plan;
  final VoiceSource source;
  final Map<String, Rhythm> rhythms;
  final String lang;
  final double selfPacedAfter;
  final RecordingOutput output;
  late final SessionScript script;
  late final SessionBuilder builder;
  late final SessionRunner runner;
  late final VoiceQueue queue;
  final fired = <FiredCue>[];

  SessionEngine get engine => runner.engine;

  void _submit(Iterable<FiredCue> cues, double t) {
    for (final f in cues) {
      fired.add(f);
      queue.submit(f.cue, t);
    }
  }

  void run({double until = 1e9}) {
    var t = 0.0;
    while (t <= until) {
      _submit(runner.update(t), t);
      if (engine.awaitingCompletion &&
          t - engine.phaseStart >= selfPacedAfter) {
        _submit(runner.completeSet(t), t);
      }
      queue.tick(t);
      if (engine.done && t > engine.phaseStart + 8) break;
      t = double.parse((t + .05).toStringAsFixed(2));
    }
  }

  List<SpokenLine> get lines => queue.log;
}

/// A HipLab-style plan over the five kits.
Sim hipSim(String lang) => Sim(
  planOf([
    reps('h-squat', 8),
    timed('h-couch-stretch', 40, perSide: true),
    reps('h-sumo-pry', 3),
    reps('h-hip-gate', 6, perSide: true),
    reps('h-quad-cars', 3, perSide: true),
  ]),
  source: hipSource(),
  rhythms: hipRhythms(),
  lang: lang,
);

/// A SmartFit-style plan: sets, per side, a circuit.
Sim smartSim() => Sim(
  planOf(
    [
      reps('h-squat', 10, sets: 2, rest: 30),
      timed('h-couch-stretch', 30, perSide: true),
      timed('s-figure4', 30, perSide: true, sets: 2, rest: 15),
    ],
    more: [
      PlanBlock(
        id: 'c',
        name: '循环',
        type: BlockType.circuit,
        rounds: 2,
        restBetweenRoundsSeconds: 30,
        items: [reps('w-dead-bug', 8), reps('h-squat', 8)],
      ),
    ],
  ),
  source: smartSource(),
  rhythms: smartRhythms(),
);
