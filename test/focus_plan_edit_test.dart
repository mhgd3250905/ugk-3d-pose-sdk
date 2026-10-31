import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/output_gate.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

void main() {
  const profile = CoachProfile(
    id: 'focused-edit',
    appName: 'focused-edit',
    limits: PlanLimits(
      sets: IntRange(1, 6),
      rounds: IntRange(1, 2),
      restSeconds: IntRange(0, 30),
      restBetweenRoundsSeconds: IntRange(0, 30),
      reps: IntRange(1, 20),
      workSeconds: IntRange(10, 120),
    ),
  );
  const originalIds = ['one', 'two', 'three', 'four', 'five'];
  final catalog = Catalog(
    version: 'focus-edit',
    drills: [
      for (final id in [...originalIds, 'replacement', 'inserted'])
        Drill(
          id: id,
          name: LocalizedText({'en': id}),
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
        ),
    ],
  );
  final builder = PlanBuilder(profile, catalog, minPicks: 3);
  final gates = NodeGates(profile, catalog, minPicks: 3);
  const focusId = 'ext:B';
  const savedRef = CoachSavedPlanRef(externalId: 'B', baseVersion: 4);
  final saved = TrainingPlan(
    id: focusId,
    source: 'template',
    title: 'Saved B',
    summary: 'Current discussion plan',
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
          for (final id in originalIds)
            PlanItem(
              exerciseId: id,
              mode: DoseMode.time,
              sets: 2,
              workSeconds: 60,
              perSide: false,
              restSeconds: 0,
            ),
        ],
      ),
    ],
  );

  CoachSessionState focused() {
    CoachParamValue value(Object data) =>
        CoachParamValue(value: data, source: 'host', turn: 1);
    return CoachSessionState(
      userTurns: const [CoachUserTurn(turn: 2, text: '替换第3个动作')],
      params: {
        'minutes': value(10),
        'scene': value('home'),
        'goal': value(['body.abs']),
        'equipment': value(<String>[]),
        'limits': value(<String>[]),
      },
      seenActionIds: {...originalIds, 'replacement', 'inserted'},
      picks: originalIds,
      activePlanId: focusId,
      focusPlanId: focusId,
      savedRef: savedRef,
      // The previously delivered A must not become the edit baseline again.
      lastDeliveredPlanId: 'A',
      lastDeliveredVersion: 1,
      lastDeliveredTurn: 1,
      plans: {
        'A': [
          CoachPlanVersion(
            version: 1,
            plan: const {'id': 'A', 'title': 'Unrelated delivered A'},
            estimateSec: 1200,
            fitLog: const [],
            check: const {'ok': true},
          ),
        ],
        focusId: [
          CoachPlanVersion(
            version: 4,
            plan: saved.toJson(),
            estimateSec: 600,
            fitLog: const [],
            check: const {'ok': true},
          ),
        ],
      },
    );
  }

  Map<String, Object?> draft(List<String> ids) => {
    'plan_id': 'A',
    'title': 'Edited B',
    'blocks': [
      {
        'kind': 'main',
        'items': [
          for (final id in ids) {'id': id},
        ],
      },
    ],
  };

  CoachSessionState ready() => AgentTask.start(focused(), 'plan').state;

  List<String> actionIds(DraftResult result) => [
    for (final item
        in const PlanCodec()
            .decode(result.state.plans[focusId]!.last.plan)
            .items)
      item.exerciseId,
  ];

  CoachSessionState withPlan(TrainingPlan plan) {
    final initial = focused();
    return initial.copyWith(
      params: {
        ...initial.params,
        'minutes': CoachParamValue(
          value: plan.targetMinutes,
          source: 'host',
          turn: 1,
        ),
      },
      plans: {
        ...initial.plans,
        focusId: [
          CoachPlanVersion(
            version: 4,
            plan: plan.toJson(),
            estimateSec: const PlanDuration().estimateSeconds(plan, catalog),
            fitLog: const [],
          ),
        ],
      },
    );
  }

  TrainingPlan resultPlan(DraftResult result) =>
      const PlanCodec().decode(result.state.plans[focusId]!.last.plan);

  TrainingPlan repeatedPlan() => saved.copyWith(
    blocks: [
      PlanBlock(
        id: 'repeated-block',
        name: 'Repeated actions',
        type: BlockType.main,
        items: [
          const PlanItem(
            exerciseId: 'one',
            mode: DoseMode.time,
            sets: 3,
            workSeconds: 41,
            perSide: false,
            restSeconds: 7,
            note: 'First occurrence',
          ),
          const PlanItem(
            exerciseId: 'one',
            mode: DoseMode.time,
            sets: 1,
            workSeconds: 79,
            perSide: false,
            restSeconds: 11,
            note: 'Second occurrence',
          ),
          ...saved.items.skip(2),
        ],
      ),
    ],
  );

  Map<String, Object?> indexedDraft(List<Map<String, Object?>> items) => {
    'plan_id': focusId,
    'title': 'Edited repeated items',
    'blocks': [
      {'kind': 'main', 'items': items},
    ],
  };

  test(
    'new plan task preserves the explicit focus without repeating setup',
    () {
      final prior = focused();
      final result = AgentTask.start(prior, 'plan', reuse: false);
      expect(result.ok, isTrue);
      expect(result.state.activePlanId, focusId);
      expect(result.state.focusPlanId, focusId);
      expect(result.state.savedRef, same(savedRef));
      expect(result.state.picks, prior.picks);
      expect(result.state.seenActionIds, prior.seenActionIds);
      expect(result.state.plans['A']!.single, same(prior.plans['A']!.single));
      expect(result.state.lastDeliveredPlanId, 'A');
      expect(result.state.task!.nodes.map((node) => node.status), [
        'done',
        'done',
        'done',
        'current',
        'pending',
        'pending',
      ]);
    },
  );

  for (final operation in <String, List<String>>{
    'replace third': ['one', 'two', 'replacement', 'four', 'five'],
    'insert before third': ['one', 'two', 'inserted', 'three', 'four', 'five'],
    'delete third': ['one', 'two', 'four', 'five'],
    'insert another occurrence': ['one', 'two', 'one', 'three', 'four', 'five'],
  }.entries) {
    test('${operation.key} appends B and leaves A and old B intact', () {
      final prior = ready();
      final result = builder.draft(
        prior,
        draft(operation.value),
        newPlanId: 'unused-new-plan',
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.planId, focusId);
      expect(result.version, 5);
      expect(result.state.plans[focusId], hasLength(2));
      expect(
        result.state.plans[focusId]!.first,
        same(prior.plans[focusId]!.first),
      );
      expect(result.state.plans['A']!.single, same(prior.plans['A']!.single));
      expect(result.state.savedRef, same(savedRef));
      expect(result.state.focusPlanId, focusId);
      expect(result.state.plans[focusId]!.last.operation, 'edit');
      expect(actionIds(result), operation.value);
    });
  }

  test(
    'successive edits use the newest focus version while preserving base',
    () {
      final first = builder.draft(
        ready(),
        draft(['one', 'two', 'replacement', 'four', 'five']),
        newPlanId: 'unused',
      );
      expect(first.ok, isTrue);
      final next = AgentTask.start(
        first.state.appendUserTurn('再删除第4个'),
        'plan',
      ).state;
      final second = builder.draft(
        next,
        draft(['one', 'two', 'replacement', 'five']),
        newPlanId: 'unused',
      );
      expect(second.ok, isTrue, reason: '${second.error}');
      expect(second.version, 6);
      expect(second.state.plans[focusId]!.map((v) => v.version), [4, 5, 6]);
      expect(second.state.savedRef!.baseVersion, 4);
      expect(second.state.lastDeliveredPlanId, 'A');
      expect(actionIds(second), ['one', 'two', 'replacement', 'five']);
    },
  );

  test('focused parameter reset never invalidates the unrelated plan A', () {
    final prior = ready();
    final params = Map<String, CoachParamValue>.of(prior.params)
      ..['minutes'] = CoachParamValue(
        value: 5,
        source: 'user',
        quote: '5分钟',
        turn: 2,
      );
    final reset = gates.parametersChanged(
      prior.copyWith(params: params),
      changedFields: {'minutes'},
    );
    expect(reset.ok, isTrue);
    expect(reset.state.plans['A']!.single, same(prior.plans['A']!.single));
    expect(reset.state.plans['A']!.single.check, {'ok': true});
    expect(reset.state.plans[focusId]!.single.check, isNull);
    expect(reset.state.savedRef, same(savedRef));
    final resized = builder.refit(reset.state, saved);
    expect(resized.ok, isTrue, reason: '${resized.error}');
    expect(resized.feasibility, isNull);
    expect(resized.planId, focusId);
    expect(resized.version, 5);
    expect(resized.state.plans['A']!.single, same(prior.plans['A']!.single));
    expect(resized.state.savedRef, same(savedRef));
    expect(
      const PlanCodec()
          .decode(resized.state.plans[focusId]!.last.plan)
          .targetMinutes,
      5,
    );
  });

  test(
    'replacing a focused item preserves custom doses and block metadata',
    () {
      final custom = saved.copyWith(
        // These custom two-round doses total about 28 minutes, not 10. Keep
        // this a dose-preservation fixture rather than a duration repair.
        targetMinutes: 28,
        blocks: [
          PlanBlock(
            id: 'saved-main',
            name: 'Original block name',
            type: BlockType.main,
            rounds: 2,
            restBetweenRoundsSeconds: 17,
            items: [
              for (final entry in saved.items.indexed)
                PlanItem(
                  exerciseId: entry.$2.exerciseId,
                  mode: DoseMode.time,
                  sets: entry.$1 + 1,
                  workSeconds: 41 + entry.$1,
                  perSide: false,
                  restSeconds: 9 + entry.$1,
                  note: 'Original note ${entry.$1}',
                ),
            ],
          ),
        ],
      );
      final prior = AgentTask.start(withPlan(custom), 'plan').state;
      final edited = builder.draft(
        prior,
        draft(['one', 'two', 'replacement', 'four', 'five']),
        newPlanId: 'unused',
      );
      expect(edited.ok, isTrue, reason: '${edited.error}');
      final block = resultPlan(edited).blocks.single;
      expect(block.id, 'saved-main');
      expect(block.name, 'Original block name');
      expect(block.rounds, 2);
      expect(block.restBetweenRoundsSeconds, 17);
      for (final index in [0, 1, 3, 4]) {
        expect(
          block.items[index].toJson(),
          custom.blocks.single.items[index].toJson(),
        );
      }
      expect(edited.fitLog, isEmpty);
      expect(edited.state.plans[focusId]!.first.plan, custom.toJson());
      final output = OutputGate(profile, catalog).prepare(
        edited.state,
        CoachTools.showPlan,
        {'plan_id': focusId, 'note': 'Updated third action'},
      );
      expect(output.ok, isTrue, reason: '${output.error}');
      expect(output.nodeResult!.state.plans[focusId], hasLength(2));
      final delivered = output.plan!.blocks.single;
      expect(delivered.rounds, 2);
      for (final index in [0, 1, 3, 4]) {
        expect(
          delivered.items[index].toJson(),
          custom.blocks.single.items[index].toJson(),
        );
      }
    },
  );

  test('unchanged repeated IDs retain independent saved doses', () {
    final custom = saved.copyWith(
      blocks: [
        PlanBlock(
          id: 'repeated-block',
          name: 'Repeated actions',
          type: BlockType.main,
          items: [
            const PlanItem(
              exerciseId: 'one',
              mode: DoseMode.time,
              sets: 3,
              workSeconds: 41,
              perSide: false,
              restSeconds: 7,
              note: 'First occurrence',
            ),
            const PlanItem(
              exerciseId: 'one',
              mode: DoseMode.time,
              sets: 1,
              workSeconds: 79,
              perSide: false,
              restSeconds: 11,
              note: 'Second occurrence',
            ),
            ...saved.items.skip(2),
          ],
        ),
      ],
    );
    final result = builder.draft(
      AgentTask.start(withPlan(custom), 'plan').state,
      draft(['one', 'one', 'three', 'replacement', 'five']),
      newPlanId: 'unused',
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    final items = resultPlan(result).items.toList();
    expect(items[0].toJson(), custom.items.first.toJson());
    expect(items[1].toJson(), custom.items.elementAt(1).toJson());
    expect(items, hasLength(5));
  });

  test('unmodified segmented item survives ID-only focused editing', () {
    const segmented = PlanItem(
      exerciseId: 'one',
      mode: DoseMode.time,
      sets: 2,
      workSeconds: 70,
      perSide: false,
      restSeconds: 13,
      note: 'Keep group note',
      segments: [
        PlanSegment(
          id: 'part-a',
          exerciseId: 'two',
          mode: DoseMode.time,
          workSeconds: 31,
          holdSeconds: 2,
          label: 'Original label',
          rhythm: {'kind': 'rep_hold', 'leadSeconds': 1},
        ),
        PlanSegment(
          id: 'part-b',
          exerciseId: 'three',
          mode: DoseMode.time,
          workSeconds: 39,
        ),
      ],
    );
    final custom = saved.copyWith(
      // Two rounds retain their full saved work (~22 minutes after editing).
      targetMinutes: 22,
      blocks: [
        PlanBlock(
          id: 'segmented-block',
          name: 'Original segmented block',
          type: BlockType.main,
          rounds: 2,
          items: [segmented, ...saved.items.skip(1)],
        ),
      ],
    );
    final result = builder.draft(
      AgentTask.start(withPlan(custom), 'plan').state,
      draft(['one', 'two', 'replacement', 'four', 'five']),
      newPlanId: 'unused',
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(resultPlan(result).items.first.toJson(), segmented.toJson());
    expect(resultPlan(result).blocks.single.rounds, 2);
  });

  test('ordinary focus refit starts from saved work and preserves notes', () {
    final prior = AgentTask.start(withPlan(saved), 'plan').state;
    final shorter = prior.copyWith(
      params: {
        ...prior.params,
        'minutes': CoachParamValue(value: 5, source: 'host', turn: 2),
      },
    );
    final result = builder.refit(shorter, saved);
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.feasibility, isNull);
    final plan = resultPlan(result);
    expect(plan.blocks.single.id, 'main');
    expect(plan.targetMinutes, 5);
    expect(result.durationErrorPercent, lessThanOrEqualTo(10));
    expect(result.state.savedRef, same(savedRef));
    expect(actionIds(result), originalIds);
  });

  test(
    'ordinary focused output shrink uses saved refit rather than defaults',
    () {
      final custom = saved.copyWith(
        blocks: [
          PlanBlock(
            id: 'saved-block',
            name: 'Original name',
            type: BlockType.main,
            items: [
              for (final item in saved.items)
                PlanItem(
                  exerciseId: item.exerciseId,
                  mode: item.mode,
                  sets: item.sets,
                  workSeconds: item.workSeconds,
                  perSide: item.perSide,
                  restSeconds: item.restSeconds,
                  note: 'Preserve ${item.exerciseId}',
                ),
            ],
          ),
        ],
      );
      final prior = AgentTask.start(withPlan(custom), 'plan').state;
      final shorter = prior.copyWith(
        params: {
          ...prior.params,
          'minutes': CoachParamValue(value: 5, source: 'host', turn: 2),
        },
      );
      final output = OutputGate(profile, catalog).prepare(
        shorter,
        CoachTools.showPlan,
        {'plan_id': focusId, 'note': 'Shortened'},
      );
      expect(output.ok, isTrue, reason: '${output.error}');
      expect(output.plan, isNotNull);
      expect(output.plan!.targetMinutes, 5);
      expect(output.plan!.blocks.single.id, 'saved-block');
      expect(output.plan!.blocks.single.name, 'Original name');
      expect(output.plan!.items.map((item) => item.note), [
        for (final id in originalIds) 'Preserve $id',
      ]);
      expect(output.nodeResult!.state.plans[focusId], hasLength(2));
      expect(output.nodeResult!.state.savedRef, same(savedRef));
    },
  );

  for (final retainedIndex in [1, 2]) {
    test(
      'sourceIndex retains duplicate occurrence $retainedIndex after deletion',
      () {
        // After deleting either occurrence the preserved work is near 9 min.
        final custom = repeatedPlan().copyWith(targetMinutes: 9);
        final prior = AgentTask.start(withPlan(custom), 'plan').state;
        final result = builder.draft(
          prior,
          indexedDraft([
            {'id': 'one', 'sourceIndex': retainedIndex},
            {'id': 'three', 'sourceIndex': 3},
            {'id': 'four', 'sourceIndex': 4},
            {'id': 'five', 'sourceIndex': 5},
          ]),
          newPlanId: 'unused',
        );
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(resultPlan(result).items, hasLength(4));
        expect(
          resultPlan(result).items.first.toJson(),
          custom.items.elementAt(retainedIndex - 1).toJson(),
        );
        expect(result.state.plans[focusId]!.first.plan, custom.toJson());
      },
    );
  }

  test('an unreferenced duplicate insertion gets its own default dose', () {
    final custom = repeatedPlan();
    final result = builder.draft(
      AgentTask.start(withPlan(custom), 'plan').state,
      indexedDraft([
        {'id': 'one', 'sourceIndex': 1},
        {'id': 'one'},
        {'id': 'one', 'sourceIndex': 2},
        {'id': 'three', 'sourceIndex': 3},
        {'id': 'four', 'sourceIndex': 4},
        {'id': 'five', 'sourceIndex': 5},
      ]),
      newPlanId: 'unused',
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    final items = resultPlan(result).items.toList();
    expect(items, hasLength(6));
    expect(items[0].toJson(), custom.items.first.toJson());
    expect(items[2].toJson(), custom.items.elementAt(1).toJson());
    expect(items[1].sets, 1);
    expect(items[1].workSeconds, 60);
    expect(items[1].note, isNull);
  });

  for (final invalid in <String, List<Map<String, Object?>>>{
    'zero': [
      {'id': 'one', 'sourceIndex': 0},
    ],
    'negative': [
      {'id': 'one', 'sourceIndex': -1},
    ],
    'out of range': [
      {'id': 'one', 'sourceIndex': 6},
    ],
    'fraction': [
      {'id': 'one', 'sourceIndex': 1.5},
    ],
    'string': [
      {'id': 'one', 'sourceIndex': '1'},
    ],
    'null': [
      {'id': 'one', 'sourceIndex': null},
    ],
    'wrong ID': [
      {'id': 'three', 'sourceIndex': 1},
    ],
    'reused index': [
      {'id': 'one', 'sourceIndex': 1},
      {'id': 'one', 'sourceIndex': 1},
    ],
  }.entries) {
    test('sourceIndex ${invalid.key} is refused without state changes', () {
      final prior = AgentTask.start(withPlan(repeatedPlan()), 'plan').state;
      final result = builder.draft(
        prior,
        indexedDraft(invalid.value),
        newPlanId: 'unused',
      );
      expect(result.error!['code'], 'invalid_source_index');
      expect(result.state, same(prior));
    });
  }
}
