import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/plan/coach_context.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final params = SessionParams(ActionTags(profile, catalog));
  final gate = NodeGates(profile, catalog, minPicks: profile.minActions);
  CoachSessionState base([int minutes = 20]) => CoachSessionState(
    userTurns: [const CoachUserTurn(turn: 1, text: '先做20分钟')],
    params: {
      'minutes': CoachParamValue(
        value: minutes,
        source: 'user',
        quote: '20分钟',
        turn: 1,
      ),
    },
  );
  ParamMutation derived(
    CoachSessionState state,
    Object value, {
    String direction = 'shorter',
    String quote = '短一点',
  }) => params.set(state, {
    'fields': {
      'minutes': {
        'value': value,
        'source': 'derived',
        'quote': quote,
        'direction': direction,
      },
    },
  });

  test(
    'shorter and longer candidates respect 20–50%, profile range and five-minute steps',
    () {
      final state = base().appendUserTurn('短一点');
      for (final value in [10, 15]) {
        expect(derived(state, value).ok, isTrue, reason: '$value');
      }
      final longer = base().appendUserTurn('长一点');
      for (final value in [25, 30]) {
        expect(
          derived(longer, value, direction: 'longer', quote: '长一点').ok,
          isTrue,
          reason: '$value',
        );
      }
      for (final value in [5, 20, 25, 15.0]) {
        final result = derived(state, value);
        expect(result.ok, isFalse, reason: '$value');
        expect(result.error!['code'], 'derived_out_of_range');
        expect(result.error!['fix'], contains('10–15'));
        expect(result.state.params['minutes']!.value, 20);
      }
      final ten = base(10).appendUserTurn('短一点');
      expect(derived(ten, 5).ok, isTrue);
      final limit = base(5).appendUserTurn('短一点');
      expect(derived(limit, 5).error!['fix'], contains('询问用户'));
    },
  );

  test('derived integer is rounded to the nearest five before validation', () {
    final shorter = base().appendUserTurn('短一点');
    for (final sample in [(13, 15), (12, 10), (8, 10)]) {
      final result = derived(shorter, sample.$1);
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.params['minutes']!.value, sample.$2);
      expect(result.state.params['minutes']!.basedOn!.value, 20);
    }
    expect(derived(shorter, 18).error!['code'], 'derived_out_of_range');
    expect(derived(shorter, 7).error!['code'], 'derived_out_of_range');
    final longer = base().appendUserTurn('长一点');
    final rounded = derived(longer, 27, direction: 'longer', quote: '长一点');
    expect(rounded.ok, isTrue, reason: '${rounded.error}');
    expect(rounded.state.params['minutes']!.value, 25);
    expect(derived(longer, 22, direction: 'longer', quote: '长一点').ok, isFalse);
  });

  test('ratio and admissible minutes are read from profile configuration', () {
    final configured = CoachProfile(
      id: 'test',
      appName: 'test',
      planRules: const PlanRules(
        derivedStep: DerivedStepRange(min: .25, max: .3),
      ),
      limits: const PlanLimits(minutes: IntRange(3, 25)),
    );
    final custom = SessionParams(ActionTags(configured, catalog));
    final state = base().appendUserTurn('长一点');
    final result = custom.set(state, {
      'fields': {
        'minutes': {
          'value': 25,
          'source': 'derived',
          'quote': '长一点',
          'direction': 'longer',
        },
      },
    });
    expect(result.ok, isTrue, reason: '${result.error}');
    final rejected = custom.set(state, {
      'fields': {
        'minutes': {
          'value': 30,
          'source': 'derived',
          'quote': '长一点',
          'direction': 'longer',
        },
      },
    });
    expect(rejected.error!['code'], 'derived_out_of_range');
    expect(rejected.error!['fix'], contains('25'));
  });

  test('derived requires a fresh quoted user turn and explicit direction', () {
    final noNew = derived(base(), 15, quote: '20分钟');
    expect(noNew.error!['code'], 'derived_quote_not_new');
    final state = base().appendUserTurn('短一点');
    expect(derived(state, 15, quote: '从未说过').error!['code'], 'quote_not_found');
    expect(derived(state, 15, quote: '...').error!['code'], 'invalid_quote');
    expect(
      derived(state, 15, direction: 'other').error!['code'],
      'invalid_direction',
    );
    expect(
      params.set(state, {
        'fields': {
          'minutes': {'value': 15, 'source': 'derived', 'quote': '短一点'},
        },
      }).error!['code'],
      'invalid_direction',
    );
    expect(
      params.set(state, {
        'fields': {
          'level': {
            'value': 1,
            'source': 'derived',
            'quote': '短一点',
            'direction': 'shorter',
          },
        },
      }).error!['code'],
      'invalid_source',
    );
    expect(
      params.set(state, {
        'fields': {
          'minutes': {
            'value': 15,
            'source': 'user',
            'quote': '短一点',
            'direction': 'shorter',
          },
        },
      }).error!['code'],
      'invalid_direction',
    );
    expect(
      derived(CoachSessionState().appendUserTurn('短一点'), 15).error!['code'],
      'derived_missing_baseline',
    );
  });

  test('a prior unused relative request cannot be reused in a later turn', () {
    final state = base().appendUserTurn('短一点').appendUserTurn('换部位');
    final result = derived(state, 15, quote: '短一点');
    expect(result.ok, isFalse);
    expect(result.error!['code'], 'derived_quote_not_new');
    expect(result.error!['fix'], contains('当前轮'));
    expect(result.state.params['minutes']!.value, 20);
    expect(result.valueChangedFields, isEmpty);
  });

  test(
    'derived preserves full source chain and delivered identifiers on roundtrip',
    () {
      final first = derived(base().appendUserTurn('短一点'), 15);
      expect(first.ok, isTrue);
      final entry = first.state.params['minutes']!;
      expect(entry.source, 'derived');
      expect(entry.quote, '短一点');
      expect(entry.direction, 'shorter');
      expect(entry.basedOn!.toJson(), base().params['minutes']!.toJson());
      final second = derived(
        first.state.appendUserTurn('再短一点'),
        10,
        quote: '再短一点',
      );
      expect(second.ok, isTrue, reason: '${second.error}');
      final version = CoachPlanVersion(
        version: 2,
        plan: {'title': '方案'},
        estimateSec: 600,
        fitLog: const [],
        createdAtTurn: 3,
        operation: 'edit',
      );
      final saved = second.state.copyWith(
        lastDeliveredPlanId: 'p',
        lastDeliveredVersion: 2,
        lastDeliveredTurn: 3,
        plans: {
          'p': [version],
        },
      );
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(saved.toJson())) as Map<String, Object?>,
      );
      expect(restored.toJson(), saved.toJson());
      expect(restored.params['minutes']!.basedOn!.basedOn!.value, 20);
      expect(restored.lastDeliveredPlanId, 'p');
      expect(restored.lastDeliveredVersion, 2);
      expect(restored.lastDeliveredTurn, 3);
      expect(restored.plans['p']!.single.createdAtTurn, 3);
      expect(restored.plans['p']!.single.operation, 'edit');
      final legacy = CoachSessionState.fromJson({
        'params': <String, Object?>{},
      });
      expect(legacy.lastDeliveredPlanId, isNull);
      expect(legacy.lastDeliveredVersion, isNull);
      expect(legacy.lastDeliveredTurn, isNull);
    },
  );

  test(
    'minute-only update preserves picks and actions, restarts planning and restamps',
    () {
      final changed = derived(base().appendUserTurn('短一点'), 15);
      final task = CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: [
          const CoachNodeState(id: 'understand', status: 'done'),
          const CoachNodeState(id: 'parameters', status: 'done'),
          const CoachNodeState(
            id: 'actions',
            status: 'done',
            stamp: '找到动作',
            doneAtTurn: 1,
          ),
          const CoachNodeState(
            id: 'planning',
            status: 'done',
            stamp: '旧计划',
            doneAtTurn: 1,
          ),
          const CoachNodeState(
            id: 'review',
            status: 'done',
            stamp: '已核对',
            doneAtTurn: 1,
          ),
          const CoachNodeState(
            id: 'output',
            status: 'done',
            stamp: '已交付',
            doneAtTurn: 1,
          ),
        ],
      );
      final version = CoachPlanVersion(
        version: 1,
        plan: const {},
        estimateSec: 1200,
        fitLog: const [],
        check: const {'ok': true},
        createdAtTurn: 1,
        operation: 'edit',
      );
      final input = changed.state.copyWith(
        task: task,
        picks: ['h-squat'],
        seenActionIds: {'h-squat'},
        plans: {
          'p': [version],
        },
      );
      final result = gate.parametersChanged(
        input,
        changedFields: changed.changedFields,
      );
      expect(result.state.picks, ['h-squat']);
      expect(result.state.seenActionIds, {'h-squat'});
      expect(result.state.task!.nodes.map((n) => n.status), [
        'done',
        'updated',
        'done',
        'current',
        'pending',
        'pending',
      ]);
      expect(result.state.task!.nodes[2].stamp, '找到动作');
      expect(
        result.state.task!.nodes[1].stamp,
        contains('15 分钟（按你说的“短一点”调整，原 20 分钟）'),
      );
      expect(result.state.plans['p']!.last.check, isNull);
      expect(result.state.plans['p']!.last.createdAtTurn, 1);
      expect(result.state.plans['p']!.last.operation, 'edit');
      final english = gate.parametersChanged(
        input,
        changedFields: {'minutes'},
        language: 'en',
      );
      expect(
        english.state.task!.nodes[1].stamp,
        contains('15 min (adjusted as you said “短一点”, previously 20 min)'),
      );
      final other = gate.parametersChanged(
        input,
        changedFields: {'minutes', 'scene'},
      );
      expect(other.state.task!.nodes[2].status, 'current');
      expect(other.state.task!.nodes[3].status, 'pending');
    },
  );

  test(
    'derived and another field fail atomically when direction is invalid',
    () {
      final state = base().appendUserTurn('短一点');
      final result = params.set(state, {
        'fields': {
          'minutes': {
            'value': 15,
            'source': 'derived',
            'quote': '短一点',
            'direction': 'shorter',
          },
          'level': {
            'value': 1,
            'source': 'derived',
            'quote': '短一点',
            'direction': 'shorter',
          },
        },
      });
      expect(result.ok, isFalse);
      expect(result.state.params['minutes']!.value, 20);
      expect(result.changedFields, isEmpty);
    },
  );
  test(
    'same-value host write updates provenance without restarting or invalidating the plan',
    () {
      final completed = CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: [
          const CoachNodeState(id: 'understand', status: 'done'),
          const CoachNodeState(id: 'parameters', status: 'done', stamp: '旧来源'),
          const CoachNodeState(id: 'actions', status: 'done', stamp: '找到动作'),
          const CoachNodeState(id: 'planning', status: 'done'),
          const CoachNodeState(id: 'review', status: 'done'),
          const CoachNodeState(id: 'output', status: 'done'),
        ],
      );
      CoachParamValue user(Object value) =>
          CoachParamValue(value: value, source: 'user', quote: '用户条件', turn: 1);
      final source = CoachSessionState(
        task: completed,
        userTurns: [const CoachUserTurn(turn: 1, text: '用户条件')],
        params: {
          'scene': user('home'),
          'equipment': user(['equip.chair', 'equip.mat']),
          'minutes': user(10),
          'goal': user(['purpose.stretch']),
        },
        picks: ['h-squat'],
        seenActionIds: {'h-squat'},
        plans: {
          'p': [
            CoachPlanVersion(
              version: 1,
              plan: const {},
              estimateSec: 600,
              fitLog: const [],
              check: const {'ok': true},
            ),
          ],
        },
      );
      final mutation = params.applyHost(
        source,
        const CoachContext(
          scene: 'home',
          equipment: {'mat', 'chair'},
          minutes: 10,
        ),
      );
      expect(mutation.changedFields, {'scene', 'equipment', 'minutes'});
      expect(mutation.valueChangedFields, isEmpty);
      expect(mutation.state.params['scene']!.source, 'host');
      final refreshed = gate.parametersChanged(
        mutation.state,
        changedFields: mutation.changedFields,
        valueChangedFields: mutation.valueChangedFields,
      );
      expect(refreshed.changes.map((node) => node.id), ['parameters']);
      expect(refreshed.state.task!.nodes.map((node) => node.status), [
        'done',
        'updated',
        'done',
        'done',
        'done',
        'done',
      ]);
      expect(refreshed.state.task!.nodes[1].stamp, contains('居家（App 设置）'));
      expect(refreshed.state.picks, ['h-squat']);
      expect(refreshed.state.plans['p']!.last.check!['ok'], isTrue);
      final next = params.set(refreshed.state.appendUserTurn('长一点'), {
        'fields': {
          'minutes': {
            'value': 15,
            'source': 'derived',
            'direction': 'longer',
            'quote': '长一点',
          },
        },
      });
      expect(next.ok, isTrue, reason: '${next.error}');
      expect(next.valueChangedFields, {'minutes'});
      final adjusted = gate.parametersChanged(
        next.state,
        changedFields: next.changedFields,
        valueChangedFields: next.valueChangedFields,
      );
      expect(adjusted.state.task!.nodes.map((node) => node.status), [
        'done',
        'updated',
        'done',
        'current',
        'pending',
        'pending',
      ]);
      expect(adjusted.state.picks, ['h-squat']);
      expect(adjusted.state.plans['p']!.last.check, isNull);

      final changedScene = params.applyHost(
        source,
        const CoachContext(
          scene: 'office',
          equipment: {'mat', 'chair'},
          minutes: 10,
        ),
      );
      expect(changedScene.valueChangedFields, {'scene'});
      final reset = gate.parametersChanged(
        changedScene.state,
        changedFields: changedScene.changedFields,
        valueChangedFields: changedScene.valueChangedFields,
      );
      expect(reset.state.task!.nodes[2].status, 'current');
    },
  );
}
