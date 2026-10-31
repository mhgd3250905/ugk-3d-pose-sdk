import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

const _fixture = 'test/fixtures/smartfit/five-minute';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

// The existing raw v3 fixture is immutable and retains its historical 313/345s
// replay. Current SF _planningCadence (app_test_content.dart:148-215) creates a
// separate planning view with the SAME execution cycle and a real video path.
// This projection does not erase authored lead, phases, cues or source bytes.
Catalog _planningCadence(Catalog source, Map<String, Rhythm> rhythms) =>
    Catalog.fromJson({
      ...source.raw,
      'drills': [
        for (final drill in source.drills)
          if (drill.defaultDose.mode == DoseMode.reps)
            {
              ...drill.raw,
              'assets': {
                ...Map<String, Object?>.from(
                  drill.raw['assets'] as Map? ?? const {},
                ),
                'video': {
                  'sources': [
                    {
                      ...Map<String, Object?>.from(
                        (drill.raw['files'] as Map)['video'] as Map,
                      ),
                      'app': 'pose-hub',
                      'repSeconds': rhythms[drill.id]!.cycleFor(),
                    },
                  ],
                },
              },
            }
          else
            drill.raw,
      ],
    });

CoachParamValue _param(Object value) =>
    CoachParamValue(value: value, source: 'user', quote: '在家全身训练', turn: 1);

CoachSessionState _ready(int minutes, CoachProfile profile, Catalog catalog) {
  var state = CoachSessionState(
    userTurns: [CoachUserTurn(turn: 1, text: '在家全身训练 $minutes 分钟')],
    params: {
      'scene': _param('home'),
      'goal': _param(['purpose.strength']),
      'minutes': _param(minutes),
      'level': _param(3),
      'equipment': _param(['equip.mat', 'equip.wall', 'equip.chair']),
      'limits': _param(<String>[]),
    },
    seenActionIds: catalog.ids.toSet(),
  );
  final gate = NodeGates(profile, catalog, minPicks: profile.minActions);
  state = AgentTask.start(
    state,
    'plan',
  ).state.copyWith(seenActionIds: catalog.ids.toSet());
  for (final node in ['understand', 'parameters']) {
    final checked = gate.check(state, node);
    expect(checked.ok, isTrue, reason: '${checked.error}');
    state = checked.state;
  }
  final selected = gate.check(state, 'actions', picks: catalog.ids.toList());
  expect(selected.ok, isTrue, reason: '${selected.error}');
  return selected.state;
}

void main() {
  final originalBytes = File('$_fixture/catalog.json').readAsBytesSync();
  final source = Catalog.fromJson(_json('$_fixture/catalog.json'));
  final profile = CoachProfile.fromJson(_json('../../profiles/smartfit.json'));
  final rhythms = rhythmsFromCatalog(
    source,
    overrides: {
      for (final drill in source.drills)
        drill.id: Rhythm.fromJson(
          Map<String, dynamic>.from(
            (drill.raw['rhythm'] as Map)['execution'] as Map,
          ),
        ),
    },
  );
  final catalog = _planningCadence(source, rhythms);
  final fitter = PlanBuilder(profile, catalog, minPicks: profile.minActions);

  for (final warmup in [
    (id: 'h-squat', mode: DoseMode.reps, bilateral: false),
    (id: 's-butterfly', mode: DoseMode.time, bilateral: false),
    (id: 's-kneel-hipflex', mode: DoseMode.time, bilateral: true),
  ]) {
    for (final minutes in [5, 10, 20, 30]) {
      test(
        'SF $minutes min with ${warmup.id} warmup fits card and execution',
        () {
          final cooldown = warmup.id == 's-butterfly'
              ? 's-kneel-hipflex'
              : 's-butterfly';
          final mainIds = catalog.ids
              .where((id) => id != warmup.id && id != cooldown)
              .toList();
          final result = fitter.draft(_ready(minutes, profile, catalog), {
            'title': 'SF $minutes min',
            'blocks': [
              {
                'kind': 'warmup',
                'items': [
                  {'id': warmup.id},
                ],
              },
              {
                'kind': 'main',
                'items': [
                  for (final id in mainIds) {'id': id},
                ],
              },
              {
                'kind': 'cooldown',
                'items': [
                  {'id': cooldown},
                ],
              },
            ],
          }, newPlanId: 'sf-${warmup.id}-$minutes');
          expect(result.ok, isTrue, reason: '${result.error}');
          expect(result.feasibility, isNull, reason: '${result.feasibility}');
          final version = result.state.plans[result.planId]!.last;
          final plan = const PlanCodec().decode(version.plan);
          expect(plan.blocks.map((block) => block.type), [
            BlockType.warmup,
            BlockType.main,
            BlockType.cooldown,
          ]);
          expect(plan.blocks.first.items.single.exerciseId, warmup.id);
          expect(plan.blocks.first.items.single.mode, warmup.mode);
          expect(plan.blocks.first.items.single.perSide, warmup.bilateral);
          expect(
            plan.items.map((item) => item.exerciseId),
            unorderedEquals(source.ids),
          );
          for (final block in plan.blocks) {
            expect(profile.limits.rounds.contains(block.rounds), isTrue);
            for (final item in block.items) {
              final range = source[item.exerciseId]!.doseRange;
              expect(range.sets!.contains(item.sets), isTrue);
              expect(profile.limits.sets.contains(item.sets), isTrue);
              expect(item.perSide, source[item.exerciseId]!.unilateral);
              if (item.mode == DoseMode.reps) {
                expect(range.reps!.contains(item.reps!), isTrue);
                expect(profile.limits.reps.contains(item.reps!), isTrue);
              } else {
                expect(range.seconds!.contains(item.workSeconds!), isTrue);
                expect(
                  profile.limits.workSeconds.contains(item.workSeconds!),
                  isTrue,
                );
              }
            }
          }
          final card = const PlanDuration().estimateSeconds(plan, catalog);
          // SF's actual host prep is 10s (HipLab's separate fixture uses 15s).
          // Authored rhythms and lead remain exactly as in the original fixture.
          final playback = SessionBuilder(rhythms: rhythms, prepSeconds: 10);
          final phases = playback.phases(plan);
          expect(phases.where((phase) => phase.selfPaced), isEmpty);
          final total = phases.fold(0.0, (sum, phase) => sum + phase.seconds);
          final target = minutes * 60.0;
          printOnFailure(
            jsonEncode({
              'minutes': minutes,
              'warmup': warmup.id,
              'cardSeconds': card,
              'executionSeconds': total,
            }),
          );
          expect((card - target).abs(), lessThanOrEqualTo(target * .1));
          expect((total - target).abs(), lessThanOrEqualTo(target * .1));
          expect(version.estimateSec, card);
          expect(result.toJson()['withinTolerance'], isTrue);
          final engine = SessionEngine(phases)..update(total);
          expect(engine.done, isTrue);
          expect(engine.endedEarly, isFalse);
          expect(
            engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
            closeTo(total, 1e-6),
          );
          expect(
            File('$_fixture/catalog.json').readAsBytesSync(),
            originalBytes,
          );
          expect(rhythms['h-squat']!.lead, 1);
        },
      );
    }
  }
}
