import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _sample() => {
  'userTurns': [
    {'turn': 1, 'text': '  在家，徒手！\n'},
    {'turn': 2, 'text': ' 初学者，20分钟 '},
  ],
  'task': {
    'type': 'plan',
    'reused': true,
    'nodes': [
      {'id': 'understand', 'status': 'done', 'stamp': '计划', 'doneAtTurn': 1},
      {
        'id': 'parameters',
        'status': 'updated',
        'stamp': '徒手（你说的）',
        'doneAtTurn': 2,
      },
      {'id': 'actions', 'status': 'current', 'stamp': null, 'doneAtTurn': null},
      {
        'id': 'planning',
        'status': 'pending',
        'stamp': null,
        'doneAtTurn': null,
      },
    ],
  },
  'params': {
    'scene': {'value': 'home', 'source': 'user', 'quote': '在家', 'turn': 1},
    'goal': {
      'value': ['body.core', 'purpose.strength'],
      'source': 'host',
      'turn': 0,
    },
    'equipment': {
      'value': <String>[],
      'source': 'user',
      'quote': '徒手',
      'turn': 1,
    },
    'minutes': {'value': 20, 'source': 'user', 'quote': '20分钟', 'turn': 2},
    'level': {'value': 1, 'source': 'preselect', 'turn': 2},
    'limits': {'value': <String>[], 'source': 'default', 'turn': 2},
  },
  'seenActionIds': ['a', 'b', 'c'],
  'picks': ['c', 'a', 'b'],
  'plans': {
    'plan-1': [
      {
        'version': 1,
        'plan': {
          'id': 'plan-1',
          'blocks': [
            {
              'rounds': 2,
              'items': [
                {
                  'id': 'a',
                  'segments': [
                    {'id': 'part-1', 'workSeconds': 25},
                  ],
                },
              ],
            },
          ],
        },
        'estimateSec': 1180.5,
        'fitLog': ['主体由1轮加到2轮'],
        'check': {
          'ok': false,
          'errors': [
            {'code': 'focus', 'expected': 0.5, 'actual': 0.3},
          ],
        },
      },
      {
        'version': 2,
        'plan': {'id': 'plan-1', 'blocks': <Object?>[]},
        'estimateSec': 1200,
        'fitLog': <String>[],
        'check': null,
      },
    ],
    'plan-2': <Object?>[],
  },
};

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');

  CoachAgent agent(FakeLlmClient client) {
    final result = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
    );
    addTearDown(result.dispose);
    return result;
  }

  ValidatedPlan admittedPlan() {
    final plan = TrainingPlan(
      id: 'plan-1',
      source: 'ai',
      title: '髋部放松',
      summary: '放松髋部',
      goal: 'relax',
      scene: 'home',
      equipment: const ['mat'],
      level: 1,
      targetMinutes: 10,
      blocks: const [
        PlanBlock(
          id: 'main',
          name: '训练',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: 's-figure4',
              mode: DoseMode.time,
              sets: 1,
              workSeconds: 40,
              perSide: true,
              restSeconds: 10,
            ),
          ],
        ),
      ],
    );
    final result = ToolGate(catalog: catalog, profile: profile).admitTemplate(
      plan,
      const CoachContext(scene: 'home', equipment: {'mat'}, minutes: 10),
    );
    final report = PlanValidator(catalog: catalog, profile: profile).validate(
      plan,
      const CoachContext(scene: 'home', equipment: {'mat'}, minutes: 10),
    );
    expect(result, isNotNull, reason: '${report.errors}');
    return result!;
  }

  test('session JSON round trips all fields without losing nested data', () {
    final original = _sample();
    final state = CoachSessionState.fromJson(original);
    final serialized = jsonDecode(jsonEncode(state.toJson()));
    final restored = CoachSessionState.fromJson(
      (serialized as Map<String, Object?>),
    );
    expect(restored.toJson(), original);
  });

  test('nested input, exports and snapshots cannot mutate saved state', () {
    final original = _sample();
    final state = CoachSessionState.fromJson(original);
    final expected = jsonDecode(jsonEncode(original));
    final params = original['params']! as Map<String, Object?>;
    final goal = params['goal']! as Map<String, Object?>;
    (goal['value']! as List<String>).add('body.fabricated');
    final exported = state.toJson();
    (exported['picks']! as List<String>).clear();
    final plan = state.plans['plan-1']!.first.plan;
    expect(() => plan['id'] = 'changed', throwsUnsupportedError);
    expect(
      () => (state.params['goal']!.value! as List<Object?>).add('bad'),
      throwsUnsupportedError,
    );
    expect(state.toJson(), expected);
  });

  test(
    'plan state persists and restores the complete session when IDs match',
    () {
      final admitted = admittedPlan();
      final session = CoachSessionState.fromJson(_sample());
      final saved = CoachPlanState(
        planId: admitted.plan.id,
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
        ),
        sessionState: session,
      );
      final wire =
          jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>;
      final restored = CoachPlanState.fromJson(wire);
      final coach = agent(FakeLlmClient(const []));
      final controller = CoachConversationController(agent: coach);
      addTearDown(controller.dispose);
      controller.restoreHistory([
        CoachConversationMessage(
          id: 'card',
          at: DateTime.utc(2026),
          plan: admitted,
          planState: restored,
        ),
      ]);
      expect(coach.sessionState.toJson(), session.toJson());
      expect(coach.sessionState.params['goal']!.source, 'host');
      expect(coach.sessionState.params['goal']!.turn, 0);
      expect(
        coach.planStateFor(admitted).sessionState!.toJson(),
        session.toJson(),
      );
    },
  );

  test(
    'legacy and mismatched plan snapshots do not import unrelated state',
    () {
      final admitted = admittedPlan();
      final old = CoachPlanState.fromJson({
        'planId': admitted.plan.id,
        'context': {
          'scene': 'home',
          'equipment': ['mat'],
          'minutes': 10,
        },
      });
      expect(old.sessionState, isNull);
      expect(old.toJson().containsKey('sessionState'), isFalse);

      final coach = agent(FakeLlmClient(const []));
      final unrelated = CoachPlanState(
        planId: 'unrelated-plan',
        sessionState: CoachSessionState.fromJson(_sample()),
      );
      coach.restorePlan(admitted, planState: unrelated);
      expect(coach.sessionState.userTurns, isEmpty);
      expect(coach.sessionState.task, isNull);
      expect(coach.sessionState.params['goal'], isNull);
      expect(coach.sessionState.params['scene']!.value, admitted.plan.scene);
      expect(coach.sessionState.params['minutes']!.value, admitted.plan.targetMinutes);
      expect(coach.sessionState.params.values.every((p) => p.source == 'host'), isTrue);
    },
  );

  test(
    'controller records each original input once with its sequence',
    () async {
      final coach = agent(
        FakeLlmClient(['你好。', '可以。'], latency: Duration.zero),
      );
      final controller = CoachConversationController(agent: coach);
      addTearDown(controller.dispose);
      expect((await controller.send('  你好！\n'))?.status, TurnStatus.ok);
      expect((await controller.send('\t谢谢  '))?.status, TurnStatus.ok);
      expect(
        coach.sessionState.userTurns.map((turn) => turn.toJson()).toList(),
        [
          {'turn': 1, 'text': '  你好！\n'},
          {'turn': 2, 'text': '\t谢谢  '},
        ],
      );
    },
  );

  test('busy, cancellation and reset do not append a phantom turn', () async {
    final pendingModel = Completer<Object>();
    final client = FakeLlmClient([
      (LlmRequest _) => pendingModel.future,
      '可以。',
    ], latency: Duration.zero);
    final coach = agent(client);
    final token = CancelToken();
    final pending = coach.send('  等待中的输入  ', cancel: token);
    await Future<void>.delayed(Duration.zero);
    expect((await coach.send('不能排队')).status, TurnStatus.busy);
    expect(coach.sessionState.userTurns, hasLength(1));
    token.cancel();
    expect((await pending).status, TurnStatus.cancelled);
    expect(coach.sessionState.userTurns, isEmpty);
    pendingModel.complete('迟到回复');

    expect((await coach.send('  实际第二次  ')).status, TurnStatus.ok);
    expect(coach.sessionState.userTurns.single.toJson(), {
      'turn': 1,
      'text': '  实际第二次  ',
    });
    coach.reset();
    expect(coach.sessionState.userTurns, isEmpty);
  });
}
