import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final source = loadCatalog();
  Drill drill(
    String id,
    String category,
    List<String> bodies, {
    List<String> cautions = const [],
    List<String> scenes = const ['home'],
  }) => Drill(
    id: id,
    name: LocalizedText({'zh': '测试$id', 'en': 'Test $id'}),
    category: category,
    muscleGroups: bodies,
    position: 'standing',
    unilateral: false,
    level: 1,
    scenes: scenes,
    cautions: cautions,
    defaultDose: const Dose(
      mode: DoseMode.time,
      sets: 1,
      seconds: 25,
      restSeconds: 0,
    ),
  );
  final catalog = Catalog(
    version: 'test',
    taxonomy: source.taxonomy,
    drills: [
      drill('shoulder-secondary', 'strength', ['chest', 'deltoids']),
      drill('shoulder-primary', 'strength', ['deltoids']),
      drill('core-secondary', 'strength', ['rotator-cuff', 'abs']),
      drill('core-primary', 'strength', ['erectors']),
      drill('other1', 'strength', ['quadriceps']),
      drill('other2', 'strength', ['hamstrings']),
      for (final category in ['stretch', 'mobility', 'breath', 'activation'])
        drill('prep-$category', category, ['chest']),
      drill('relax', 'stretch', ['obliques']),
      drill('stretch-shoulder', 'stretch', ['deltoids']),
      drill('unsafe-relax', 'stretch', ['quadriceps'], cautions: ['膝']),
      drill('wrong-scene-relax', 'stretch', ['calves'], scenes: ['office']),
      drill('not-seen-relax', 'stretch', ['lats']),
    ],
  );
  CoachProfile profile(double ratio) => CoachProfile(
    id: 'test',
    appName: 'test',
    bodyGroups: const {
      'body.core': ['body.abs', 'body.obliques', 'body.erectors'],
    },
    planRules: PlanRules(focusRatio: ratio),
  );
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  PlanItem item(String id) => PlanItem(
    exerciseId: id,
    mode: DoseMode.time,
    sets: 1,
    workSeconds: 25,
    perSide: false,
    restSeconds: 0,
  );
  CoachSessionState state(
    Catalog c,
    List<String> mains, {
    String? warmup,
    String? cooldown,
    List<String> goals = const ['body.deltoids'],
    Set<String>? seen,
  }) {
    final plan = TrainingPlan(
      id: 'test',
      source: 'ai',
      title: 'Test',
      summary: 'Test',
      goal: 'strength',
      scene: 'home',
      level: 1,
      targetMinutes: 4,
      equipment: const [],
      blocks: [
        if (warmup != null)
          PlanBlock(
            id: 'warmup',
            name: 'warmup',
            type: BlockType.warmup,
            items: [item(warmup)],
          ),
        PlanBlock(
          id: 'main',
          name: 'main',
          type: BlockType.main,
          items: [for (final id in mains) item(id)],
        ),
        if (cooldown != null)
          PlanBlock(
            id: 'cooldown',
            name: 'cooldown',
            type: BlockType.cooldown,
            items: [item(cooldown)],
          ),
      ],
    );
    return CoachSessionState(
      task: CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: const [
          CoachNodeState(id: 'understand', status: 'done'),
          CoachNodeState(id: 'parameters', status: 'done'),
          CoachNodeState(id: 'actions', status: 'done'),
          CoachNodeState(id: 'planning', status: 'done'),
          CoachNodeState(id: 'review', status: 'current'),
          CoachNodeState(id: 'output', status: 'pending'),
        ],
      ),
      params: {
        'scene': param('home'),
        'equipment': param(<String>[]),
        'minutes': param(4),
        'goal': param(goals),
        'limits': param(['limit.knee']),
      },
      seenActionIds: seen ?? c.ids.toSet(),
      activePlanId: 'test',
      plans: {
        'test': [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: 0,
            fitLog: const [],
          ),
        ],
      },
    );
  }

  PlanCheckResult check(
    CoachSessionState s, {
    double ratio = .5,
    Catalog? actual,
  }) => PlanChecker(
    profile(ratio),
    actual ?? catalog,
    minPicks: 3,
  ).check(s, 'test');
  Map<String, Object?> rule(PlanCheckResult result, String name) =>
      result.rules[name] as Map<String, Object?>;
  const shoulders = [
    'shoulder-secondary',
    'other1',
    'shoulder-primary',
    'other2',
  ];
  const cores = ['core-secondary', 'other1', 'core-primary', 'other2'];

  test(
    'main body focus counts secondary muscles and parent-child codes, exactly half passes',
    () {
      for (final goalsAndIds in [
        (['body.deltoids'], shoulders),
        (['body.core'], cores),
      ]) {
        final result = check(
          state(catalog, goalsAndIds.$2, goals: goalsAndIds.$1),
        );
        expect(rule(result, 'focus_body')['ok'], isTrue);
        expect(rule(result, 'focus_body')['actual'], '2/4');
        expect(
          result.errors.where((e) => e['code'] == 'plan_focus_body'),
          isEmpty,
        );
      }
    },
  );
  test(
    'body focus has a hard half floor while stricter profiles remain stricter',
    () {
      final quarter = check(
        state(catalog, [
          'shoulder-secondary',
          'other1',
          'other2',
          'core-primary',
        ]),
        ratio: .25,
      );
      expect(rule(quarter, 'focus_body')['ok'], isFalse);
      expect(rule(quarter, 'focus_body')['expected'], contains('50%'));
      expect(rule(quarter, 'focus_body')['actual'], '1/4');
      expect(
        rule(check(state(catalog, shoulders), ratio: .75), 'focus_body')['ok'],
        isFalse,
      );
      final strict = check(
        state(catalog, [
          'shoulder-secondary',
          'shoulder-primary',
          'stretch-shoulder',
          'other1',
        ]),
        ratio: .75,
      );
      expect(rule(strict, 'focus_body')['ok'], isTrue);
      expect(rule(strict, 'focus_body')['actual'], '3/4');
    },
  );
  test(
    'purpose-only focus keeps its configured semantics and dual goals remain separate',
    () {
      final purpose = check(
        state(
          catalog,
          ['stretch-shoulder', 'other1', 'other2', 'core-primary'],
          goals: ['purpose.stretch'],
        ),
        ratio: .25,
      );
      expect(rule(purpose, 'focus_purpose')['ok'], isTrue);
      expect(purpose.rules.containsKey('focus_body'), isFalse);
      final dual = check(
        state(catalog, shoulders, goals: ['body.deltoids', 'purpose.stretch']),
      );
      expect(rule(dual, 'focus_body')['ok'], isTrue);
      expect(rule(dual, 'focus_purpose')['ok'], isFalse);
    },
  );
  test('all four allowed catalogue purposes can serve warmup and cooldown', () {
    for (final category in ['stretch', 'mobility', 'breath', 'activation']) {
      final result = check(
        state(catalog, shoulders, warmup: 'prep-$category', cooldown: 'relax'),
      );
      expect(result.ok, isTrue, reason: '$category ${result.errors}');
      expect(rule(result, 'block_purpose')['ok'], isTrue);
    }
  });
  test(
    'unusual preparation emits a goal-aware advisory rather than a rejection',
    () {
      final result = check(
        state(
          catalog,
          shoulders,
          warmup: 'core-secondary',
          cooldown: 'relax',
          seen: {
            'prep-mobility',
            'unsafe-relax',
            'wrong-scene-relax',
            'core-secondary',
            'relax',
            ...shoulders,
          },
        ),
      );
      expect(result.ok, isTrue);
      final warning = result.warningDetails.singleWhere(
        (e) => e['code'] == 'plan_block_purpose',
      );
      expect(
        (warning['actual'] as List).single,
        containsPair('id', 'core-secondary'),
      );
      expect(result.errors, isEmpty);
    },
  );
  test(
    'real strength cooldown produces an advisory and does not impersonate a safety error',
    () {
      const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final published = PoseHubAppTestCatalog.fromBytes(
        File('$pack/catalog.json').readAsBytesSync(),
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      expect(published['h-db-front-raise']!.category, 'strength');
      final plan = state(
        published,
        [
          'forearms-A',
          'n-pelvis-circle',
          'o-stand-sidebend',
          'h-bilateral-upper-back-hug',
        ],
        warmup: 'forearms-A',
        cooldown: 'h-db-front-raise',
        goals: ['purpose.mobility'],
        seen: {'forearms-A', 'h-bilateral-upper-back-hug', 'h-db-front-raise'},
      );
      final withGear = plan.copyWith(
        params: {
          ...plan.params,
          'equipment': param(['equip.dumbbell']),
          'limits': param(<String>[]),
        },
      );
      final rejected = PlanChecker(
        loadProfile('smartfit'),
        published,
        minPicks: 3,
      ).check(withGear, 'test');
      final purpose = rejected.warningDetails.singleWhere(
        (e) => e['code'] == 'plan_block_purpose',
      );
      expect(purpose['actual'], [
        {
          'block': 2,
          'kind': 'cooldown',
          'id': 'h-db-front-raise',
          'purposes': ['purpose.strength'],
        },
      ]);
      expect(
        rejected.errors.any((e) => e['code'] == 'plan_block_purpose'),
        isFalse,
      );
    },
  );
}
