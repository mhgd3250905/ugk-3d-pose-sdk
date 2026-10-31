import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _plan = TrainingPlan(
  id: 'player-timing',
  source: 'ai',
  title: 'Player timeline',
  goal: 'mobility',
  scene: 'home',
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(
      id: 'warmup',
      name: 'Warmup',
      type: BlockType.warmup,
      items: [
        PlanItem(
          exerciseId: 'counted',
          mode: DoseMode.reps,
          reps: 6,
          sets: 1,
          perSide: false,
          restSeconds: 15,
        ),
      ],
    ),
    PlanBlock(
      id: 'main',
      name: 'Main',
      type: BlockType.main,
      rounds: 2,
      restBetweenRoundsSeconds: 25,
      items: [
        PlanItem(
          exerciseId: 'bilateral',
          mode: DoseMode.time,
          workSeconds: 40,
          sets: 2,
          perSide: true,
          restSeconds: 20,
        ),
      ],
    ),
  ],
);

class _CountingBuilder extends SessionBuilder {
  _CountingBuilder()
    : super(
        prepSeconds: 15,
        transitionSeconds: 17,
        rhythms: const {
          'counted': Rhythm(
            kind: ActionKind.repUpdown,
            lead: 1,
            phases: [KitPhase('go', 4, [])],
          ),
        },
        switchSecondsFor: (_, _, _) => 8,
      );

  int phaseCalls = 0;

  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    phaseCalls++;
    return super.phases(plan);
  }
}

class _PhaseBuilder extends SessionBuilder {
  _PhaseBuilder(this.timeline);
  final List<SessionPhase> timeline;

  @override
  List<SessionPhase> phases(TrainingPlan plan) => timeline;
}

CoachSessionState _savedCircuitState(TrainingPlan saved) => CoachSessionState(
  params: {
    for (final entry in <String, Object>{
      'scene': 'home',
      'minutes': 5,
      'goal': ['body.abs'],
      'equipment': <String>[],
      'limits': <String>[],
    }.entries)
      entry.key: CoachParamValue(
        value: entry.value,
        source: 'default',
        turn: 0,
      ),
  },
  picks: saved.exerciseIds.toList(),
  seenActionIds: saved.exerciseIds,
  activePlanId: saved.id,
  plans: {
    saved.id: [
      CoachPlanVersion(
        version: 1,
        plan: saved.toJson(),
        estimateSec: 300,
        fitLog: const [],
      ),
    ],
  },
);

