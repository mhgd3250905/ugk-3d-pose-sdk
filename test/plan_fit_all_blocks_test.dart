import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _kinds = ['warmup', 'main', 'cooldown'];

Drill _drill(
  String id, {
  DoseMode mode = DoseMode.time,
  int amount = 20,
  int sets = 1,
  IntRange setRange = const IntRange(1, 1),
  IntRange? workRange,
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
    sets: sets,
    reps: mode == DoseMode.reps ? amount : null,
    seconds: mode == DoseMode.time ? amount : null,
    restSeconds: 0,
  ),
  doseRange: DoseRange(
    sets: setRange,
    reps: mode == DoseMode.reps ? workRange ?? IntRange(amount, amount) : null,
    seconds: mode == DoseMode.time
        ? workRange ?? IntRange(amount, amount)
        : null,
    restSeconds: const IntRange(0, 0),
  ),
);

CoachProfile _profile({
  IntRange sets = const IntRange(1, 1),
  IntRange rounds = const IntRange(1, 1),
}) => CoachProfile(
  id: 'all-blocks',
  appName: 'all-blocks',
  limits: PlanLimits(
    sets: sets,
    reps: const IntRange(1, 45),
    workSeconds: const IntRange(10, 140),
    restSeconds: const IntRange(0, 0),
    rounds: rounds,
    restBetweenRoundsSeconds: const IntRange(0, 0),
    minutes: const IntRange(1, 60),
  ),
);

CoachSessionState _ready(
  Catalog catalog,
  int minutes, {
  List<Map<String, Object?>>? dose,
}) {
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', quote: '测试条件', turn: 1);
  return CoachSessionState(
    userTurns: const [CoachUserTurn(turn: 1, text: '测试条件')],
    task: CoachTaskState(
      type: 'plan',
      reused: false,
      nodes: [
        for (final id in [
          'understand',
          'parameters',
          'actions',
          'planning',
          'review',
          'output',
        ])
          CoachNodeState(
            id: id,
            status: id == 'planning'
                ? 'current'
                : ['understand', 'parameters', 'actions'].contains(id)
                ? 'done'
                : 'pending',
          ),
      ],
    ),
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
  );
}

Map<String, Object?> _threeBlocks() => {
  'title': 'All-block fitting',
  'blocks': [
    for (final kind in _kinds)
      {
        'kind': kind,
        'items': [
          {'id': kind},
        ],
      },
  ],
};

TrainingPlan _saved(DraftResult result) {
  expect(result.ok, isTrue, reason: '${result.toJson()}');
  expect(result.planId, isNotNull, reason: '${result.toJson()}');
  return const PlanCodec().decode(result.state.plans[result.planId]!.last.plan);
}

void _withinTarget(TrainingPlan plan, Catalog catalog, int minutes) => expect(
  const PlanDuration().estimateSeconds(plan, catalog),
  closeTo(minutes * 60, minutes * 6 + 1e-7),
);

