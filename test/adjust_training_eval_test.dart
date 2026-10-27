import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

// This suite exercises the real CoachAgent/Controller and the released
// Pose-Hub catalog. FakeLlmClient supplies scripted model replies; passing it
// does not establish real-model quality or native SmartFit behavior.
Map<String, Object?> _item(
  String id,
  String mode, {
  int sets = 1,
  int? reps,
  int? seconds,
  bool perSide = false,
  int rest = 0,
}) => {
  'exerciseId': id,
  'mode': mode,
  'sets': sets,
  'reps': ?reps,
  'workSeconds': ?seconds,
  'perSide': perSide,
  'restSeconds': rest,
};

Map<String, Object?> _plan({
  required String scene,
  required int minutes,
  required List<String> equipment,
  required List<Map<String, Object?>> items,
  int rounds = 1,
}) => {
  'schemaVersion': 1,
  'title': '髋部放松训练',
  'summary': '按已确认条件安排',
  'goal': 'relax',
  'scene': scene,
  'level': 1,
  'targetMinutes': minutes,
  'equipment': equipment,
  'blocks': [
    {
      'id': 'main',
      'name': '训练',
      'type': 'main',
      'rounds': rounds,
      'restBetweenRoundsSeconds': 15,
      'items': items,
    },
  ],
};

Map<String, Object?> _initialPlan() => _plan(
  scene: 'home',
  minutes: 10,
  equipment: ['mat'],
  items: [
    _item(
      's-kneel-hipflex',
      'time',
      sets: 2,
      seconds: 60,
      perSide: true,
      rest: 60,
    ),
    _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 60),
  ],
);

Map<String, Object?> _sevenMinutes() => _plan(
  scene: 'home',
  minutes: 7,
  equipment: ['mat'],
  items: [
    _item(
      's-kneel-hipflex',
      'time',
      sets: 2,
      seconds: 60,
      perSide: true,
      rest: 30,
    ),
    _item('s-butterfly', 'time', seconds: 80),
  ],
);

Map<String, Object?> _twentyMinutes() => _plan(
  scene: 'home',
  minutes: 20,
  equipment: ['mat'],
  rounds: 3,
  items: [
    _item('s-kneel-hipflex', 'time', seconds: 60, perSide: true),
    _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 60),
  ],
);

Map<String, Object?> _relativeShort() => _plan(
  scene: 'home',
  minutes: 5,
  equipment: ['mat'],
  items: [
    _item('s-kneel-hipflex', 'time', seconds: 60, perSide: true),
    _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 10),
  ],
);

Map<String, Object?> _relativeLong() => _plan(
  scene: 'home',
  minutes: 19,
  equipment: ['mat'],
  rounds: 3,
  items: [
    _item('s-kneel-hipflex', 'time', seconds: 60, perSide: true),
    _item('s-butterfly', 'time', sets: 2, seconds: 80, rest: 60),
  ],
);

Map<String, Object?> _bodyweight({String scene = 'home'}) => _plan(
  scene: scene,
  minutes: 10,
  equipment: [],
  items: scene == 'office'
      ? [
          _item('h-step-jack', 'time', sets: 3, seconds: 80, rest: 30),
          _item(
            'o-stand-sidebend',
            'time',
            sets: 2,
            seconds: 60,
            perSide: true,
            rest: 60,
          ),
        ]
      : [
          _item('h-squat', 'reps', sets: 4, reps: 18, rest: 30),
          _item(
            'adductors-A',
            'reps',
            sets: 3,
            reps: 8,
            perSide: true,
            rest: 20,
          ),
        ],
);

var _sequence = 0;
Map<String, Object?> _user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};
LlmResponse _set(Map<String, Object?> fields) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'adjust-params-${_sequence++}',
      name: AgentTools.setParams,
      arguments: jsonEncode({'fields': fields}),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);
