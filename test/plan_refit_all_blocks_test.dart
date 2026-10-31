import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _types = [BlockType.warmup, BlockType.main, BlockType.cooldown];

const _profile = CoachProfile(
  id: 'refit-all-blocks',
  appName: 'refit-all-blocks',
  limits: PlanLimits(
    sets: IntRange(1, 1),
    rounds: IntRange(1, 1),
    reps: IntRange(1, 50),
    workSeconds: IntRange(10, 160),
    restSeconds: IntRange(0, 0),
    restBetweenRoundsSeconds: IntRange(0, 0),
    minutes: IntRange(1, 60),
  ),
);

Drill _drill(
  String id, {
  DoseMode mode = DoseMode.time,
  int amount = 20,
  IntRange? range,
}) => Drill(
  id: id,
  name: LocalizedText({'en': id}),
  category: 'core',
  muscleGroups: const ['abs'],
  position: 'standing',
  unilateral: false,
  level: 1,
  scenes: const ['home'],
  defaultDose: Dose(
    mode: mode,
    sets: 1,
    reps: mode == DoseMode.reps ? amount : null,
    seconds: mode == DoseMode.time ? amount : null,
    restSeconds: 0,
  ),
  doseRange: DoseRange(
    sets: const IntRange(1, 1),
    reps: mode == DoseMode.reps ? range ?? IntRange(amount, amount) : null,
    seconds: mode == DoseMode.time ? range ?? IntRange(amount, amount) : null,
    restSeconds: const IntRange(0, 0),
  ),
);

PlanItem _ordinary(
  String id, {
  DoseMode mode = DoseMode.time,
  int amount = 20,
}) => PlanItem(
  exerciseId: id,
  mode: mode,
  sets: 1,
  reps: mode == DoseMode.reps ? amount : null,
  workSeconds: mode == DoseMode.time ? amount : null,
  perSide: false,
  restSeconds: 0,
  note: 'Keep $id note',
);

TrainingPlan _plan(PlanItem Function(BlockType type) itemFor) => TrainingPlan(
  id: 'saved-refit',
  source: 'ai',
  title: 'Saved title',
  summary: 'Saved summary',
  goal: 'core',
  scene: 'home',
  level: 1,
  targetMinutes: 10,
  blocks: [
    for (final type in _types)
      PlanBlock(
        id: 'block-${type.name}',
        name: 'Saved ${type.name} heading',
        type: type,
        items: [itemFor(type)],
      ),
  ],
);

CoachSessionState _ready(
  TrainingPlan plan,
  Catalog catalog, {
  int minutes = 3,
  List<Map<String, Object?>>? dose,
}) {
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', quote: '调整训练时长', turn: 2);
  return CoachSessionState(
    userTurns: const [CoachUserTurn(turn: 2, text: '调整训练时长')],
    params: {
      'scene': param('home'),
      'minutes': param(minutes),
      'goal': param(['body.abs']),
      'equipment': param(<String>[]),
      'limits': param(<String>[]),
      if (dose != null) 'dose': param(dose),
    },
    seenActionIds: {for (final drill in catalog.drills) drill.id},
    picks: [for (final drill in catalog.drills) drill.id],
    activePlanId: plan.id,
    lastDeliveredPlanId: plan.id,
    lastDeliveredVersion: 1,
    lastDeliveredTurn: 1,
    plans: {
      plan.id: [
        CoachPlanVersion(
          version: 1,
          plan: plan.toJson(),
          estimateSec: const PlanDuration().estimateSeconds(plan, catalog),
          fitLog: [],
        ),
      ],
    },
  );
}

TrainingPlan _resultPlan(DraftResult result, TrainingPlan original) {
  expect(result.ok, isTrue, reason: '${result.toJson()}');
  expect(result.feasibility, isNull);
  expect(result.planId, original.id);
  expect(result.version, 2);
  expect(result.state.focusPlanId, isNull);
  expect(result.state.plans[original.id]!, hasLength(2));
  expect(result.state.plans[original.id]!.first.plan, original.toJson());
  final fitted = const PlanCodec().decode(
    result.state.plans[original.id]!.last.plan,
  );
  expect(fitted.targetMinutes, 3);
  expect((fitted.title, fitted.summary), (original.title, original.summary));
  expect(
    fitted.blocks.map(
      (block) => (block.id, block.name, block.type, block.rounds),
    ),
    original.blocks.map(
      (block) => (block.id, block.name, block.type, block.rounds),
    ),
  );
  expect(
    fitted.items.map(
      (item) => (item.exerciseId, item.mode, item.perSide, item.note),
    ),
    original.items.map(
      (item) => (item.exerciseId, item.mode, item.perSide, item.note),
    ),
  );
  return fitted;
}

