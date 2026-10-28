import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

CoachParamValue _param(Object value, [String source = 'user']) =>
    CoachParamValue(value: value, source: source, turn: 1);

Map<String, Object?> _exclude(
  List<String> value,
  String quote, {
  String source = 'user',
}) => {
  'fields': {
    'equipment_exclude': {'value': value, 'source': source, 'quote': quote},
  },
};

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final gate = NodeGates(profile, catalog, minPicks: 3);
  final params = SessionParams(ActionTags(profile, catalog));

  CoachSessionState state({String? scene = 'home'}) => CoachSessionState(
    params: {
      if (scene != null) 'scene': _param(scene),
      'equipment': _param(<String>[]),
      'goal': _param(['purpose.stretch']),
      'minutes': _param(10),
      'level': _param(1),
      'limits': _param(<String>[]),
    },
  );

  test(
    'all published profiles configure scene ambient items and round trip',
    () {
      for (final id in ['smartfit', 'hiplab', 'flarelab']) {
        final configured = loadProfile(id);
        expect(configured.ambientEquipment['home'], {
          'equip.mat',
          'equip.wall',
          'equip.chair',
        });
        expect(configured.ambientEquipment['office'], {
          'equip.chair',
          'equip.wall',
        });
        expect(configured.ambientEquipment['gym'], {
          'equip.mat',
          'equip.wall',
          'equip.chair',
        });
        expect(configured.ambientEquipmentUnknown, {'equip.wall', 'equip.mat'});
        final restored = CoachProfile.fromJson(configured.toJson());
        expect(restored.ambientEquipment, configured.ambientEquipment);
        expect(
          restored.ambientEquipmentUnknown,
          configured.ambientEquipmentUnknown,
        );
      }
    },
  );

  test('bodyweight admission includes environmental items, not extra gear', () {
    expect(gate.effectiveEquipment(state()), {
      'equip.mat',
      'equip.wall',
      'equip.chair',
    });
    expect(gate.ambientEquipment(state(scene: 'office')), {
      'equip.chair',
      'equip.wall',
    });
    expect(gate.ambientEquipment(state(scene: null)), {
      'equip.wall',
      'equip.mat',
    });
    final mat = profile
        .scope(catalog)
        .firstWhere(
          (drill) =>
              drill.scenes.contains('home') && drill.equipment.contains('mat'),
        );
    expect(gate.actionProblem(state(), mat.id), isNull);
    final dumbbell = profile
        .scope(catalog)
        .firstWhere(
          (drill) =>
              drill.scenes.contains('home') &&
              drill.equipment.contains('dumbbell'),
        );
    expect(gate.actionProblem(state(), dumbbell.id), '器械不符合');
    final extra = Map<String, CoachParamValue>.of(state().params)
      ..['equipment'] = _param(['equip.dumbbell']);
    expect(
      gate.actionProblem(state().copyWith(params: extra), dumbbell.id),
      isNull,
    );
  });

  test(
    'explicit exclusions require a fresh quote and only reduce equipment',
    () {
      var current = state().appendUserTurn('我不使用垫子');
      for (final source in ['default', 'preselect', 'derived']) {
        expect(
          params
              .set(current, _exclude(['equip.mat'], '不使用垫子', source: source))
              .error!['code'],
          'invalid_source',
        );
      }
      final excluded = params.set(current, _exclude(['equip.mat'], '不使用垫子'));
      expect(excluded.ok, isTrue, reason: '${excluded.error}');
      current = excluded.state;
      expect(gate.effectiveEquipment(current), {'equip.wall', 'equip.chair'});
      final mat = profile
          .scope(catalog)
          .firstWhere(
            (drill) =>
                drill.scenes.contains('home') &&
                drill.equipment.contains('mat'),
          );
      expect(gate.actionProblem(current, mat.id), '器械不符合');
      current = current.appendUserTurn('我现在也不使用椅子');
      expect(
        params
            .set(current, _exclude(['equip.mat', 'equip.chair'], '不使用垫子'))
            .error!['code'],
        'equipment_exclude_quote_not_new',
      );
      final increased = params.set(
        current,
        _exclude(['equip.mat', 'equip.chair'], '不使用椅子'),
      );
      expect(increased.ok, isTrue, reason: '${increased.error}');
      expect(gate.effectiveEquipment(increased.state), {'equip.wall'});
      final relaxed = params.set(
        increased.state.appendUserTurn('现在可以用垫子'),
        _exclude(['equip.chair'], '可以用垫子'),
      );
      expect(relaxed.error!['code'], 'equipment_exclude_cannot_relax');
      final restored = CoachSessionState.fromJson(increased.state.toJson());
      expect(restored.toJson(), increased.state.toJson());
      expect(gate.effectiveEquipment(restored), {'equip.wall'});
    },
  );

  test(
    'known exclusion overrides both ledger and environmental availability',
    () {
      final source = state().appendUserTurn('不用椅子');
      final owned = Map<String, CoachParamValue>.of(source.params)
        ..['equipment'] = _param(['equip.chair', 'equip.dumbbell']);
      final updated = params.set(
        source.copyWith(params: owned),
        _exclude(['equip.chair'], '不用椅子'),
      );
      expect(updated.ok, isTrue);
      expect(gate.effectiveEquipment(updated.state), {
        'equip.mat',
        'equip.wall',
        'equip.dumbbell',
      });
      expect(
        gate.effectiveEquipment(updated.state),
        isNot(contains('equip.chair')),
      );
    },
  );

  test(
    'excluding nonambient extra equipment is ignored without changing ledger',
    () {
      final source = state().appendUserTurn('这次不用哑铃');
      final owned = Map<String, CoachParamValue>.of(source.params)
        ..['equipment'] = _param(['equip.dumbbell']);
      final excluded = params.set(
        source.copyWith(params: owned),
        _exclude(['equip.dumbbell'], '不用哑铃'),
      );
      expect(excluded.ok, isTrue);
      expect(gate.effectiveEquipment(excluded.state), {
        'equip.mat',
        'equip.wall',
        'equip.chair',
        'equip.dumbbell',
      });
      expect(excluded.ignoredEquipmentExclude, ['equip.dumbbell']);
      final missingQuote = params.set(source, {
        'fields': {
          'equipment_exclude': {
            'value': ['equip.mat'],
            'source': 'user',
          },
        },
      });
      expect(missingQuote.error!['code'], 'invalid_quote');
    },
  );

  test(
    'parameter stamp lists ambient items for bodyweight in each language',
    () {
      var current = AgentTask.start(state(), 'plan').state;
      current = gate.check(current, 'understand').state;
      final checked = gate.check(current, 'parameters');
      expect(checked.ok, isTrue);
      final stamp = checked.state.task!.nodes[1].stamp!;
      expect(stamp, contains('徒手（可用'));
      expect(stamp, contains('墙'));
      expect(stamp, contains('椅'));
      expect(stamp, isNot(contains('equip.')));
      final english = gate.check(current, 'parameters', language: 'en');
      final englishStamp = english.state.task!.nodes[1].stamp!;
      expect(englishStamp, contains('Bodyweight ('));
      expect(englishStamp, contains('available)'));
      expect(englishStamp, isNot(contains('equip.')));
    },
  );

  test('new exclusions reset actions and remove newly incompatible picks', () {
    var current = AgentTask.start(state(), 'plan').state;
    current = gate.check(current, 'understand').state;
    current = gate.check(current, 'parameters').state;
    final mat = profile
        .scope(catalog)
        .firstWhere(
          (drill) =>
              gate.actionProblem(current, drill.id) == null &&
              drill.equipment.contains('mat'),
        );
    final ids = {
      mat.id,
      ...profile
          .scope(catalog)
          .where((drill) => gate.actionProblem(current, drill.id) == null)
          .map((drill) => drill.id),
    }.take(3).toList();
    current = current.copyWith(seenActionIds: ids.toSet());
    current = gate.check(current, 'actions', picks: ids).state;
    current = current.appendUserTurn('这次不用垫子');
    final mutation = params.set(current, _exclude(['equip.mat'], '不用垫子'));
    expect(mutation.ok, isTrue);
    final updated = gate.parametersChanged(
      mutation.state,
      changedFields: mutation.changedFields,
      valueChangedFields: mutation.valueChangedFields,
    );
    expect(updated.state.task!.nodes[1].status, 'updated');
    expect(updated.state.task!.nodes[2].status, 'current');
    expect(updated.state.picks, isNot(contains(mat.id)));
    expect(updated.state.task!.nodes[1].stamp, contains('不使用：'));
  });

  test('check_plan uses the same ambient and explicit exclusion admission', () {
    final configured = loadProfile('hiplab');
    final raw = planOf(okEnvelope())..['id'] = 'ambient-plan';
    final plan = const PlanCodec().decode(raw);
    final review = CoachTaskState(
      type: 'plan',
      reused: false,
      nodes: [
        for (final id in AgentTask.planNodes)
          CoachNodeState(
            id: id,
            status: id == 'review'
                ? 'current'
                : id == 'output'
                ? 'pending'
                : 'done',
          ),
      ],
    );
    final source = state().copyWith(
      task: review,
      activePlanId: plan.id,
      plans: {
        plan.id: [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: 600,
            fitLog: const [],
          ),
        ],
      },
    );
    final checker = PlanChecker(configured, catalog, minPicks: 3);
    final admitted = checker.check(source, plan.id);
    expect((admitted.rules['equipment'] as Map)['ok'], isTrue);
    expect(admitted.ok, isTrue, reason: '${admitted.errors}');
    final withoutMat = Map<String, CoachParamValue>.of(source.params)
      ..['equipment_exclude'] = _param(['equip.mat']);
    final excluded = checker.check(
      source.copyWith(params: withoutMat),
      plan.id,
    );
    expect((excluded.rules['equipment'] as Map)['ok'], isFalse);
    expect(
      excluded.errors.any((error) => error['code'] == 'plan_equipment'),
      isTrue,
    );
  });
}