LlmResponse _initialFacts() => _set({
  'scene': _user('home', '在家'),
  'equipment': _user(['equip.mat'], '瑜伽垫'),
  'minutes': _user(10, '10分钟'),
});
LlmResponse _show(Map<String, Object?> plan) => LlmResponse(
  content: '这里是调整后的方案。',
  toolCalls: [
    LlmToolCall(
      id: 'adjust-eval-${_sequence++}',
      name: AgentTools.showPlan,
      arguments: jsonEncode(plan),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  final fixture =
      jsonDecode(File('eval/cases/adjust_training_r2.json').readAsStringSync())
          as Map<String, Object?>;
  final cases = <String, Map<String, Object?>>{
    for (final entry
        in (fixture['cases']! as List<Object?>).cast<Map<String, Object?>>())
      entry['id']! as String: entry,
  };
  String turn(String id, int n) =>
      (((cases[id]!['turns']! as List<Object?>)[n]!
              as Map<String, Object?>)['text']!
          as String);
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final app = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  );
  final catalog = app.toAiCatalog();
  final profile = loadProfile('smartfit');
  final duration = const PlanDuration();

  CoachConversationController controller(FakeLlmClient client) {
    final value = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(value.dispose);
    return value;
  }

  Future<TrainingPlan> begin(CoachConversationController c, String id) async {
    final first = await c.send(turn(id, 0));
    expect(first!.question, isNull);
    expect(
      first.plan,
      isNotNull,
      reason: 'initial issues: ${first.issues}; error: ${first.error}',
    );
    return first.plan!.plan;
  }

  test(
    'fixture records six adjustments without claiming real-model evaluation',
    () {
      expect(fixture['mode'], 'offline-scripted-protocol');
      expect(cases.keys.toSet(), {
        'shorten_to_7',
        'extend_to_20',
        'relative_shorter',
        'relative_longer',
        'switch_bodyweight',
        'switch_scene_bodyweight',
      });
    },
  );

  test('scripted adjustment plans use catalogue doses and stay within 10%', () {
    const homeMat = CoachContext(scene: 'home', equipment: {'mat'});
    const homeBodyweight = CoachContext(scene: 'home', equipment: {});
    const officeBodyweight = CoachContext(scene: 'office', equipment: {});
    for (final (raw, context) in [
      (_initialPlan(), homeMat),
      (_sevenMinutes(), homeMat),
      (_twentyMinutes(), homeMat),
      (_relativeShort(), homeMat),
      (_relativeLong(), homeMat),
      (_bodyweight(), homeBodyweight),
      (_bodyweight(scene: 'office'), officeBodyweight),
    ]) {
      final plan = const PlanCodec().decode(raw);
      final checked = PlanValidator(
        catalog: catalog,
        profile: profile,
        enforceDrillDoseRange: true,
      ).validate(plan, context);
      expect(
        checked.errors,
        isEmpty,
        reason: '${plan.targetMinutes}: ${checked.errors}',
      );
      expect(
        (duration.estimateSeconds(plan, catalog) / 60 - plan.targetMinutes)
                .abs() /
            plan.targetMinutes,
        lessThanOrEqualTo(.10),
        reason: '${plan.targetMinutes}-minute scripted plan',
      );
    }
  });

  for (final sample in [
    ('shorten_to_7', 7, _sevenMinutes),
    ('extend_to_20', 20, _twentyMinutes),
  ]) {
    test(
      '${sample.$1}: explicit time overrides the previous 10-minute target',
      () async {
        final client = FakeLlmClient([
          _initialFacts(),
          _show(_initialPlan()),
          _set({'minutes': _user(sample.$2, '${sample.$2} 分钟')}),
          _show(_initialPlan()),
          _show(sample.$3()),
        ]);
        final c = controller(client);
        await begin(c, sample.$1);
        final result = await c.send(
          turn(sample.$1, 1),
          context: const CoachContext(
            scene: 'home',
            equipment: {'mat'},
            minutes: 10,
          ),
        );
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: 'issues: ${result.issues}; error: ${result.error}',
        );
        final plan = result.plan!.plan;
        expect(plan.targetMinutes, sample.$2);
        expect(plan.scene, 'home');
        expect(plan.equipment, ['mat']);
        expect(
          (duration.estimateSeconds(plan, catalog) / 60 - sample.$2).abs() /
              sample.$2,
          lessThanOrEqualTo(.10),
        );
        expect(
          client.requests,
          hasLength(5),
          reason: 'old-target plan must be rejected and corrected',
        );
        expect(
          client.requests.last.messages
              .where((m) => m.role == LlmRole.tool)
              .any((m) => m.content.contains('targetMinutes')),
          isTrue,
        );
        expect(c.agent.lastConfirmedForm?['minutes'], [
          sample.$2 == 20 ? '20+ 分钟' : '${sample.$2} 分钟',
        ]);
      },
    );
  }

  for (final sample in [
    ('relative_shorter', _relativeShort, true),
    ('relative_longer', _relativeLong, false),
  ]) {
    test(
      '${sample.$1}: actual direction is respected within 10% of target',
      () async {
        final c = controller(
          FakeLlmClient([
            _initialFacts(),
            _show(_initialPlan()),
            _set({
              'minutes': _user(sample.$3 ? 5 : 19, sample.$3 ? '短一点' : '长一点'),
            }),
            _show(sample.$2()),
          ]),
        );
        final previous = await begin(c, sample.$1);
        final result = await c.send(
          turn(sample.$1, 1),
          context: const CoachContext(
            scene: 'home',
            equipment: {'mat'},
            minutes: 10,
          ),
        );
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: 'issues: ${result.issues}; error: ${result.error}',
        );
        final plan = result.plan!.plan;
        final before = duration.estimateSeconds(previous, catalog) / 60;
        final after = duration.estimateSeconds(plan, catalog) / 60;
        expect(after, sample.$3 ? lessThan(before) : greaterThan(before));
        expect(plan.targetMinutes, sample.$3 ? lessThan(10) : greaterThan(10));
        expect(
          (after - plan.targetMinutes).abs() / plan.targetMinutes,
          lessThanOrEqualTo(.10),
          reason: 'relative adjustments also meet the v2 duration tolerance',
        );
        expect(plan.scene, 'home');
        expect(plan.equipment, ['mat']);
      },
    );
  }

  for (final sample in [
    ('switch_bodyweight', 'home'),
    ('switch_scene_bodyweight', 'office'),
  ]) {
    test('${sample.$1}: new conditions replace the previous values', () async {
      final client = FakeLlmClient([
        _initialFacts(),
        _show(_initialPlan()),
        _set({
          if (sample.$2 == 'office') 'scene': _user('office', '办公室'),
          'equipment': _user(<String>[], '徒手'),
        }),
        _show(_initialPlan()),
        _show(_bodyweight(scene: sample.$2)),
      ]);
      final c = controller(client);
      await begin(c, sample.$1);
      final result = await c.send(
        turn(sample.$1, 1),
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
        ),
      );
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: 'issues: ${result.issues}; error: ${result.error}',
      );
      final plan = result.plan!.plan;
      expect(plan.scene, sample.$2);
      expect(plan.targetMinutes, 10);
      expect(plan.equipment, isEmpty);
      expect(
        plan.items.every((item) => catalog[item.exerciseId]!.equipment.isEmpty),
        isTrue,
      );
      expect(
        client.requests,
        hasLength(5),
        reason: 'old mat plan must be rejected',
      );
      expect(c.agent.lastConfirmedForm?['equipment'], ['徒手']);
    });
  }

  test(
    'retry after a failed explicit adjustment keeps the new 7-minute conditions',
    () async {
      final client = FakeLlmClient([
        _initialFacts(),
        _show(_initialPlan()),
        const LlmException(LlmErrorKind.network, 'offline'),
        _set({'minutes': _user(7, '7 分钟')}),
        // A stale retry response must be rejected against the pending edit,
        // even though the last successfully delivered plan is still 10 min.
        _show(_initialPlan()),
        _show(_sevenMinutes()),
      ]);
      final c = controller(client);
      await begin(c, 'shorten_to_7');
      final failed = await c.send(turn('shorten_to_7', 1));
      expect(failed!.status, TurnStatus.error);
      expect(failed.isPlanningFailure, isTrue);
      expect(c.agent.lastConfirmedForm?['minutes'], ['10 分钟']);
      final retried = await c.send('重试');
      expect(retried!.question, isNull);
      expect(
        retried.plan,
        isNotNull,
        reason: 'issues: ${retried.issues}; error: ${retried.error}',
      );
      expect(retried.plan!.plan.targetMinutes, 7);
      expect(retried.plan!.plan.equipment, ['mat']);
      expect(c.agent.lastConfirmedForm?['minutes'], ['7 分钟']);
      expect(client.requests, hasLength(6));
      expect(client.requests[3].messages.last.content, contains('缩短到 7 分钟'));
      expect(
        client.requests.last.messages
            .where((m) => m.role == LlmRole.tool)
            .any((m) => m.content.contains('targetMinutes')),
        isTrue,
      );
    },
  );
}
