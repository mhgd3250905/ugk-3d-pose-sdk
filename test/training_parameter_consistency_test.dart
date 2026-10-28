import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  CoachSessionState stateFor(CoachContext context, {CoachProfile? using}) {
    final params = SessionParams(ActionTags(using ?? profile, catalog));
    final host = params.applyHost(CoachSessionState(), context);
    expect(host.ok, isTrue, reason: '${host.error}');
    final goal = params.set(host.state, {
      'fields': {
        'goal': {
          'value': ['purpose.stretch'],
          'source': 'default',
        },
      },
    });
    expect(goal.ok, isTrue, reason: '${goal.error}');
    return goal.state;
  }

  PlanCheckResult review(
    TrainingPlan plan,
    CoachContext context, {
    CoachProfile? using,
  }) => PlanChecker(
    using ?? profile,
    catalog,
    minPicks: 3,
  ).validateTemplate(stateFor(context, using: using), plan);

  const confirmed = CoachContext(
    scene: 'home',
    equipment: {'mat', 'chair'},
    minutes: 10,
  );

  test(
    'structured equipment edits preserve, replace or remove previous gear',
    () {
      final params = SessionParams(ActionTags(profile, catalog));
      const previous = CoachContext(
        scene: 'home',
        equipment: {'mat'},
        minutes: 10,
      );
      CoachSessionState edit(
        String message,
        List<String> equipment, [
        CoachContext context = previous,
      ]) {
        final state = params.applyHost(CoachSessionState(), context).state;
        final updated = params.set(state.appendUserTurn(message), {
          'fields': {
            'equipment': {
              'value': equipment,
              'source': 'user',
              'quote': message,
            },
          },
        });
        expect(updated.ok, isTrue, reason: '${updated.error}');
        expect(updated.state.params['equipment']!.source, 'user');
        expect(updated.state.params['equipment']!.quote, message);
        return updated.state;
      }

      for (final message in ['增加椅子', '再加椅子', '把这套计划加上椅子']) {
        final updated = edit(message, ['equip.mat', 'equip.chair']);
        expect(updated.params['equipment']!.value, [
          'equip.mat',
          'equip.chair',
        ]);
        expect(updated.params['scene']!.value, 'home');
        expect(updated.params['minutes']!.value, 10);
      }
      for (final message in ['改成椅子', '只用椅子']) {
        expect(edit(message, ['equip.chair']).params['equipment']!.value, [
          'equip.chair',
        ], reason: message);
      }
      expect(
        edit('不用椅子', ['equip.mat'], confirmed).params['equipment']!.value,
        ['equip.mat'],
      );
      expect(
        edit('没有瑜伽垫', ['equip.chair'], confirmed).params['equipment']!.value,
        ['equip.chair'],
      );
      expect(edit('瑜伽垫不用了，再加椅子', ['equip.chair']).params['equipment']!.value, [
        'equip.chair',
      ]);
      final unknown = CoachSessionState().appendUserTurn('不用椅子');
      expect(unknown.params.containsKey('equipment'), isFalse);
    },
  );

  TrainingPlan makePlan({int minutes = 10, List<String>? equipment}) {
    final json = planOf(okEnvelope())
      ..['targetMinutes'] = minutes
      ..['equipment'] = equipment ?? ['mat'];
    return const PlanCodec().decode(json);
  }

  test(
    'checking does not relabel a template dose and leaves actual refitting to delivery',
    () {
      final baseline = review(makePlan(), confirmed);
      expect(baseline.ok, isTrue, reason: '${baseline.errors}');
      final mismatch = makePlan(minutes: 15);
      final checked = review(mismatch, confirmed);
      expect(checked.ok, isTrue, reason: '${checked.errors}');
      final conditions = checked.rules['card_conditions'] as Map;
      expect(conditions['ok'], isTrue);
      expect((conditions['expected'] as Map)['targetMinutes'], 10);
      expect((conditions['actual'] as Map)['targetMinutes'], 15);
      // Only the target label changed; actual dose and estimated duration did not.
      expect(
        const PlanDuration().estimateSeconds(mismatch, catalog),
        const PlanDuration().estimateSeconds(makePlan(), catalog),
      );
      expect(checked.state.plans[mismatch.id]!.last.plan['targetMinutes'], 15);
    },
  );

  test(
    'plan gear may be a subset but explicitly excluded gear is rejected',
    () {
      final subset = review(makePlan(equipment: ['mat']), confirmed);
      expect(subset.ok, isTrue, reason: '${subset.errors}');
      final declaration = review(
        makePlan(equipment: ['mat', 'dumbbell']),
        confirmed,
      );
      expect(declaration.ok, isTrue);
      expect((declaration.rules['card_conditions'] as Map)['ok'], isTrue);
      expect(declaration.state.plans.values.single.last.plan['equipment'], [
        'mat',
      ]);
      final source = stateFor(
        const CoachContext(scene: 'home', equipment: {'chair'}, minutes: 10),
      ).appendUserTurn('这次不用瑜伽垫');
      final excluded = SessionParams(ActionTags(profile, catalog)).set(source, {
        'fields': {
          'equipment_exclude': {
            'value': ['equip.mat'],
            'source': 'user',
            'quote': '不用瑜伽垫',
          },
        },
      });
      expect(excluded.ok, isTrue, reason: '${excluded.error}');
      final missing = PlanChecker(
        profile,
        catalog,
        minPicks: 3,
      ).validateTemplate(excluded.state, makePlan());
      expect(missing.ok, isFalse);
      expect(
        (missing.rules['equipment'] as Map)['actual'],
        contains('equip.mat'),
      );
    },
  );

  test(
    'unknown parameters stay unknown and cannot silently authorize a plan',
    () {
      final state = CoachSessionState().appendUserTurn('随便看看');
      final before = state.toJson();
      final checked = PlanChecker(profile, catalog, minPicks: 3)
          .validateTemplate(
            state,
            makePlan(minutes: 15, equipment: ['mat', 'dumbbell']),
          );
      expect(checked.error!['code'], 'missing_parameters');
      expect(checked.state.params, isEmpty);
      expect(state.toJson(), before);
    },
  );

  test('equipment metadata exactly matches actual catalog needs', () {
    for (final declared in [
      <String>[],
      ['mat', 'chair'],
    ]) {
      final checked = review(makePlan(equipment: declared), confirmed);
      final conditions = checked.rules['card_conditions'] as Map;
      expect(conditions['ok'], isTrue);
      expect(conditions['normalized'], isTrue);
      expect((conditions['expected'] as Map)['equipment'], ['mat']);
      expect((conditions['actual'] as Map)['equipment'], ['mat']);
      expect(checked.state.plans.values.single.last.plan['equipment'], ['mat']);
    }
  });

  test('segments rather than the parent represent performed equipment', () {
    final original = makePlan();
    final candidate = TrainingPlan(
      id: original.id,
      source: original.source,
      title: original.title,
      summary: original.summary,
      goal: original.goal,
      scene: original.scene,
      level: original.level,
      targetMinutes: original.targetMinutes,
      equipment: const [],
      blocks: [
        PlanBlock(
          id: 'b',
          name: 'main',
          type: BlockType.main,
          items: [
            PlanItem(
              // This parent needs a mat but is not the performed segment.
              exerciseId: 'n-windshield',
              mode: DoseMode.reps,
              sets: 1,
              reps: 8,
              perSide: false,
              restSeconds: 0,
              segments: const [
                PlanSegment(
                  id: 's',
                  exerciseId: 'h-squat',
                  mode: DoseMode.reps,
                  reps: 8,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    expect(
      (review(candidate, confirmed).rules['card_conditions'] as Map)['ok'],
      isTrue,
    );
  });

  test('office chair and wall are both reflected in the actual equipment', () {
    final smartfit = loadProfile('smartfit');
    const office = CoachContext(
      scene: 'office',
      equipment: {'chair', 'wall'},
      minutes: 10,
    );
    TrainingPlan officePlan(List<String> equipment) => TrainingPlan(
      id: 'office-stretch',
      source: 'template',
      title: '办公室拉伸',
      summary: '舒展身体',
      goal: 'relax',
      scene: 'office',
      equipment: equipment,
      level: 1,
      targetMinutes: 10,
      blocks: const [
        PlanBlock(
          id: 'b',
          name: '拉伸',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: 'h-chair-lat',
              mode: DoseMode.time,
              sets: 2,
              workSeconds: 120,
              perSide: false,
              restSeconds: 30,
            ),
            PlanItem(
              exerciseId: 'h-wall-calf',
              mode: DoseMode.time,
              sets: 1,
              workSeconds: 120,
              perSide: true,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    );
    final matching = review(
      officePlan(['chair', 'wall']),
      office,
      using: smartfit,
    );
    expect((matching.rules['equipment'] as Map)['ok'], isTrue);
    expect((matching.rules['card_conditions'] as Map)['ok'], isTrue);
    final missing = review(officePlan(['chair']), office, using: smartfit);
    expect((missing.rules['card_conditions'] as Map)['ok'], isTrue);
    expect((missing.rules['card_conditions'] as Map)['normalized'], isTrue);
    expect(
      ((missing.rules['card_conditions'] as Map)['expected']
          as Map)['equipment'],
      ['chair', 'wall'],
    );
  });

  test(
    'selected equipment is preferred, not forced into an unsuitable plan',
    () {
      final original = makePlan();
      final candidate = TrainingPlan(
        id: original.id,
        source: original.source,
        title: original.title,
        summary: original.summary,
        goal: original.goal,
        scene: original.scene,
        level: original.level,
        targetMinutes: original.targetMinutes,
        equipment: const [],
        blocks: const [
          PlanBlock(
            id: 'b',
            name: 'main',
            type: BlockType.main,
            items: [
              PlanItem(
                exerciseId: 'h-squat',
                mode: DoseMode.reps,
                sets: 1,
                reps: 8,
                perSide: false,
                restSeconds: 0,
              ),
            ],
          ),
        ],
      );
      expect(
        (review(candidate, confirmed).rules['equipment'] as Map)['ok'],
        isTrue,
      );
      expect(
        (review(candidate, confirmed).rules['card_conditions'] as Map)['ok'],
        isTrue,
      );
    },
  );

  test(
    'the model records accepted defaults explicitly without parsing text',
    () {
      final params = SessionParams(ActionTags(profile, catalog));
      final state = CoachSessionState().appendUserTurn('按默认来');
      expect(state.params, isEmpty);
      final defaults = params.set(state, {
        'fields': {
          'scene': {'value': profile.defaultScene, 'source': 'default'},
          'equipment': {'value': <String>[], 'source': 'default'},
          'minutes': {'value': 15, 'source': 'default'},
        },
      });
      expect(defaults.ok, isTrue, reason: '${defaults.error}');
      expect(defaults.state.params['equipment']!.value, isEmpty);
      expect(defaults.state.params['minutes']!.value, 15);
      for (final value in defaults.state.params.values) {
        expect(value.source, 'default');
      }
    },
  );

  test(
    'new structured scene minutes and equipment override old host values',
    () {
      final smartfit = loadProfile('smartfit');
      final params = SessionParams(ActionTags(smartfit, catalog));
      var state = stateFor(confirmed, using: smartfit);
      state = state.appendUserTurn('改为办公室，徒手，5分钟');
      final changed = params.set(state, {
        'fields': {
          'scene': {'value': 'office', 'source': 'user', 'quote': '办公室'},
          'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
          'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
        },
      });
      expect(changed.ok, isTrue, reason: '${changed.error}');
      expect(changed.state.params['scene']!.value, 'office');
      expect(changed.state.params['minutes']!.value, 5);
      expect(changed.state.params['equipment']!.value, isEmpty);
      final oldPlan = PlanChecker(
        smartfit,
        catalog,
        minPicks: 3,
      ).validateTemplate(changed.state, makePlan());
      expect(oldPlan.ok, isFalse);
      expect((oldPlan.rules['card_conditions'] as Map)['ok'], isTrue);
      // The new office scene does not allow the old home mat: both actual
      // scene and equipment restrictions remain hard.
      expect((oldPlan.rules['equipment'] as Map)['ok'], isFalse);
      expect(oldPlan.errors.map((e) => e['code']), contains(IssueCodes.scene));
    },
  );
}