Map<String, Object?> _metadata(PlanSegment segment) => segment.toJson()
  ..remove('reps')
  ..remove('workSeconds');

const _authoredRhythm = <String, Object?>{
  'kind': 'rep_hold',
  'leadSeconds': 0,
  'phases': [
    {'id': 'go', 'seconds': 1, 'cue': 'up'},
    {'id': 'hold', 'seconds': 2, 'cue': 'hold'},
  ],
};

void main() {
  for (final type in [BlockType.warmup, BlockType.cooldown]) {
    for (final mode in [DoseMode.reps, DoseMode.time]) {
      test(
        'ordinary ${type.name} ${mode.name} work is searchable without focus',
        () {
          final amount = mode == DoseMode.reps ? 50 : 150;
          final catalog = Catalog(
            version: 'ordinary-refit',
            drills: [
              for (final blockType in _types)
                blockType == type
                    ? _drill(
                        type.name,
                        mode: mode,
                        amount: amount,
                        range: mode == DoseMode.reps
                            ? const IntRange(20, 50)
                            : const IntRange(80, 150),
                      )
                    : _drill(blockType.name),
            ],
          );
          final original = _plan(
            (blockType) => blockType == type
                ? _ordinary(type.name, mode: mode, amount: amount)
                : _ordinary(blockType.name),
          );
          final state = _ready(original, catalog);
          final result = PlanBuilder(
            _profile,
            catalog,
            minPicks: 3,
          ).refit(state, original);
          final plan = _resultPlan(result, original);
          expect(
            const PlanDuration().estimateSeconds(plan, catalog),
            closeTo(180, 18),
          );
          final item = plan.blocks
              .singleWhere((block) => block.type == type)
              .items
              .single;
          expect(
            mode == DoseMode.reps ? item.reps : item.workSeconds,
            lessThan(amount),
          );
          expect(
            mode == DoseMode.reps ? item.reps : item.workSeconds,
            inInclusiveRange(mode == DoseMode.reps ? 20 : 80, amount),
          );
          expect(plan.items.map((item) => item.sets), everyElement(1));
          expect(state.plans[original.id]!, hasLength(1));
        },
      );
    }
  }

  for (final type in _types) {
    for (final mode in [DoseMode.reps, DoseMode.time]) {
      test(
        'segmented ${type.name} ${mode.name} work fits without flattening metadata',
        () {
          final amount = mode == DoseMode.reps ? 50 : 150;
          final variable = PlanSegment(
            id: 'original-variable-id',
            exerciseId: 'part-variable',
            mode: mode,
            reps: mode == DoseMode.reps ? amount : null,
            workSeconds: mode == DoseMode.time ? amount : null,
            holdSeconds: 2,
            label: 'Original variable label',
            rhythm: _authoredRhythm,
          );
          const fixed = PlanSegment(
            id: 'original-fixed-id',
            exerciseId: 'part-fixed',
            mode: DoseMode.time,
            workSeconds: 20,
            holdSeconds: 1,
            label: 'Original fixed label',
            rhythm: {'kind': 'hold', 'customMetadata': 'preserve'},
          );
          final catalog = Catalog(
            version: 'segmented-refit',
            drills: [
              for (final blockType in _types) _drill(blockType.name),
              _drill('group'),
              _drill(
                'part-variable',
                mode: mode,
                amount: amount,
                range: mode == DoseMode.reps
                    ? const IntRange(10, 50)
                    : const IntRange(40, 150),
              ),
              _drill('part-fixed'),
            ],
          );
          final original = _plan(
            (blockType) => blockType == type
                ? PlanItem(
                    exerciseId: 'group',
                    mode: DoseMode.time,
                    sets: 1,
                    workSeconds: 100,
                    perSide: false,
                    restSeconds: 0,
                    note: 'Original group note',
                    segments: [variable, fixed],
                  )
                : _ordinary(blockType.name),
          );
          final result = PlanBuilder(
            _profile,
            catalog,
            minPicks: 3,
          ).refit(_ready(original, catalog), original);
          final plan = _resultPlan(result, original);
          expect(
            const PlanDuration().estimateSeconds(plan, catalog),
            closeTo(180, 18),
          );
          final group = plan.blocks
              .singleWhere((block) => block.type == type)
              .items
              .single;
          expect(group.workSeconds, 100);
          expect(group.segments, hasLength(2));
          expect(
            group.segments.map(_metadata),
            [variable, fixed].map(_metadata),
          );
          expect(group.segments.last.toJson(), fixed.toJson());
          final chosen = group.segments.first;
          expect(
            mode == DoseMode.reps ? chosen.reps : chosen.workSeconds,
            lessThan(amount),
          );
          expect(
            mode == DoseMode.reps ? chosen.reps : chosen.workSeconds,
            inInclusiveRange(mode == DoseMode.reps ? 10 : 40, amount),
          );
          expect(group.sets, 1);
          expect(result.fitLog, isNotEmpty);
        },
      );
    }
  }

  test('locked segment integer gap fails without committing a new version', () {
    const profile = CoachProfile(
      id: 'gap',
      appName: 'gap',
      limits: PlanLimits(
        sets: IntRange(1, 1),
        rounds: IntRange(1, 2),
        workSeconds: IntRange(10, 160),
        restSeconds: IntRange(0, 0),
        restBetweenRoundsSeconds: IntRange(0, 0),
      ),
    );
    final catalog = Catalog(
      version: 'gap',
      drills: [
        _drill('group'),
        _drill('part-variable', amount: 100, range: const IntRange(20, 150)),
      ],
    );
    const segment = PlanSegment(
      id: 'locked-segment-id',
      exerciseId: 'part-variable',
      mode: DoseMode.time,
      workSeconds: 100,
      label: 'Keep locked',
    );
    const original = TrainingPlan(
      id: 'saved-refit',
      source: 'ai',
      title: 'Integer segment gap',
      goal: 'core',
      scene: 'home',
      level: 1,
      targetMinutes: 10,
      blocks: [
        PlanBlock(
          id: 'main',
          name: 'Main',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: 'group',
              mode: DoseMode.time,
              sets: 1,
              workSeconds: 20,
              perSide: false,
              restSeconds: 0,
              segments: [segment],
            ),
          ],
        ),
      ],
    );
    final state = _ready(
      original,
      catalog,
      dose: [
        {'field': 'seconds', 'value': 100, 'actionId': 'part-variable'},
      ],
    );
    final result = PlanBuilder(
      profile,
      catalog,
      minPicks: 1,
    ).refit(state, original);
    // Locked part work permits only 110 or 225 seconds. The legal enclosing
    // interval includes 180, but neither discrete choice meets the ±10% gate.
    expect(result.ok, isFalse);
    expect(result.error!['code'], 'duration_fit_failed');
    expect(result.feasibility, isNull);
    expect(result.planId, isNull);
    expect(result.state, same(state));
    expect(result.state.plans[original.id]!, hasLength(1));
    expect(result.state.plans[original.id]!.single.plan, original.toJson());
  });

  test(
    'saved doses outside current catalogue/profile bounds are normalized or rejected without committing',
    () {
      final catalog = Catalog(
        version: 'new-tighter-bounds',
        drills: [
          _drill('warmup', amount: 100, range: const IntRange(80, 100)),
          _drill('main'),
          _drill('cooldown'),
        ],
      );
      final old = _plan(
        (type) =>
            _ordinary(type.name, amount: type == BlockType.warmup ? 200 : 20),
      );
      // These values can come from a card saved under an older, wider profile.
      // Retain that historical version, but never copy its obsolete doses into
      // the newly fitted version under the current one-set/one-round profile.
      final original = const PlanCodec().decode({
        ...old.toJson(),
        'blocks': [
          for (final block in old.blocks)
            {
              ...block.toJson(),
              'rounds': 4,
              'restBetweenRoundsSeconds': 99,
              'items': [
                for (final item in block.items)
                  {...item.toJson(), 'sets': 3, 'restSeconds': 99},
              ],
            },
        ],
      });
      final builder = PlanBuilder(_profile, catalog, minPicks: 3);
      final state = _ready(original, catalog);
      final result = builder.refit(state, original);
      expect(result.ok, isTrue, reason: '${result.toJson()}');
      expect(result.planId, original.id);
      expect(result.version, 2);
      final plan = const PlanCodec().decode(
        result.state.plans[original.id]!.last.plan,
      );
      expect(plan.blocks.map((block) => block.rounds), everyElement(1));
      expect(
        plan.blocks.map((block) => block.restBetweenRoundsSeconds),
        everyElement(0),
      );
      expect(plan.items.map((item) => item.sets), everyElement(1));
      expect(plan.items.map((item) => item.restSeconds), everyElement(0));
      expect(plan.items.map((item) => item.workSeconds), [100, 20, 20]);
      expect(const PlanDuration().estimateSeconds(plan, catalog), 180);
      expect(result.state.plans[original.id]!.first.plan, original.toJson());
      expect(state.plans[original.id]!, hasLength(1));

      final explicit = _ready(
        original,
        catalog,
        dose: [
          {'field': 'seconds', 'value': 200, 'actionId': 'warmup'},
        ],
      );
      final failed = builder.refit(explicit, original);
      expect(failed.planId, isNull);
      expect(failed.feasibility!['reason'], 'explicit_dose_conflict');
      expect(failed.state, same(explicit));
      expect(failed.state.plans[original.id]!, hasLength(1));
      expect(failed.state.plans[original.id]!.single.plan, original.toJson());
    },
  );
}