void main() {
  test(
    'adapter sums the player phases once with the same block attribution',
    () {
      final builder = _CountingBuilder();
      final timing = evaluatePlanExecutionTiming(
        _plan,
        builder.executionTiming,
      );
      expect(builder.phaseCalls, 1);
      final timeline = builder.phases(_plan);
      expect(
        timing.totalSeconds,
        timeline.fold(0.0, (sum, phase) => sum + phase.seconds),
      );
      expect(timing.blocks.map((block) => block.blockId), ['warmup', 'main']);
      for (final (index, block) in timing.blocks.indexed) {
        expect(
          block.seconds,
          timeline
              .where((phase) => phase.blockIndex == index)
              .fold(0.0, (sum, phase) => sum + phase.seconds),
        );
      }
      expect(timing.containsManualCounting, isFalse);
      expect(timeline.first.seconds, 15);
      expect(timeline.firstWhere((phase) => phase.isWork).seconds, 25);
      expect(
        timeline.where((phase) => phase.kind == PhaseKind.switchSide),
        everyElement(
          isA<SessionPhase>().having((phase) => phase.seconds, 'seconds', 8),
        ),
      );
      expect(
        timeline.any((phase) => phase.kind == PhaseKind.roundRest),
        isTrue,
      );
    },
  );

  test('manual-counted work is estimated while clock-counted reps are not', () {
    final builder = SessionBuilder(
      rhythms: const {'counted': Rhythm.selfPacedReps},
    );
    final timing = evaluatePlanExecutionTiming(_plan, builder.executionTiming);
    expect(timing.containsManualCounting, isTrue);
    expect(
      timing.totalSeconds,
      builder.phases(_plan).fold(0.0, (sum, phase) => sum + phase.seconds),
    );
    expect(
      SessionBuilder(
        rhythms: {'counted': Rhythm.fromRepSeconds(4)},
      ).executionTiming(_plan).containsManualCounting,
      isFalse,
    );
  });

  test('unassigned phases remain included only in the overall total', () {
    final builder = _PhaseBuilder(const [
      SessionPhase(kind: PhaseKind.prep, seconds: 15),
      SessionPhase(kind: PhaseKind.work, seconds: 20, blockIndex: 0),
      SessionPhase(kind: PhaseKind.work, seconds: 40, blockIndex: 1),
      SessionPhase(kind: PhaseKind.done, seconds: 0),
    ]);
    final timing = evaluatePlanExecutionTiming(_plan, builder.executionTiming);
    expect(timing.totalSeconds, 75);
    expect(timing.blocks.map((block) => block.seconds), [20, 40]);
  });

  test(
    'empty blocks preserve their identities and have zero assigned seconds',
    () {
      final emptyPlan = _plan.copyWith(
        blocks: [
          ..._plan.blocks,
          const PlanBlock(
            id: 'empty',
            name: 'Empty',
            type: BlockType.cooldown,
            items: [],
          ),
        ],
      );
      final builder = SessionBuilder();
      final timing = evaluatePlanExecutionTiming(
        emptyPlan,
        builder.executionTiming,
      );
      expect(timing.blocks.last.blockId, 'empty');
      expect(timing.blocks.last.seconds, 0);
      final noWork = _plan.copyWith(blocks: []);
      final empty = evaluatePlanExecutionTiming(
        noWork,
        builder.executionTiming,
      );
      expect(empty.totalSeconds, 0);
      expect(empty.blocks, isEmpty);
      expect(empty.containsManualCounting, isFalse);
    },
  );

  for (final seconds in [double.nan, double.infinity, -1.0]) {
    test('rejects a malformed timeline phase with $seconds seconds', () {
      final builder = _PhaseBuilder([
        SessionPhase(kind: PhaseKind.work, seconds: seconds, blockIndex: 0),
      ]);
      expect(
        () => evaluatePlanExecutionTiming(_plan, builder.executionTiming),
        throwsA(
          isA<PlanExecutionTimingException>().having(
            (error) => error.code,
            'code',
            'execution_timing_callback_failed',
          ),
        ),
      );
    });
  }

  for (final blockIndex in [-2, 2]) {
    test('rejects a timeline phase with invalid block index $blockIndex', () {
      final builder = _PhaseBuilder([
        SessionPhase(kind: PhaseKind.work, seconds: 10, blockIndex: blockIndex),
      ]);
      expect(
        () => evaluatePlanExecutionTiming(_plan, builder.executionTiming),
        throwsA(isA<PlanExecutionTimingException>()),
      );
    });
  }

  test(
    'circuit single-round maximum remains reachable after native bounds',
    () {
      const profile = CoachProfile(
        id: 'circuit-native-bounds',
        appName: 'circuit-native-bounds',
        minActions: 1,
        limits: PlanLimits(
          sets: IntRange(1, 6),
          rounds: IntRange(1, 2),
          workSeconds: IntRange(60, 60),
          restSeconds: IntRange(0, 0),
          restBetweenRoundsSeconds: IntRange(0, 0),
        ),
      );
      final catalog = Catalog(
        version: 'circuit-native-bounds',
        drills: [
          Drill(
            id: 'hold',
            name: const LocalizedText({'zh': '保持', 'en': 'hold'}),
            category: 'core',
            muscleGroups: const ['abs'],
            position: 'standing',
            unilateral: false,
            level: 1,
            scenes: const ['home'],
            defaultDose: const Dose(
              mode: DoseMode.time,
              sets: 1,
              seconds: 60,
              restSeconds: 0,
            ),
            doseRange: const DoseRange(
              sets: IntRange(1, 6),
              seconds: IntRange(60, 60),
              restSeconds: IntRange(0, 0),
            ),
          ),
        ],
      );
      TrainingPlan candidate(int rounds, int sets) => TrainingPlan(
        id: 'circuit',
        source: 'ai',
        title: 'Circuit bounds regression',
        summary: 'Single rounds retain item sets.',
        goal: 'core',
        scene: 'home',
        level: 1,
        targetMinutes: 5,
        blocks: [
          PlanBlock(
            id: 'circuit-block',
            name: 'Circuit',
            type: BlockType.circuit,
            rounds: rounds,
            items: [
              PlanItem(
                exerciseId: 'hold',
                mode: DoseMode.time,
                workSeconds: 60,
                sets: sets,
                perSide: false,
                restSeconds: 0,
              ),
            ],
          ),
        ],
      );
      final builder = SessionBuilder();
      expect(builder.executionTiming(candidate(1, 1)).totalSeconds, 70);
      expect(builder.executionTiming(candidate(2, 6)).totalSeconds, 145);
      expect(
        const PlanDuration().estimateSeconds(candidate(2, 6), catalog),
        745,
      );
      final saved = candidate(1, 5);
      expect(builder.executionTiming(saved).totalSeconds, 310);
      expect(const PlanDuration().estimateSeconds(saved, catalog), 310);
      final state = _savedCircuitState(saved);
      final legacy = PlanBuilder(
        profile,
        catalog,
        minPicks: 1,
      ).refit(state, saved);
      expect(legacy.ok, isTrue, reason: '${legacy.error}');
      final result = PlanBuilder(
        profile,
        catalog,
        minPicks: 1,
        executionTiming: builder.executionTiming,
      ).refit(state, saved);
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.executionTiming!.totalSeconds, 310);
      expect(result.state.plans[saved.id], hasLength(2));
      expect(result.state.plans[saved.id]!.last.estimateSec, 310);
      expect(result.fitLog, isEmpty);
      expect(state.plans[saved.id], hasLength(1));
    },
  );

  test('native bounds include simultaneous branches of two circuit blocks', () {
    const profile = CoachProfile(
      id: 'two-circuit-bounds',
      appName: 'two-circuit-bounds',
      minActions: 1,
      limits: PlanLimits(
        sets: IntRange(1, 6),
        rounds: IntRange(1, 2),
        workSeconds: IntRange(21, 21),
        restSeconds: IntRange(0, 0),
        restBetweenRoundsSeconds: IntRange(0, 0),
      ),
    );
    final catalog = Catalog(
      version: 'two-circuit-bounds',
      drills: [
        for (final id in ['first', 'second'])
          Drill(
            id: id,
            name: LocalizedText({'zh': '保持 $id', 'en': id}),
            category: 'core',
            muscleGroups: const ['abs'],
            position: 'standing',
            unilateral: false,
            level: 1,
            scenes: const ['home'],
            defaultDose: const Dose(
              mode: DoseMode.time,
              sets: 1,
              seconds: 21,
              restSeconds: 0,
            ),
            doseRange: const DoseRange(
              sets: IntRange(1, 6),
              seconds: IntRange(21, 21),
              restSeconds: IntRange(0, 0),
            ),
          ),
      ],
    );
    TrainingPlan candidate(int firstRounds, int secondRounds) => TrainingPlan(
      id: 'two-circuits',
      source: 'ai',
      title: 'Two circuit branches',
      summary: 'Both single-round branches are required for the upper bound.',
      goal: 'core',
      scene: 'home',
      level: 1,
      targetMinutes: 5,
      blocks: [
        for (final (index, id) in ['first', 'second'].indexed)
          PlanBlock(
            id: 'block-$id',
            name: id,
            type: BlockType.circuit,
            rounds: index == 0 ? firstRounds : secondRounds,
            items: [
              PlanItem(
                exerciseId: id,
                mode: DoseMode.time,
                workSeconds: 21,
                sets: 6,
                perSide: false,
                restSeconds: 0,
              ),
            ],
          ),
      ],
    );
    final builder = SessionBuilder();
    expect(builder.executionTiming(candidate(2, 2)).totalSeconds, 139);
    expect(builder.executionTiming(candidate(1, 2)).totalSeconds, 208);
    expect(builder.executionTiming(candidate(2, 1)).totalSeconds, 208);
    final saved = candidate(1, 1);
    expect(builder.executionTiming(saved).totalSeconds, 277);
    expect(const PlanDuration().estimateSeconds(saved, catalog), 277);
    final state = _savedCircuitState(saved);
    final result = PlanBuilder(
      profile,
      catalog,
      minPicks: 1,
      executionTiming: builder.executionTiming,
    ).refit(state, saved);
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.executionTiming!.totalSeconds, 277);
    expect(result.state.plans[saved.id]!.last.estimateSec, 277);
    expect(result.state.plans[saved.id], hasLength(2));
    expect(result.fitLog, isEmpty);
    expect(state.plans[saved.id], hasLength(1));
  });
}
