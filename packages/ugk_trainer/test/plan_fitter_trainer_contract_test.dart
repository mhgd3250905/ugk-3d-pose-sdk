import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _selected = [
  's-figure4',
  's-kneel-hipflex',
  'n-thomas-test',
  'h-couch-stretch',
  'o-seated-fig4',
  'o-seated-ham',
];

Catalog _realCatalog() => PoseHubAppTestCatalog.fromJson(
  jsonDecode(
        File(
          'assets/pose_hub/app-test-pack-r1/catalog.json',
        ).readAsStringSync(),
      )
      as Map<String, Object?>,
  semanticCatalog:
      jsonDecode(
            File(
              'assets/pose_hub/app-test-pack-r1/catalog/catalog.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>,
).toAiCatalog();

CoachParamValue _user(Object value) => CoachParamValue(
  value: value,
  source: 'user',
  quote: 'HipLab duration contract',
  turn: 1,
);

CoachSessionState _ready(int minutes, CoachProfile profile, Catalog catalog) {
  var state = CoachSessionState(
    userTurns: const [
      CoachUserTurn(turn: 1, text: 'HipLab bilateral stretching duration'),
    ],
    params: {
      'scene': _user('home'),
      'goal': _user(['purpose.stretch']),
      'minutes': _user(minutes),
      'level': _user(3),
      'equipment': _user(['equip.mat', 'equip.chair']),
      'limits': _user(<String>[]),
    },
    seenActionIds: _selected.toSet(),
  );
  final gate = NodeGates(profile, catalog, minPicks: 3);
  state = AgentTask.start(
    state,
    'plan',
  ).state.copyWith(seenActionIds: _selected.toSet());
  for (final node in ['understand', 'parameters']) {
    final checked = gate.check(state, node);
    expect(checked.ok, isTrue, reason: '${checked.error}');
    state = checked.state;
  }
  final selected = gate.check(state, 'actions', picks: _selected);
  expect(selected.ok, isTrue, reason: '${selected.error}');
  return selected.state;
}

TrainingPlan _savedCircuit(Catalog catalog) => TrainingPlan(
  id: 'saved-bilateral-circuit',
  source: 'template',
  title: 'Saved bilateral HipLab circuit',
  goal: 'relax',
  scene: 'home',
  equipment: const ['mat', 'chair'],
  level: 3,
  targetMinutes: 10,
  blocks: [
    PlanBlock(
      id: 'main',
      name: 'Bilateral circuit',
      type: BlockType.circuit,
      items: [
        for (final id in _selected)
          PlanItem(
            exerciseId: id,
            mode: catalog[id]!.defaultDose.mode,
            sets: catalog[id]!.defaultDose.sets,
            workSeconds: catalog[id]!.defaultDose.seconds,
            perSide: catalog[id]!.unilateral,
            restSeconds: catalog[id]!.defaultDose.restSeconds,
          ),
      ],
    ),
  ],
);

void _expectFitted(
  DraftResult result,
  int minutes,
  Catalog catalog,
  CoachProfile profile, {
  required BlockType blockType,
}) {
  expect(result.ok, isTrue, reason: '${result.error}');
  expect(result.feasibility, isNull, reason: '${result.feasibility}');
  expect(
    result.fitLog,
    isNotEmpty,
    reason: 'The real fitter must adjust doses.',
  );
  final version = result.state.plans[result.planId]!.last;
  final plan = const PlanCodec().decode(version.plan);
  expect(plan.targetMinutes, minutes);
  expect(plan.blocks.single.type, blockType);
  expect(
    plan.blocks.single.items.map((item) => item.exerciseId).toSet(),
    _selected.toSet(),
  );
  expect(plan.items.every((item) => item.perSide), isTrue);
  if (minutes >= 10) {
    expect(plan.blocks.single.rounds, greaterThan(1));
  }

  final phases = SessionBuilder(
    rhythms: rhythmsFromCatalog(catalog),
  ).phases(plan);
  final actualSeconds = phases.fold(0.0, (sum, phase) => sum + phase.seconds);
  final cardSeconds = const PlanDuration().estimateSeconds(plan, catalog);
  expect(actualSeconds, closeTo(cardSeconds, 1));
  expect(version.estimateSec, cardSeconds);

  // PlanBuilder's existing return contract is <=10%; the profile's separate
  // warning tolerance can be looser. Honor the stricter existing boundary.
  final ratio = profile.limits.durationTolerance < .1
      ? profile.limits.durationTolerance
      : .1;
  final target = minutes * 60.0;
  expect((actualSeconds - target).abs(), lessThanOrEqualTo(target * ratio));
  expect(result.toJson()['withinTolerance'], isTrue);

  final engine = SessionEngine(phases);
  engine.update(actualSeconds);
  expect(engine.done, isTrue);
  expect(engine.endedEarly, isFalse);
  expect(
    engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
    closeTo(cardSeconds, 1),
  );
}

void main() {
  final catalog = _realCatalog();
  final profile = CoachProfile.fromJson(
    jsonDecode(File('../../profiles/hiplab.json').readAsStringSync()),
  );
  final builder = PlanBuilder(profile, catalog, minPicks: 3);

  for (final minutes in [5, 10, 20, 30]) {
    test(
      'draft $minutes min remains on target with actual main-round playback',
      () {
        final state = _ready(minutes, profile, catalog);
        final result = builder.draft(state, {
          'title': 'HipLab target $minutes',
          'blocks': [
            {
              'kind': 'main',
              'items': [
                for (final id in _selected) {'id': id},
              ],
            },
          ],
        }, newPlanId: 'draft-$minutes');
        _expectFitted(
          result,
          minutes,
          catalog,
          profile,
          blockType: BlockType.main,
        );
      },
    );

    test('refit $minutes min retains a circuit and actual target duration', () {
      final saved = _savedCircuit(catalog);
      final state = _ready(minutes, profile, catalog).copyWith(
        activePlanId: saved.id,
        focusPlanId: saved.id,
        plans: {
          saved.id: [
            CoachPlanVersion(
              version: 1,
              plan: saved.toJson(),
              estimateSec: const PlanDuration().estimateSeconds(saved, catalog),
              fitLog: const [],
            ),
          ],
        },
      );
      final result = builder.refit(state, saved);
      _expectFitted(
        result,
        minutes,
        catalog,
        profile,
        blockType: BlockType.circuit,
      );
    });
  }
}
