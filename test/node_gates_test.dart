import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final gate = NodeGates(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value, [String source = 'user']) =>
      CoachParamValue(value: value, source: source, turn: 1);
  CoachSessionState initial() => CoachSessionState(
    userTurns: [const CoachUserTurn(turn: 1, text: '在家练核心 20 分钟')],
    params: {
      'scene': param('home', 'host'),
      'goal': param(['body.core']),
      'minutes': param(20),
    },
  );
  CoachSessionState parametersDone() {
    var state = AgentTask.start(initial(), 'plan').state;
    state = gate.check(state, 'understand').state;
    final result = gate.check(state, 'parameters');
    expect(result.ok, isTrue, reason: '${result.error}');
    return result.state;
  }

  test('fixed nodes reject skipped checks and output cannot be checked', () {
    final started = AgentTask.start(initial(), 'plan');
    expect(started.state.task!.nodes.map((n) => n.id), AgentTask.planNodes);
    final rejected = gate.check(started.state, 'parameters');
    expect(rejected.ok, isFalse);
    expect(rejected.error!['expected'], 'understand');
    expect(gate.check(started.state, 'output').ok, isFalse);
    expect(started.state.task!.nodes.first.status, 'current');
  });

  test(
    'parameters require goal and plan conditions, then add sourced defaults',
    () {
      var state = AgentTask.start(CoachSessionState(), 'plan').state;
      state = gate.check(state, 'understand').state;
      final missing = gate.check(state, 'parameters');
      expect(missing.error!['actual'], ['scene', 'goal', 'minutes']);
      final ready = parametersDone();
      expect(ready.params['equipment']!.value, isEmpty);
      expect(ready.params['level']!.value, 1);
      expect(ready.params['limits']!.value, isEmpty);
      final stamp = ready.task!.nodes[1].stamp!;
      expect(stamp, contains('居家（App 设置）'));
      expect(stamp, contains('徒手（可用'));
      expect(stamp, contains('墙'));
      expect(stamp, contains('20 分钟（你说的）'));
      expect(stamp, contains('初学（默认）'));
      expect(stamp, contains('无伤痛（默认）'));
    },
  );

  test('seen and equipment conditions are enforced before action check', () {
    var state = parametersDone();
    final valid = profile
        .scope(catalog)
        .where((d) => gate.actionProblem(state, d.id) == null)
        .take(3)
        .map((d) => d.id)
        .toList();
    expect(valid, hasLength(3));
    expect(
      gate.check(state, 'actions', picks: valid).error!['code'],
      'unseen_actions',
    );
    final extra = profile
        .scope(catalog)
        .firstWhere((d) => d.equipment.contains('dumbbell'));
    state = state.copyWith(seenActionIds: {...valid, extra.id});
    final bad = gate.check(
      state,
      'actions',
      picks: [valid[0], valid[1], extra.id],
    );
    expect(bad.error!['code'], 'incompatible_actions');
    expect((bad.error!['actual'] as Map)[extra.id], '器械不符合');
    final good = gate.check(state, 'actions', picks: valid);
    expect(good.ok, isTrue);
    expect(good.state.picks, valid);
    expect(good.state.task!.nodes[3].status, 'current');
  });

  test('changed parameters update stamp and reset later steps and picks', () {
    var state = parametersDone();
    final valid = profile
        .scope(catalog)
        .where((d) => gate.actionProblem(state, d.id) == null)
        .take(3)
        .map((d) => d.id)
        .toList();
    state = state.copyWith(seenActionIds: valid.toSet());
    state = gate.check(state, 'actions', picks: valid).state;
    state = state.copyWith(
      plans: {
        'p': [
          CoachPlanVersion(
            version: 1,
            plan: {},
            estimateSec: 1200,
            fitLog: const [],
            check: {'ok': true},
          ),
        ],
      },
    );
    state = gate.check(state, 'planning', planId: 'p').state;
    state = gate.check(state, 'review', planId: 'p').state;
    final params = Map<String, CoachParamValue>.of(state.params)
      ..['level'] = param(1);
    final updated = gate.parametersChanged(state.copyWith(params: params));
    expect(updated.state.task!.nodes[1].status, 'updated');
    expect(updated.state.task!.nodes[1].stamp, contains('初学（你说的）'));
    expect(updated.state.task!.nodes.skip(2).map((n) => n.status), [
      'current',
      'pending',
      'pending',
      'pending',
    ]);
    expect(updated.changes.map((n) => n.id), [
      'parameters',
      'actions',
      'planning',
      'review',
      'output',
    ]);
    expect(updated.state.picks, valid);
    expect(updated.state.plans['p']!.single.check, isNull);
    var restarted = gate.check(updated.state, 'actions', picks: valid).state;
    restarted = gate.check(restarted, 'planning', planId: 'p').state;
    expect(
      gate.check(restarted, 'review', planId: 'p').error!['code'],
      'plan_not_checked',
    );
  });

  test('new restrictive equipment removes previously selected mat action', () {
    var state = parametersDone();
    final mat = profile
        .scope(catalog)
        .firstWhere((d) => d.equipment.contains('mat'));
    state = state.copyWith(picks: [mat.id]);
    final params = Map<String, CoachParamValue>.of(state.params)
      ..['equipment_exclude'] = param(['equip.mat']);
    state = state.copyWith(params: params);
    final updated = gate.parametersChanged(state);
    expect(updated.state.picks, isEmpty);
  });

  test('host English restriction matches the catalogue caution', () {
    final drill = profile
        .scope(catalog)
        .firstWhere((d) => d.cautions.contains('膝'));
    final state = CoachSessionState(
      params: {
        'equipment': param([
          for (final id in drill.equipment) ?gate.tags.equipmentCode(id),
        ]),
        'limits': param(['limit.knee'], 'host'),
      },
    );
    expect(gate.tags.canonicalLimitCode('knee'), 'limit.knee');
    expect(gate.actionProblem(state, drill.id), '触及伤痛限制');
  });

  test(
    'unknown equipment is not treated as bodyweight and declared missing semantics warn',
    () {
      final base = catalog.drills.first;
      final unknown = Drill(
        id: 'unknown-equipment',
        name: base.name,
        category: base.category,
        equipment: const ['特殊设备'],
        position: base.position,
        unilateral: base.unilateral,
        level: base.level,
        defaultDose: base.defaultDose,
        raw: const {
          'trainingSemantics': {
            'unknownFields': [
              {'field': 'contraindications'},
            ],
          },
        },
      );
      final missingCode = Drill(
        id: 'unencodable-equipment',
        name: base.name,
        category: base.category,
        equipment: const [''],
        position: base.position,
        unilateral: base.unilateral,
        level: base.level,
        defaultDose: base.defaultDose,
      );
      final synthetic = Catalog(
        version: catalog.version,
        taxonomy: catalog.taxonomy,
        drills: [unknown, missingCode, ...catalog.drills],
      );
      final syntheticGate = NodeGates(
        const CoachProfile(id: 'all', appName: 'all'),
        synthetic,
        minPicks: 1,
      );
      var state = CoachSessionState(
        params: {
          'goal': param(['body.core']),
        },
      );
      state = AgentTask.start(state, 'recommend').state;
      state = syntheticGate.check(state, 'understand').state;
      state = syntheticGate.check(state, 'parameters').state;
      expect(syntheticGate.actionProblem(state, unknown.id), '器械不符合');
      expect(syntheticGate.actionProblem(state, missingCode.id), '器械不符合');
      final params = Map<String, CoachParamValue>.of(state.params)
        ..['equipment'] = param([
          syntheticGate.tags.equipmentCode('特殊设备')!,
        ], 'host');
      state = state.copyWith(params: params, seenActionIds: {unknown.id});
      final result = syntheticGate.check(state, 'actions', picks: [unknown.id]);
      expect(result.ok, isTrue);
      expect(result.warnings.single, contains('contraindications'));
    },
  );

  test('only latest plan version with passing check completes review', () {
    var state = parametersDone();
    final valid = profile
        .scope(catalog)
        .where((d) => gate.actionProblem(state, d.id) == null)
        .take(3)
        .map((d) => d.id)
        .toList();
    state = gate
        .check(
          state.copyWith(seenActionIds: valid.toSet()),
          'actions',
          picks: valid,
        )
        .state;
    state = state.copyWith(
      plans: {
        'p': [
          CoachPlanVersion(
            version: 1,
            plan: {},
            estimateSec: 600,
            fitLog: const [],
            check: {'ok': true},
          ),
          CoachPlanVersion(
            version: 2,
            plan: {},
            estimateSec: 1200,
            fitLog: const [],
          ),
        ],
      },
    );
    state = gate.check(state, 'planning', planId: 'p').state;
    expect(
      gate.check(state, 'review', planId: 'p').error!['code'],
      'plan_not_checked',
    );
    expect(gate.completeOutput(state).error!['code'], 'nodes_incomplete');
  });

  test(
    'reuse requires delivered recommendation and keeps first three nodes',
    () {
      var state = AgentTask.start(initial(), 'recommend').state;
      expect(AgentTask.start(state, 'plan', reuse: true).ok, isFalse);
      state = gate.check(state, 'understand').state;
      state = gate.check(state, 'parameters').state;
      final valid = profile
          .scope(catalog)
          .where((d) => gate.actionProblem(state, d.id) == null)
          .take(3)
          .map((d) => d.id)
          .toList();
      state = gate
          .check(
            state.copyWith(seenActionIds: valid.toSet()),
            'actions',
            picks: valid,
          )
          .state;
      state = gate.completeOutput(state).state;
      final reused = AgentTask.start(state, 'plan', reuse: true);
      expect(reused.ok, isTrue);
      expect(reused.state.picks, valid);
      expect(
        reused.state.task!.nodes.take(3).map((n) => n.toJson()),
        state.task!.nodes.take(3).map((n) => n.toJson()),
      );
      expect(reused.state.task!.nodes[3].status, 'current');
    },
  );

  test('English provenance and unknown host limit remain visible', () {
    var state = initial().copyWith(
      hostValues: {
        'limitsOpaque': ['limit.u_1234'],
      },
    );
    state = AgentTask.start(state, 'plan').state;
    state = gate.check(state, 'understand', language: 'en').state;
    state = gate.check(state, 'parameters', language: 'en').state;
    expect(state.task!.nodes[1].stamp, contains('Home (app setting)'));
    final valid = profile
        .scope(catalog)
        .where((d) => gate.actionProblem(state, d.id) == null)
        .take(3)
        .map((d) => d.id)
        .toList();
    final result = gate.check(
      state.copyWith(seenActionIds: valid.toSet()),
      'actions',
      picks: valid,
    );
    expect(result.ok, isTrue);
    expect(result.warnings, isNotEmpty);
    expect(result.state.hostValues['limitsOpaque'], ['limit.u_1234']);
  });

  test('starting another task preserves historical plan versions', () {
    final version = CoachPlanVersion(
      version: 1,
      plan: {'title': 'old'},
      estimateSec: 600,
      fitLog: const [],
    );
    final state = initial().copyWith(
      plans: {
        'previous': [version],
      },
    );
    final next = AgentTask.start(state, 'recommend').state;
    expect(next.plans['previous']!.single.plan['title'], 'old');
  });
}
