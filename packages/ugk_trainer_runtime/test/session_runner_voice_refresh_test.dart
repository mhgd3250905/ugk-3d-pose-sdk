import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/engine.dart';

class _PreparedScript extends SessionScript {
  _PreparedScript() : super(source: ManifestVoiceSource.empty);

  bool prepared = false;

  @override
  List<VoiceCue> cues(
    SessionPhase phase, {
    required double planSeconds,
    bool bySkip = false,
  }) => [
    const VoiceCue(0, ['welcome'], CuePriority.call),
    if (prepared) const VoiceCue(1, ['downloaded-intro'], CuePriority.call),
    const VoiceCue(5, ['future'], CuePriority.call),
  ];
}

SessionEngine _engine() => SessionEngine(const [
  SessionPhase(kind: PhaseKind.prep, seconds: 20),
  SessionPhase(kind: PhaseKind.work, seconds: 20),
  SessionPhase(kind: PhaseKind.done, seconds: 0),
]);

List<String> _clips(List<FiredCue> cues) => [
  for (final fired in cues) ...fired.cue.clips,
];

void main() {
  test('preparation before the first tick keeps the welcome pending once', () {
    final script = _PreparedScript();
    final runner = SessionRunner(_engine(), script);
    script.prepared = true;
    runner.refreshVoice(0);
    runner.refreshVoice(0);
    expect(_clips(runner.update(0)), ['welcome']);
    expect(runner.update(0), isEmpty);
    expect(runner.update(.1), isEmpty);
    expect(_clips(runner.update(1)), ['downloaded-intro']);
  });

  test('a refresh at zero never replays a welcome already fired', () {
    final script = _PreparedScript();
    final runner = SessionRunner(_engine(), script);
    expect(_clips(runner.update(0)), ['welcome']);
    script.prepared = true;
    runner.refreshVoice(0);
    expect(runner.update(0), isEmpty);
    expect(runner.update(.1), isEmpty);
    expect(_clips(runner.update(1)), ['downloaded-intro']);
    runner.refreshVoice(1);
    expect(runner.update(1), isEmpty);
    expect(_clips(runner.update(5)), ['future']);
  });

  test('late or different-generation refreshes do not backfill past cues', () {
    for (final newGeneration in [false, true]) {
      final script = _PreparedScript();
      final engine = _engine();
      final runner = SessionRunner(engine, script);
      script.prepared = true;
      final refreshAt = newGeneration ? 20.0 : 3.0;
      if (newGeneration) engine.update(refreshAt);
      runner.refreshVoice(refreshAt);
      expect(runner.update(refreshAt), isEmpty);
      final futureAt = engine.phaseStart + 5;
      expect(_clips(runner.update(futureAt)), ['future']);
      expect(runner.update(futureAt), isEmpty);
    }
  });
}