void main() {
  for (final kind in _kinds) {
    for (final field in ['reps', 'seconds', 'sets']) {
      test('$kind $field is fitted inside catalogue/profile intersection', () {
        final variable = field == 'reps'
            ? _drill(
                kind,
                mode: DoseMode.reps,
                amount: 50,
                workRange: const IntRange(20, 50),
              )
            : field == 'seconds'
            ? _drill(kind, amount: 150, workRange: const IntRange(80, 150))
            : _drill(kind, amount: 30, sets: 5, setRange: const IntRange(2, 5));
        final catalog = Catalog(
          version: 'all-blocks',
          drills: [
            for (final blockKind in _kinds)
              blockKind == kind ? variable : _drill(blockKind),
          ],
        );
        final result = PlanBuilder(
          _profile(sets: IntRange(1, field == 'sets' ? 4 : 1)),
          catalog,
          minPicks: 3,
        ).draft(_ready(catalog, 3), _threeBlocks(), newPlanId: 'fit');
        final plan = _saved(result);
        _withinTarget(plan, catalog, 3);
        expect(plan.blocks.map((block) => block.type.name), _kinds);
        expect(plan.items.map((item) => item.exerciseId), _kinds);
        final item = plan.items.singleWhere((item) => item.exerciseId == kind);
        if (field == 'reps') {
          expect(item.reps, inInclusiveRange(20, 45));
          expect(item.reps, lessThan(45));
        } else if (field == 'seconds') {
          expect(item.workSeconds, inInclusiveRange(80, 140));
          expect(item.workSeconds, lessThan(140));
        } else {
          expect(item.sets, inInclusiveRange(2, 4));
          expect(item.sets, lessThan(4));
        }
        expect(
          plan.items
              .where((item) => item.exerciseId != kind)
              .map(
                (item) =>
                    (item.mode, item.sets, item.workSeconds, item.restSeconds),
              ),
          everyElement((DoseMode.time, 1, 20, 0)),
        );
      });
    }

    test('$kind rounds can use the profile range above four', () {
      final catalog = Catalog(
        version: 'all-blocks',
        drills: [
          for (final blockKind in _kinds)
            _drill(blockKind, amount: blockKind == kind ? 100 : 20),
        ],
      );
      final state = _ready(
        catalog,
        10,
        dose: [
          for (final (index, blockKind) in _kinds.indexed)
            if (blockKind != kind)
              {'field': 'rounds', 'value': 1, 'blockId': 'b${index + 1}'},
        ],
      );
      final result = PlanBuilder(
        _profile(rounds: const IntRange(1, 6)),
        catalog,
        minPicks: 3,
      ).draft(state, _threeBlocks(), newPlanId: 'rounds');
      final plan = _saved(result);
      _withinTarget(plan, catalog, 10);
      expect(
        plan.blocks.singleWhere((block) => block.type.name == kind).rounds,
        5,
      );
      expect(
        plan.blocks
            .where((block) => block.type.name != kind)
            .map((block) => block.rounds),
        everyElement(1),
      );
    });
  }

  test(
    'a coupled sets change crosses a greedy local gap without adding actions',
    () {
      final catalog = Catalog(
        version: 'coupled',
        drills: [
          _drill('a', amount: 80, sets: 2, setRange: const IntRange(1, 2)),
          _drill('b', amount: 35, setRange: const IntRange(1, 2)),
        ],
      );
      final result =
          PlanBuilder(
            _profile(sets: const IntRange(1, 2)),
            catalog,
            minPicks: 1,
          ).draft(_ready(catalog, 3), {
            'title': 'Coupled sets',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  {'id': 'a'},
                  {'id': 'b'},
                ],
              },
            ],
          }, newPlanId: 'coupled');
      final plan = _saved(result);
      expect(
        {for (final item in plan.items) item.exerciseId: item.sets},
        {'a': 1, 'b': 2},
      );
      expect(const PlanDuration().estimateSeconds(plan, catalog), 175);
    },
  );

  test(
    'confirmed non-main work and every block round remain locked during fit',
    () {
      final catalog = Catalog(
        version: 'locked',
        drills: [
          _drill(
            'warmup',
            mode: DoseMode.reps,
            amount: 50,
            workRange: const IntRange(20, 50),
          ),
          _drill('main', amount: 150, workRange: const IntRange(80, 150)),
          _drill('cooldown'),
        ],
      );
      final result =
          PlanBuilder(
            _profile(rounds: const IntRange(1, 6)),
            catalog,
            minPicks: 3,
          ).draft(
            _ready(
              catalog,
              4,
              dose: [
                {'field': 'reps', 'value': 25, 'actionId': 'warmup'},
                for (var index = 1; index <= 3; index++)
                  {'field': 'rounds', 'value': 1, 'blockId': 'b$index'},
              ],
            ),
            _threeBlocks(),
            newPlanId: 'locked',
          );
      final plan = _saved(result);
      _withinTarget(plan, catalog, 4);
      expect(plan.items.first.reps, 25);
      expect(plan.blocks.map((block) => block.rounds), everyElement(1));
      expect(plan.items.elementAt(1).workSeconds, lessThan(140));
    },
  );

  test(
    'an interior integer-dose gap cannot publish its nearest approximation',
    () {
      final catalog = Catalog(
        version: 'gap',
        drills: [_drill('a', amount: 100)],
      );
      final state = _ready(catalog, 3);
      final result =
          PlanBuilder(
            _profile(rounds: const IntRange(1, 2)),
            catalog,
            minPicks: 1,
          ).draft(state, {
            'title': 'Integer gap',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  {'id': 'a'},
                ],
              },
            ],
          }, newPlanId: 'gap');
      // The legal durations are 110 and 225 seconds. Their enclosing interval
      // contains 180, but neither discrete choice is within the delivery gate.
      expect(result.planId, isNull);
      expect(result.state, same(state));
      expect(result.error != null || result.feasibility != null, isTrue);
      expect(result.state.plans, isEmpty);
    },
  );

  for (final (minutes, reason) in [
    (1, 'minimum_exceeds_target'),
    (60, 'maximum_below_target'),
  ]) {
    test('proven bound $reason retains the user-choice outcome', () {
      final catalog = Catalog(
        version: 'bounds',
        drills: [_drill('a', amount: 100)],
      );
      final state = _ready(catalog, minutes);
      final result =
          PlanBuilder(
            _profile(rounds: const IntRange(1, 2)),
            catalog,
            minPicks: 1,
          ).draft(state, {
            'title': 'Bound',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  {'id': 'a'},
                ],
              },
            ],
          }, newPlanId: 'bound');
      expect(result.ok, isTrue);
      expect(result.planId, isNull);
      expect(result.state, same(state));
      expect(result.feasibility!['reason'], reason);
    });
  }
}
