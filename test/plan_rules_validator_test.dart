import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/plan/training_plan.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

import 'support.dart';

void main() {
  final real = loadCatalog();
  final name = real.drills.first.name;
  Drill drill(
    String id,
    String category,
    String muscle, {
    List<String> equipment = const [],
    List<String> cautions = const [],
    List<String> contraindications = const [],
  }) => Drill(
    id: id,
    name: name,
    category: category,
    muscleGroups: [muscle],
    equipment: equipment,
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
      seconds: IntRange(10, 120),
      restSeconds: IntRange(0, 180),
    ),
    cautions: cautions,
    contraindications: contraindications,
  );
  final catalog = Catalog(
    version: 'test',
    taxonomy: real.taxonomy,
    drills: [
      drill('ad-stretch', 'stretch', 'adductors'),
      drill('ad-mobility', 'mobility', 'adductors'),
      drill('abs-stretch', 'stretch', 'abs'),
      drill('chest-strength', 'strength', 'chest'),
      drill('knee-risk', 'strength', 'quadriceps', cautions: ['膝']),
      drill('mat-stretch', 'stretch', 'abs', equipment: ['mat']),
      drill('shoulder-risk', 'strength', 'chest', contraindications: ['肩']),
    ],
  );
  const defaultProfile = CoachProfile(id: 'test', appName: 'test');
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  PlanItem item(String id, [int seconds = 60]) => PlanItem(
    exerciseId: id,
    mode: DoseMode.time,
    sets: 1,
    workSeconds: seconds,
    perSide: false,
    restSeconds: 0,
  );
  PlanBlock block(BlockType type, List<PlanItem> items) =>
      PlanBlock(id: type.name, name: type.name, type: type, items: items);
  CoachSessionState session({
    required List<PlanBlock> blocks,
    List<String> goals = const ['purpose.stretch'],
    List<String> equipment = const [],
    List<String> limits = const [],
    int minutes = 4,
    int? planMinutes,
    List<String> planEquipment = const [],
    String id = 'p',
    Map<String, Object?>? existingCheck,
    Map<String, Object?> hostValues = const {},
  }) {
    final plan = TrainingPlan(
      id: id,
      source: 'ai',
      title: '计划',
      summary: '计划',
      goal: 'relax',
      scene: 'home',
      level: 1,
      targetMinutes: planMinutes ?? minutes,
      equipment: planEquipment,
      blocks: blocks,
    );
    return CoachSessionState(
      task: CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: [
          const CoachNodeState(id: 'understand', status: 'done'),
          const CoachNodeState(id: 'parameters', status: 'done'),
          const CoachNodeState(id: 'actions', status: 'done'),
          const CoachNodeState(
            id: 'planning',
            status: 'done',
            stamp: '旧规划',
            doneAtTurn: 1,
          ),
          const CoachNodeState(id: 'review', status: 'current'),
          const CoachNodeState(id: 'output', status: 'pending'),
        ],
      ),
      params: {
        'scene': param('home'),
        'goal': param(goals),
        'equipment': param(equipment),
        'limits': param(limits),
        'minutes': param(minutes),
        'level': param(1),
      },
      seenActionIds: catalog.ids.toSet(),
      picks: catalog.ids.toList(),
      activePlanId: id,
      hostValues: hostValues,
      plans: {
        id: [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: const PlanDuration().estimateSeconds(plan, catalog),
            fitLog: const [],
            check: existingCheck,
          ),
        ],
      },
    );
  }

  PlanCheckResult check(
    CoachSessionState s, [
    CoachProfile profile = defaultProfile,
  ]) => PlanChecker(profile, catalog, minPicks: 3).check(s, 'p');
  Map<String, Object?> rule(PlanCheckResult result, String name) =>
      result.rules[name]! as Map<String, Object?>;
  List<PlanBlock> main(List<String> ids) => [
    block(BlockType.main, [for (final id in ids) item(id)]),
  ];

  test(
    'body, purpose and dual goals each have separate passing and failing checks',
    () {
      final cases =
          <({List<String> goals, List<String> ids, bool? body, bool? purpose})>[
            (
              goals: ['body.inner_thigh'],
              ids: ['ad-mobility', 'abs-stretch'],
              body: true,
              purpose: null,
            ),
            (
              goals: ['body.inner_thigh'],
              ids: ['abs-stretch', 'chest-strength'],
              body: false,
              purpose: null,
            ),
            (
              goals: ['purpose.stretch'],
              ids: ['ad-stretch', 'chest-strength'],
              body: null,
              purpose: true,
            ),
            (
              goals: ['purpose.stretch'],
              ids: ['ad-mobility', 'chest-strength'],
              body: null,
              purpose: false,
            ),
            (
              goals: ['body.inner_thigh', 'purpose.stretch'],
              ids: ['ad-mobility', 'abs-stretch'],
              body: true,
              purpose: true,
            ),
            (
              goals: ['body.inner_thigh', 'purpose.stretch'],
              ids: ['ad-mobility', 'chest-strength'],
              body: true,
              purpose: false,
            ),
            (
              goals: ['body.inner_thigh', 'purpose.stretch'],
              ids: ['abs-stretch', 'chest-strength'],
              body: false,
              purpose: true,
            ),
          ];
      for (final c in cases) {
        final result = check(session(blocks: main(c.ids), goals: c.goals));
        if (c.body == null) {
          expect(result.rules.containsKey('focus_body'), isFalse);
        } else {
          expect(rule(result, 'focus_body')['ok'], c.body);
          expect(rule(result, 'focus_body')['actual'], c.body! ? '1/2' : '0/2');
        }
        if (c.purpose == null) {
          expect(result.rules.containsKey('focus_purpose'), isFalse);
        } else {
          expect(rule(result, 'focus_purpose')['ok'], c.purpose);
          expect(
            rule(result, 'focus_purpose')['actual'],
            c.purpose! ? '1/2' : '0/2',
          );
        }
      }
    },
  );

  test('focus uses only main items and candidates are seen and compatible', () {
    final s = session(
      blocks: [
        block(BlockType.warmup, [item('ad-stretch')]),
        block(BlockType.main, [item('chest-strength')]),
      ],
      goals: ['purpose.stretch'],
    );
    final result = check(s);
    expect(rule(result, 'focus_purpose')['actual'], '0/1');
    final error = result.errors.singleWhere(
      (e) => e['code'] == 'plan_focus_purpose',
    );
    expect(error['candidates'], contains('abs-stretch'));
    expect(error['candidates'], isNot(contains('mat-stretch')));
    expect(error['expected'], contains('purpose.stretch'));
  });

  test('safety honors canonical host limit and contraindications', () {
    final safe = check(
      session(blocks: main(['ad-stretch']), limits: ['limit.knee']),
    );
    expect(rule(safe, 'safety')['ok'], isTrue);
    final knee = check(
      session(blocks: main(['knee-risk']), limits: ['limit.knee']),
    );
    expect(rule(knee, 'safety')['ok'], isFalse);
    final shoulder = check(
      session(blocks: main(['shoulder-risk']), limits: ['limit.shoulder']),
    );
    expect(rule(shoulder, 'safety')['ok'], isFalse);
  });

  test('equipment uses catalogue needs rather than plan declaration', () {
    expect(
      rule(
        check(session(blocks: main(['mat-stretch']), equipment: ['equip.mat'])),
        'equipment',
      )['ok'],
      isTrue,
    );
    expect(
      rule(check(session(blocks: main(['mat-stretch']))), 'equipment')['ok'],
      isFalse,
    );
  });

  test('duration checks unrounded seconds at the ten percent boundary', () {
    final pass = session(
      blocks: [
        block(BlockType.main, [
          item('ad-stretch', 75),
          item('ad-mobility', 75),
          item('abs-stretch', 74),
        ]),
      ],
    );
    final fail = session(
      blocks: [
        block(BlockType.main, [
          item('ad-stretch', 75),
          item('ad-mobility', 75),
          item('abs-stretch', 75),
        ]),
      ],
    );
    expect(rule(check(pass), 'duration')['actual'], 264);
    expect(rule(check(pass), 'duration')['ok'], isTrue);
    expect(rule(check(fail), 'duration')['actual'], 265);
    expect(rule(check(fail), 'duration')['ok'], isFalse);
  });

  test('structure follows duration thresholds and pure stretch exemption', () {
    final withBoth = session(
      minutes: 10,
      goals: ['purpose.strength'],
      blocks: [
        block(BlockType.warmup, [item('ad-stretch')]),
        ...main(['chest-strength']),
        block(BlockType.cooldown, [item('abs-stretch')]),
      ],
    );
    expect(rule(check(withBoth), 'structure')['ok'], isTrue);
    final missing = session(
      minutes: 10,
      goals: ['purpose.strength'],
      blocks: main(['chest-strength']),
    );
    expect(rule(check(missing), 'structure')['ok'], isFalse);
    final pure = session(
      minutes: 10,
      goals: ['purpose.stretch', 'body.inner_thigh'],
      blocks: [
        ...main(['ad-stretch']),
        block(BlockType.cooldown, [item('abs-stretch')]),
      ],
    );
    expect(rule(check(pure), 'structure')['ok'], isTrue);
    final mixed = session(
      minutes: 10,
      goals: ['purpose.stretch', 'purpose.strength'],
      blocks: [
        ...main(['ad-stretch']),
        block(BlockType.cooldown, [item('abs-stretch')]),
      ],
    );
    expect(rule(check(mixed), 'structure')['ok'], isFalse);
  });

  test(
    'balance rejects duplicates, long runs and missing configured antagonist',
    () {
      expect(
        rule(
          check(
            session(
              blocks: main(['ad-stretch', 'abs-stretch', 'chest-strength']),
            ),
          ),
          'balance',
        )['ok'],
        isTrue,
      );
      expect(
        rule(
          check(session(blocks: main(['ad-stretch', 'ad-stretch']))),
          'balance',
        )['ok'],
        isFalse,
      );
      final strict = CoachProfile(
        id: 'test',
        appName: 'test',
        planRules: const PlanRules(maxSameMuscleInRow: 1),
      );
      expect(
        rule(
          check(session(blocks: main(['ad-stretch', 'ad-mobility'])), strict),
          'balance',
        )['ok'],
        isFalse,
      );
      final pairs = CoachProfile(
        id: 'test',
        appName: 'test',
        planRules: const PlanRules(
          antagonisticPairs: [
            AntagonistPair(first: ['body.abs'], second: ['body.chest']),
          ],
        ),
      );
      expect(
        rule(
          check(
            session(blocks: main(['abs-stretch', 'chest-strength'])),
            pairs,
          ),
          'balance',
        )['ok'],
        isTrue,
      );
      expect(
        rule(
          check(session(blocks: main(['abs-stretch', 'ad-stretch'])), pairs),
          'balance',
        )['ok'],
        isFalse,
      );
    },
  );

  test(
    'only latest active version is checked and stale successful result is replaced',
    () {
      final s = session(
        blocks: main(['knee-risk']),
        limits: ['limit.knee'],
        existingCheck: {'ok': true},
      );
      final result = check(s);
      expect(result.ok, isFalse);
      expect(result.state.plans['p']!.last.check!['ok'], isFalse);
      expect(s.plans['p']!.last.check!['ok'], isTrue);
      expect(
        PlanChecker(
          defaultProfile,
          catalog,
          minPicks: 3,
        ).check(s, 'another').error!['code'],
        'invalid_plan_id',
      );
      expect(result.toJson()['errors'], isNotEmpty);
    },
  );

  test('unknown host limits produce an explicit data-gap warning', () {
    final code = 'limit.u_1234';
    final result = check(
      session(
        blocks: main(['ad-stretch']),
        limits: [code],
        hostValues: {
          'limitsOpaque': [code],
        },
      ),
    );
    expect(result.warnings.single, contains('不能确认其安全性'));
    expect(result.state.params['limits']!.value, [code]);
  });

  test('a valid plan records all checks while returning a concise success', () {
    final result = check(
      session(blocks: main(['ad-stretch', 'abs-stretch', 'chest-strength'])),
    );
    expect(result.ok, isTrue, reason: '${result.errors}');
    expect(result.toJson().keys, containsAll(['ok', 'summary']));
    expect(result.toJson().containsKey('rules'), isFalse);
    expect(result.state.plans['p']!.last.check!['rules'], isNotEmpty);
  });

  test('invalid const planRules invalidate any older successful check', () {
    final source = session(
      blocks: main(['ad-stretch']),
      existingCheck: {'ok': true},
    );
    for (final rules in [
      const PlanRules(focusRatio: -0.1),
      const PlanRules(focusRatio: 1.1),
      const PlanRules(warmupFromMinutes: -1),
      const PlanRules(cooldownFromMinutes: -1),
      const PlanRules(maxSameMuscleInRow: 0),
      const PlanRules(
        antagonisticPairs: [
          AntagonistPair(first: [], second: ['body.chest']),
        ],
      ),
    ]) {
      final profile = CoachProfile(
        id: 'test',
        appName: 'test',
        planRules: rules,
      );
      final result = check(source, profile);
      expect(result.error!['code'], 'invalid_plan_rules');
      expect(result.state.plans['p']!.last.check!['ok'], isFalse);
    }
  });

  test('segment actions are checked for safety and equipment', () {
    const parent = PlanItem(
      exerciseId: 'ad-stretch',
      mode: DoseMode.time,
      sets: 1,
      workSeconds: 60,
      perSide: false,
      restSeconds: 0,
      segments: [
        PlanSegment(
          id: 'part1',
          exerciseId: 'knee-risk',
          mode: DoseMode.time,
          workSeconds: 60,
        ),
        PlanSegment(
          id: 'part2',
          exerciseId: 'mat-stretch',
          mode: DoseMode.time,
          workSeconds: 60,
        ),
      ],
    );
    final result = check(
      session(
        blocks: [
          block(BlockType.main, [parent]),
        ],
        limits: ['limit.knee'],
      ),
    );
    expect(rule(result, 'safety')['ok'], isFalse);
    expect(rule(result, 'equipment')['ok'], isFalse);
  });

  test('card conditions match requested time and actual equipment', () {
    final valid = session(
      blocks: main(['mat-stretch']),
      equipment: ['equip.mat'],
      planEquipment: ['mat'],
    );
    expect(rule(check(valid), 'card_conditions')['ok'], isTrue);
    final wrongTime = session(
      blocks: main(['mat-stretch']),
      equipment: ['equip.mat'],
      planEquipment: ['mat'],
      planMinutes: 10,
    );
    expect(rule(check(wrongTime), 'card_conditions')['ok'], isFalse);
    final missingGear = session(
      blocks: main(['mat-stretch']),
      equipment: ['equip.mat'],
    );
    expect(rule(check(missingGear), 'card_conditions')['ok'], isFalse);
    final extraGear = session(
      blocks: main(['ad-stretch']),
      equipment: ['equip.mat'],
      planEquipment: ['mat'],
    );
    expect(rule(check(extraGear), 'card_conditions')['ok'], isFalse);
  });

  test(
    'failed check returns to planning and repaired version can be checked',
    () {
      final original = session(
        blocks: main(['knee-risk']),
        limits: ['limit.knee'],
      );
      final failed = check(original);
      expect(failed.ok, isFalse);
      expect(failed.changes.map((n) => '${n.id}:${n.status}'), [
        'planning:current',
        'review:pending',
      ]);
      expect(failed.changes.first.stamp, isNull);
      expect(failed.state.plans['p']!.last.check!['ok'], isFalse);
      final draft = PlanBuilder(defaultProfile, catalog, minPicks: 3).draft(
        failed.state,
        {
          'plan_id': 'p',
          'title': '重新编排',
          'blocks': [
            {
              'kind': 'main',
              'items': [
                {'id': 'ad-stretch'},
                {'id': 'abs-stretch'},
                {'id': 'chest-strength'},
              ],
            },
          ],
        },
        newPlanId: 'unused',
      );
      expect(draft.ok, isTrue, reason: '${draft.error}');
      expect(draft.version, 2);
      final planning = NodeGates(
        defaultProfile,
        catalog,
        minPicks: 3,
      ).check(draft.state, 'planning');
      expect(planning.ok, isTrue, reason: '${planning.error}');
      final reviewed = check(planning.state);
      expect(reviewed.ok, isTrue, reason: '${reviewed.errors}');
      expect(reviewed.state.plans['p']!.last.version, 2);
      expect(reviewed.state.plans['p']!.last.check!['ok'], isTrue);
      expect(reviewed.changes, isEmpty);
    },
  );
}
