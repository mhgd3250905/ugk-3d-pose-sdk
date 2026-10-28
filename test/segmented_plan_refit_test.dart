import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

void main() {
  const profile = CoachProfile(
    id: 'timing',
    appName: 'timing',
    limits: PlanLimits(
      sets: IntRange(1, 6),
      rounds: IntRange(1, 2),
      restSeconds: IntRange(0, 0),
      restBetweenRoundsSeconds: IntRange(0, 0),
      reps: IntRange(1, 20),
      workSeconds: IntRange(10, 120),
    ),
  );
  final catalog = Catalog(
    version: 'timing',
    drills: [
      for (final id in ['parent', 'repeated', 'timed'])
        Drill(
          id: id,
          name: LocalizedText({'en': id}),
          category: 'core',
          muscleGroups: const ['abs'],
          position: 'standing',
          unilateral: false,
          level: 1,
          scenes: const ['home'],
          defaultDose: Dose(
            mode: id == 'repeated' ? DoseMode.reps : DoseMode.time,
            sets: 1,
            reps: 10,
            seconds: 60,
            restSeconds: 0,
          ),
        ),
    ],
  );
  const saved = TrainingPlan(
    id: 'saved',
    source: 'ai',
    title: 'Saved',
    summary: 'Original summary',
    goal: 'core',
    scene: 'home',
    level: 1,
    targetMinutes: 10,
    blocks: [
      PlanBlock(
        id: 'legacy-main',
        name: 'Original circuit',
        type: BlockType.circuit,
        items: [
          PlanItem(
            exerciseId: 'parent',
            mode: DoseMode.time,
            sets: 6,
            workSeconds: 100,
            perSide: false,
            restSeconds: 0,
            note: 'Original group note',
            segments: [
              PlanSegment(
                id: 'reps-part',
                exerciseId: 'repeated',
                mode: DoseMode.reps,
                reps: 10,
                holdSeconds: 2,
                label: 'Original rep label',
                rhythm: {
                  'kind': 'rep_hold',
                  'leadSeconds': 0,
                  'phases': [
                    {'id': 'go', 'seconds': 1, 'cue': 'up'},
                    {'id': 'hold', 'seconds': 2, 'cue': 'hold'},
                  ],
                },
              ),
              PlanSegment(
                id: 'time-part',
                exerciseId: 'timed',
                mode: DoseMode.time,
                workSeconds: 60,
                label: 'Original time label',
              ),
            ],
          ),
        ],
      ),
    ],
  );
  final builder = PlanBuilder(profile, catalog, minPicks: 3);
  CoachSessionState ready(int minutes, {List<Map<String, Object?>>? dose}) {
    CoachParamValue value(Object data) => CoachParamValue(
      value: data,
      source: 'user',
      quote: 'explicit',
      turn: 2,
    );
    return CoachSessionState(
      userTurns: const [CoachUserTurn(turn: 2, text: 'explicit')],
      params: {
        'minutes': value(minutes),
        'scene': value('home'),
        'goal': value(['body.abs']),
        'equipment': value(<String>[]),
        'limits': value(<String>[]),
        if (dose != null) 'dose': value(dose),
      },
      seenActionIds: {'parent', 'repeated', 'timed'},
      picks: ['repeated', 'timed'],
      activePlanId: saved.id,
      lastDeliveredPlanId: saved.id,
      lastDeliveredVersion: 1,
      plans: {
        saved.id: [
          CoachPlanVersion(
            version: 1,
            plan: saved.toJson(),
            estimateSec: const PlanDuration().estimateSeconds(saved, catalog),
            fitLog: [],
          ),
        ],
      },
    );
  }

  TrainingPlan card(DraftResult result) =>
      const PlanCodec().decode(result.state.plans[saved.id]!.last.plan);

  test(
    'trusted segmented refit changes sets without flattening or losing metadata',
    () {
      final result = builder.refit(ready(5), saved);
      expect(result.ok, isTrue);
      expect(result.feasibility, isNull);
      expect(result.version, 2);
      final plan = card(result);
      expect(plan.targetMinutes, 5);
      expect(plan.blocks.single.id, 'legacy-main');
      expect(plan.blocks.single.name, 'Original circuit');
      expect(plan.blocks.single.type, BlockType.circuit);
      final item = plan.items.single;
      expect(item.exerciseId, 'parent');
      expect(item.mode, DoseMode.time);
      expect(item.perSide, isFalse);
      expect(item.note, 'Original group note');
      expect(
        item.segments.map((s) => s.toJson()).toList(),
        saved.items.single.segments.map((s) => s.toJson()).toList(),
      );
      expect(item.sets, 3);
      expect(result.durationErrorPercent, lessThanOrEqualTo(10));
      expect(result.fitLog, isNotEmpty);
      expect(
        result.fitLog.every(
          (step) =>
              step['blockId'] == 'legacy-main' &&
              {'rounds', 'sets'}.contains(step['field']),
        ),
        isTrue,
      );
    },
  );

  test(
    'confirmed dose applies to performed segment IDs and keeps their independent modes',
    () {
      final result = builder.refit(
        ready(
          5,
          dose: [
            {'field': 'sets', 'value': 3},
            {'field': 'reps', 'value': 10, 'actionId': 'repeated'},
            {'field': 'seconds', 'value': 70, 'actionId': 'timed'},
          ],
        ),
        saved,
      );
      expect(result.ok, isTrue);
      expect(result.feasibility, isNull);
      final item = card(result).items.single;
      expect(item.sets, 3);
      expect(item.segments.first.reps, 10);
      expect(
        item.segments.first.rhythm,
        saved.items.single.segments.first.rhythm,
      );
      expect(item.segments.last.workSeconds, 70);
      expect(result.durationErrorPercent, lessThanOrEqualTo(10));
      final unseen = builder.refit(
        ready(5).copyWith(seenActionIds: {'parent', 'timed'}),
        saved,
      );
      expect(unseen.ok, isFalse);
      expect(unseen.error!['code'], 'incompatible_action');
      final current = ready(5);
      final replacement = builder.refit(
        current.copyWith(
          params: {
            ...current.params,
            'operation': CoachParamValue(
              value: 'replace_all',
              source: 'user',
              quote: 'explicit',
              turn: 2,
            ),
          },
        ),
        saved,
      );
      expect(replacement.ok, isFalse);
      expect(replacement.error!['code'], 'replace_too_similar');
      expect(replacement.state.plans[saved.id]!.length, 1);
      final requestedAgain = builder.refit(
        current.copyWith(
          lastOperationRequestTurn: 2,
          params: {
            ...current.params,
            'operation': CoachParamValue(
              value: 'replace_all',
              source: 'user',
              quote: 'earlier proof',
              turn: 1,
            ),
          },
        ),
        saved,
      );
      expect(requestedAgain.error!['code'], 'replace_too_similar');
    },
  );

  test(
    'segment bounds include work the heuristic does not explore and prove only legal impossibility',
    () {
      final best = builder.refit(ready(1), saved);
      expect(best.ok, isTrue);
      expect(
        best.planId,
        saved.id,
        reason:
            'fixed original work is too long, but legal lower segment work is not',
      );
      expect(best.feasibility, isNull);
      expect(best.durationErrorPercent, greaterThan(10));
      expect(card(best).items.single.segments.last.workSeconds, 60);
      final impossible = builder.refit(
        ready(
          1,
          dose: [
            {'field': 'sets', 'value': 1},
            {'field': 'rounds', 'value': 1},
            {'field': 'reps', 'value': 20, 'actionId': 'repeated'},
            {'field': 'seconds', 'value': 120, 'actionId': 'timed'},
          ],
        ),
        saved,
      );
      expect(impossible.ok, isTrue);
      expect(impossible.planId, isNull);
      expect(impossible.feasibility!['reason'], 'minimum_exceeds_target');
      expect(impossible.feasibility!['boundBasis'], contains('segment work'));
      expect(impossible.state.plans[saved.id]!.length, 1);
    },
  );
}
