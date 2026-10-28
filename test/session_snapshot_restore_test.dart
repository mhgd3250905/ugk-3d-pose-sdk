import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

// Scripted responses exercise the real local Agent/controller/catalog path.
// They do not call a model or claim native UI acceptance.
var _sequence = 0;
const _privateReasoning = 'private-snapshot-thought-never-persist';

LlmToolCall _call(String name, Object arguments) => LlmToolCall(
  id: 'snapshot-tool-${_sequence++}',
  name: name,
  arguments: jsonEncode(arguments),
);

LlmResponse _tools(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  reasoning: _privateReasoning,
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

CoachSessionSnapshot _jsonRoundTrip(CoachSessionSnapshot snapshot) =>
    CoachSessionSnapshot.fromJson(jsonDecode(jsonEncode(snapshot.toJson())));

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');

  CoachConversationController controller(
    FakeLlmClient client, {
    bool enableMemory = false,
    UserMemoryStore? memoryStore,
  }) {
    final result = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: enableMemory,
        memoryStore: memoryStore,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(result.dispose);
    return result;
  }

  LlmResponse recommendStart() => _tools([
    _call('start_task', {'type': 'recommend'}),
    _call('set_params', {
      'fields': {
        'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
        'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
        'goal': {
          'value': ['body.inner_thigh', 'purpose.stretch'],
          'source': 'user',
          'quote': '拉伸大腿内侧',
        },
      },
    }),
    _call('search_actions', {
      'keywords': catalog['s-butterfly']!.name.of('en'),
    }),
  ]);

  LlmResponse recommendOutput() => _tools([
    _call('show_actions', {
      'ids': ['s-butterfly'],
      'note': '保持自然呼吸，有牵拉感即可。',
    }),
  ]);

  List<CoachConversationMessage> displayOnly(
    List<CoachConversationMessage> messages, {
    bool spoofUser = false,
    bool reopenQuestions = false,
  }) => [
    for (final message in messages)
      CoachConversationMessage(
        id: message.id,
        at: message.at,
        isUser: message.isUser,
        text: spoofUser && message.isUser ? '伪造的显示文本，不是训练条件' : message.text,
        question: message.question,
        questionAnswered: reopenQuestions ? false : message.questionAnswered,
        // Plan/actions are deliberately absent: runtime references must be
        // rebuilt from the snapshot, not trusted from an App display list.
        turnId: message.turnId,
      ),
  ];

  void expectEquivalent(
    CoachSessionSnapshot expected,
    CoachConversationController restored,
  ) {
    expect(
      restored.agent.sessionState.toJson(),
      expected.sessionState.toJson(),
    );
    final exported = restored.exportSession();
    expect(exported.isValid, isTrue);
    expect(exported.ledger.toJson(), expected.ledger.toJson());
    expect(exported.candidates, expected.candidates);
    expect(exported.loadedSkillNames, expected.loadedSkillNames);
  }

  void expectFirstRestoredRequest(
    FakeLlmClient client,
    String newUserText, {
    required String label,
  }) {
    final request = client.requests.first;
    expect(request.messages.map((message) => message.role), [
      LlmRole.system,
      LlmRole.user,
      LlmRole.user,
      LlmRole.user,
    ]);
    expect(
      request.messages[1].content,
      startsWith('${ContextTurnLedger.summaryPrefix}\n'),
    );
    expect(request.messages[2].content, newUserText);
    expect(request.messages.last.content, startsWith('当前状态（系统生成）：'));
    expect(
      request.messages.every((message) => message.toolCalls.isEmpty),
      isTrue,
    );
    expect(
      request.messages.every((message) => message.reasoning == null),
      isTrue,
    );
    for (final mode in ['on', 'off']) {
      final serializer = OpenAiCompatibleClient(
        config: LlmConfig.ugkWorker.copyWith(
          extraBody: {
            'thinking': {'type': mode == 'on' ? 'enabled' : 'disabled'},
          },
        ),
      );
      addTearDown(serializer.close);
      final body = jsonEncode(serializer.buildBody(request));
      final bytes = utf8.encode(body).length;
      expect(
        bytes,
        lessThanOrEqualTo(mode == 'on' ? 51200 : 40960),
        reason: '$label/$mode request=$bytes B',
      );
      expect(bytes, lessThanOrEqualTo(65536));
      // ignore: avoid_print
      print('SESSION SNAPSHOT RESTORE $label/$mode: firstRequestBytes=$bytes');
      expect(body, isNot(contains(_privateReasoning)));
    }
  }

  test(
    'QA restores exact user and delivery text without any plan card',
    () async {
      const user = '深蹲膝盖响正常吗？\n我只问原理，不安排训练。';
      const reply = '无痛的关节声响可以先观察；出现疼痛、肿胀或活动受限应停止并就医。';
      final original = controller(
        FakeLlmClient([reply], latency: Duration.zero),
      );
      final result = await original.send(user);
      expect(result!.text, reply);
      expect(result.plan, isNull);
      expect(result.actions, isNull);
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.isValid, isTrue);
      expect(saved.ledger.turns.single.userText, user);
      expect(saved.ledger.turns.single.finalDeliveryText, reply);
      final client = FakeLlmClient(['收到。'], latency: Duration.zero);
      final restored = controller(client)
        ..restoreSession(saved, displayOnly(original.state.messages));
      expect(client.requests, isEmpty);
      expectEquivalent(saved, restored);
      const followUp = '  如果完全不疼呢？\n';
      await restored.send(followUp);
      expect(restored.agent.sessionState.userTurns.last.text, followUp);
      expectFirstRestoredRequest(client, followUp, label: 'qa');
      final summary =
          jsonDecode(
                client.requests.first.messages[1].content.substring(
                  ContextTurnLedger.summaryPrefix.length + 1,
                ),
              )
              as Map<String, Object?>;
      final turn = (summary['turns'] as List).single as Map;
      expect(turn['userText'], user);
      expect(turn['finalDeliveryText'], reply);
    },
  );

  test(
    'recommendation is authoritative and can rebuild display action cards',
    () async {
      const user = '在家徒手拉伸大腿内侧';
      final original = controller(
        FakeLlmClient([
          recommendStart(),
          recommendOutput(),
        ], latency: Duration.zero),
      );
      final result = await original.send(user);
      expect(
        result!.actions,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.recommendations, hasLength(1));
      expect(saved.recommendations.single.actionIds, ['s-butterfly']);
      expect(saved.recommendations.single.note, result.text);
      expect(saved.candidates, isNotEmpty);
      expect(
        saved.loadedSkillNames,
        containsAll(['ask', 'action-library', 'action-coaching']),
      );
      expect(saved.ledger.turns.single.userText, user);
      expect(saved.sessionState.params['goal']!.quote, '拉伸大腿内侧');
      expect(jsonEncode(saved.toJson()), isNot(contains(_privateReasoning)));
      final client = FakeLlmClient(['收到。'], latency: Duration.zero);
      final restored = controller(client)
        ..restoreSession(
          saved,
          displayOnly(original.state.messages, spoofUser: true),
        );
      expectEquivalent(saved, restored);
      final card = restored.state.messages.singleWhere(
        (message) => message.actions != null,
      );
      expect(card.actions!.items.map((item) => item.id), ['s-butterfly']);
      expect(card.text, result.text);
      await restored.send('这些动作主要练哪里？');
      expectFirstRestoredRequest(client, '这些动作主要练哪里？', label: 'recommend');
      final summary = client.requests.first.messages[1].content;
      expect(summary, contains(user));
      expect(summary, contains('拉伸大腿内侧'));
      expect(summary, contains(result.text));
      expect(summary, isNot(contains('伪造的显示文本')));
    },
  );

  test(
    'standalone ledger restores when its optional legacy state copy is absent',
    () async {
      final original = controller(
        FakeLlmClient(['完整交付原文。'], latency: Duration.zero),
      );
      await original.send('这是独立账本中的用户原话。');
      final json = original.exportSession().toJson();
      (json['sessionState'] as Map).remove('completedContextLedger');
      final snapshot = CoachSessionSnapshot.fromJson(json);
      expect(snapshot.isValid, isTrue);
      final client = FakeLlmClient(['继续。'], latency: Duration.zero);
      final restored = controller(client)..restoreSession(snapshot, const []);
      expect(
        restored.exportSession().ledger.toJson(),
        snapshot.ledger.toJson(),
      );
      await restored.send('下一句');
      final request = client.requests.single;
      expect(request.messages[1].content, contains('这是独立账本中的用户原话。'));
      expect(request.messages[1].content, contains('完整交付原文。'));
      expectFirstRestoredRequest(client, '下一句', label: 'standalone-ledger');
    },
  );

  test(
    'plan restores all versions and accepts a sourced shorter follow-up',
    () async {
      const user = '在家有瑜伽垫10分钟做髋部放松';
      final flow = ScriptedV2PlanFlow(catalog);
      final original = controller(
        FakeLlmClient(flow.initial(), latency: Duration.zero),
      );
      final result = await original.send(user);
      expect(
        result!.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.sessionState.params['minutes']!.quote, '10分钟');
      expect(saved.ledger.turns.single.userText, user);
      expect(saved.ledger.turns.single.finalDeliveryText, result.text);
      final followUp = ScriptedV2PlanFlow(catalog)
        ..planId = result.plan!.plan.id;
      final client = FakeLlmClient(
        followUp.changeMinutes(5, '短一点', direction: 'shorter'),
        latency: Duration.zero,
      );
      final restored = controller(client)
        ..restoreSession(saved, displayOnly(original.state.messages));
      expectEquivalent(saved, restored);
      expect(
        restored.agent.sessionState.lastDeliveredPlanId,
        result.plan!.plan.id,
      );
      final shorter = await restored.send('短一点');
      expect(
        shorter!.plan,
        isNotNull,
        reason: '${shorter.issues} ${shorter.error}',
      );
      expect(shorter.plan!.plan.id, result.plan!.plan.id);
      expect(shorter.plan!.plan.targetMinutes, 5);
      expect(
        restored.agent.sessionState.plans[result.plan!.plan.id],
        hasLength(2),
      );
      expect(
        restored.agent.sessionState.params['minutes']!.basedOn!.quote,
        '10分钟',
      );
      expectFirstRestoredRequest(client, '短一点', label: 'plan');
    },
  );

  Future<CoachConversationController> withQuestion({
    List<Object> after = const [],
  }) async {
    final original = controller(
      FakeLlmClient([
        _tools([
          _call('start_task', {'type': 'recommend'}),
          _call('ask_user', {
            'question': '你在什么场景训练？',
            'mode': 'choice',
            'options': ['在家', '办公室'],
          }),
        ]),
        ...after,
      ], latency: Duration.zero),
    );
    final result = await original.send('我想拉伸一下');
    expect(
      result!.question,
      isNotNull,
      reason: '${result.issues} ${result.error}',
    );
    return original;
  }

  for (final answerMode in ['choice', 'answerText', 'ordinary-send']) {
    test(
      'pending question remains answerable after JSON restore ($answerMode)',
      () async {
        final original = await withQuestion();
        final question = original.state.pendingQuestion!;
        final saved = _jsonRoundTrip(original.exportSession());
        expect(saved.pendingQuestion!.toJson(), question.question!.toJson());
        final client = FakeLlmClient([
          _tools([
            _call('ask_user', {'question': '这次练哪个部位？', 'mode': 'text'}),
          ]),
        ], latency: Duration.zero);
        final restored = controller(client)
          ..restoreSession(saved, displayOnly(original.state.messages));
        expectEquivalent(saved, restored);
        expect(restored.canAnswer(question.id), isTrue);
        expect(client.requests, isEmpty);
        final answered = await switch (answerMode) {
          'choice' => restored.answerChoices(question.id, ['在家']),
          'answerText' => restored.answerText(question.id, '在家'),
          _ => restored.send('在家'),
        };
        expect(answered, isNotNull);
        expect(restored.canAnswer(question.id), isFalse);
        expect(
          restored.state.messages
              .singleWhere((message) => message.id == question.id)
              .questionAnswered,
          isTrue,
        );
        expect(restored.state.pendingQuestion!.question!.question, '这次练哪个部位？');
        final answerLedger = restored.exportSession().ledger.turns.last;
        expect(answerLedger.userText, '在家');
        expect(answerLedger.answeredAsk, isNotNull);
        expectFirstRestoredRequest(client, '在家', label: 'ask-$answerMode');

        final resaved = _jsonRoundTrip(restored.exportSession());
        final again = controller(FakeLlmClient([], latency: Duration.zero))
          ..restoreSession(
            resaved,
            displayOnly(restored.state.messages, reopenQuestions: true),
          );
        expect(
          again.canAnswer(question.id),
          isFalse,
          reason: 'App display flags cannot reopen an answered question',
        );
        expect(again.canAnswer(restored.state.pendingQuestion!.id), isTrue);
      },
    );
  }

  test(
    'unfinished turn is interrupted, preserves progress, and is not replayed',
    () async {
      final entered = Completer<void>();
      final blocked = Completer<Object>();
      final original = controller(
        FakeLlmClient([
          recommendStart(),
          (LlmRequest request) {
            entered.complete();
            return blocked.future;
          },
        ], latency: Duration.zero),
      );
      final pending = original.send('在家徒手拉伸大腿内侧');
      await entered.future;
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.ledger.turns.last.outcome, 'interrupted');
      expect(saved.ledger.turns.last.userText, '在家徒手拉伸大腿内侧');
      expect(
        saved.sessionState.task!.nodes
            .where((node) => node.id == 'parameters')
            .single
            .status,
        anyOf('done', 'updated'),
      );
      expect(saved.sessionState.params['goal']!.quote, '拉伸大腿内侧');
      expect(saved.sessionState.seenActionIds, contains('s-butterfly'));
      expect(
        saved.loadedSkillNames,
        containsAll(['ask', 'action-library', 'action-coaching']),
      );
      original.cancel();
      blocked.complete('迟到结果不能覆盖已导出的快照');
      await pending;

      final client = FakeLlmClient([recommendOutput()], latency: Duration.zero);
      final restored = controller(client)
        ..restoreSession(saved, displayOnly(original.state.messages));
      expect(client.requests, isEmpty);
      expectEquivalent(saved, restored);
      final continued = await restored.send('继续刚才的拉伸');
      expect(
        continued!.actions,
        isNotNull,
        reason: '${continued.issues} ${continued.error}',
      );
      expectFirstRestoredRequest(client, '继续刚才的拉伸', label: 'interrupted');
      expect(
        client.requests.first.messages[1].content,
        contains('interrupted'),
      );
      expect(restored.agent.sessionState.userTurns.map((turn) => turn.text), [
        '在家徒手拉伸大腿内侧',
        '继续刚才的拉伸',
      ]);
    },
  );

  test('an unanswered question survives an unrelated interrupted send', () async {
    final entered = Completer<void>();
    final blocked = Completer<Object>();
    final original = await withQuestion(
      after: [
        (LlmRequest request) {
          entered.complete();
          return blocked.future;
        },
      ],
    );
    final question = original.state.pendingQuestion!;
    final pending = original.send('先告诉我你是谁');
    await entered.future;
    expect(
      original.state.messages
          .singleWhere((message) => message.id == question.id)
          .questionAnswered,
      isFalse,
    );
    final saved = _jsonRoundTrip(original.exportSession());
    expect(saved.pendingQuestion!.toJson(), question.question!.toJson());
    expect(saved.pendingQuestionMessageId, question.id);
    expect(saved.ledger.turns.last.outcome, 'interrupted');
    expect(saved.ledger.turns.last.userText, '先告诉我你是谁');
    original.cancel();
    blocked.complete('迟到说明不能改写快照');
    await pending;
    final client = FakeLlmClient([
      _tools([
        _call('ask_user', {'question': '这次练哪个部位？', 'mode': 'text'}),
      ]),
    ], latency: Duration.zero);
    final restored = controller(client)
      ..restoreSession(saved, displayOnly(original.state.messages));
    expect(client.requests, isEmpty);
    expect(
      restored.canAnswer(question.id),
      isTrue,
      reason:
          'A later unrelated interrupted turn did not answer the earlier question',
    );
    final answer = await restored.answerText(question.id, '在家');
    expect(answer, isNotNull);
    expect(restored.canAnswer(question.id), isFalse);
    expect(
      restored.exportSession().ledger.turns.last.answeredAsk!.questionTurn,
      saved.ledger.turns.first.turn,
    );
  });

  test(
    'an explicitly submitted answer is not reopened by a busy snapshot',
    () async {
      final entered = Completer<void>();
      final blocked = Completer<Object>();
      final original = await withQuestion(
        after: [
          (LlmRequest request) {
            entered.complete();
            return blocked.future;
          },
        ],
      );
      final question = original.state.pendingQuestion!;
      final pending = original.answerChoices(question.id, ['在家']);
      await entered.future;
      expect(
        original.state.messages
            .singleWhere((message) => message.id == question.id)
            .questionAnswered,
        isTrue,
      );
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.pendingQuestion, isNull);
      expect(saved.pendingQuestionMessageId, isNull);
      expect(saved.ledger.turns.last.outcome, 'interrupted');
      expect(saved.ledger.turns.last.userText, '在家');
      original.cancel();
      blocked.complete('迟到说明不能改写快照');
      await pending;
      final client = FakeLlmClient([], latency: Duration.zero);
      final restored = controller(client)
        ..restoreSession(
          saved,
          displayOnly(original.state.messages, reopenQuestions: true),
        );
      expect(client.requests, isEmpty);
      expect(restored.state.pendingQuestion, isNull);
      expect(restored.canAnswer(question.id), isFalse);
      expect(
        restored.state.messages
            .singleWhere((message) => message.id == question.id)
            .questionAnswered,
        isTrue,
      );
    },
  );

  test(
    'unknown or malformed snapshots fall back observably without throwing',
    () async {
      final flow = ScriptedV2PlanFlow(catalog);
      final original = controller(
        FakeLlmClient(flow.initial(), latency: Duration.zero),
      );
      final delivered = await original.send('在家有瑜伽垫10分钟做髋部放松');
      final good = original.exportSession().toJson();
      for (final corrupt in <Object?>[
        {...good, 'schemaVersion': 999},
        {'schemaVersion': 1, 'sessionState': 'broken'},
        {
          ...good,
          'agentState': {'turnCount': 'not-an-integer'},
        },
        {
          ...good,
          'agentState': {'relativeDurationPolicy': 'not-a-boolean'},
        },
        {
          ...good,
          'agentState': {
            'confirmedPlanContext': {'equipment': 3},
          },
        },
        {
          ...good,
          'agentState': {
            'lastConfirmedForm': {'scene': 'not-a-list'},
          },
        },
        {
          ...good,
          'agentState': {
            'memoryOrigins': {'hash': 'not-a-turn-list'},
          },
        },
        null,
      ]) {
        final snapshot = CoachSessionSnapshot.fromJson(corrupt);
        expect(snapshot.isValid, isFalse);
        final restored = controller(FakeLlmClient([], latency: Duration.zero));
        final events = <AgentEvent>[];
        final subscription = restored.events.listen(events.add);
        addTearDown(subscription.cancel);
        expect(
          () => restored.restoreSession(snapshot, original.state.messages),
          returnsNormally,
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          events.where(
            (event) => event.kind == AgentEventKind.snapshotRestoreFallback,
          ),
          hasLength(1),
        );
        expect(
          restored.agent.sessionState.lastDeliveredPlanId,
          delivered!.plan!.plan.id,
        );
        expect(
          restored.agent.sessionState.userTurns.map((turn) => turn.text),
          contains('在家有瑜伽垫10分钟做髋部放松'),
        );
      }
    },
  );

  test(
    'export after a settled cancellation retains interrupted progress without changing live rollback',
    () async {
      final entered = Completer<void>();
      final blocked = Completer<Object>();
      final original = controller(
        FakeLlmClient([
          recommendStart(),
          (LlmRequest request) {
            entered.complete();
            return blocked.future;
          },
        ], latency: Duration.zero),
      );
      final pending = original.send('在家徒手拉伸大腿内侧');
      await entered.future;
      original.cancel();
      blocked.complete('被取消的模型响应不能回写旧会话');
      await pending;
      expect(
        original.agent.sessionState.userTurns,
        isEmpty,
        reason: 'The existing live cancellation rollback remains unchanged',
      );
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.ledger.turns.single.outcome, 'interrupted');
      expect(saved.ledger.turns.single.userText, '在家徒手拉伸大腿内侧');
      expect(saved.sessionState.userTurns.single.text, '在家徒手拉伸大腿内侧');
      expect(saved.sessionState.params['goal']!.quote, '拉伸大腿内侧');
      expect(
        saved.sessionState.task!.nodes
            .singleWhere((node) => node.id == 'parameters')
            .status,
        anyOf('done', 'updated'),
      );
      expect(saved.sessionState.seenActionIds, contains('s-butterfly'));
      final client = FakeLlmClient([recommendOutput()], latency: Duration.zero);
      final restored = controller(client)
        ..restoreSession(saved, displayOnly(original.state.messages));
      expect(client.requests, isEmpty);
      expectEquivalent(saved, restored);
      final result = await restored.send('继续刚才的拉伸');
      expect(
        result!.actions,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expectFirstRestoredRequest(client, '继续刚才的拉伸', label: 'settled-cancel');
    },
  );

  test(
    'successful forget excludes its private content and originating quote from future snapshots',
    () async {
      const privateFact = '以后在办公室训练';
      final store = InMemoryUserMemoryStore();
      final original = controller(
        FakeLlmClient([
          _tools([
            _call('remember', {'kind': 'scene', 'text': privateFact}),
            _call('set_params', {
              'fields': {
                'scene': {'value': 'office', 'source': 'user', 'quote': '办公室'},
              },
            }),
          ]),
          '已记下你的偏好。',
          _tools([
            _call('forget', {'kind': 'scene'}),
          ]),
          '已忘记这个偏好。',
        ], latency: Duration.zero),
        enableMemory: true,
        memoryStore: store,
      );
      await original.send('请记住：$privateFact。');
      expect(store.entries.single.text, privateFact);
      await original.send('把刚才的偏好忘掉');
      expect(store.entries, isEmpty);
      expect(
        original.state.messages.first.text,
        contains(privateFact),
        reason:
            'Export privacy must not rewrite the host-owned live display history',
      );
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.isValid, isTrue);
      expect(jsonEncode(saved.toJson()), isNot(contains(privateFact)));
      expect(saved.sessionState.params['scene']!.quote, '[已忘记]');
      expect(jsonEncode(saved.toJson()), isNot(contains(_privateReasoning)));
      final client = FakeLlmClient(['你好。'], latency: Duration.zero);
      final restored = controller(client, enableMemory: true)
        ..restoreSession(saved, displayOnly(original.state.messages));
      await restored.send('你好');
      expect(
        jsonEncode(
          client.requests.first.messages
              .map((message) => message.toJson())
              .toList(),
        ),
        isNot(contains(privateFact)),
      );
    },
  );

  test(
    'a fallback observer clearing the session cannot revive old display messages',
    () async {
      final restored = controller(FakeLlmClient([], latency: Duration.zero));
      final sub = restored.events.listen((event) {
        if (event.kind == AgentEventKind.snapshotRestoreFallback) {
          restored.newConversation();
        }
      });
      addTearDown(sub.cancel);
      restored.restoreSession(CoachSessionSnapshot.fromJson(null), [
        CoachConversationMessage(
          id: 'old',
          at: DateTime.utc(2026),
          text: '旧显示',
        ),
      ]);
      expect(restored.state.messages, isEmpty);
      expect(restored.agent.sessionState.userTurns, isEmpty);
    },
  );

  test(
    'forget after snapshot restoration also removes the original remember source',
    () async {
      const privateFact = '以后在办公室训练';
      final store = InMemoryUserMemoryStore();
      final original = controller(
        FakeLlmClient([
          _tools([
            _call('remember', {'kind': 'scene', 'text': privateFact}),
          ]),
          '已记下你的偏好。',
        ], latency: Duration.zero),
        enableMemory: true,
        memoryStore: store,
      );
      await original.send('请记住：$privateFact。');
      expect(store.entries.single.text, privateFact);
      final saved = _jsonRoundTrip(original.exportSession());
      expect(saved.sessionState.userTurns.single.text, '请记住：$privateFact。');
      final forgetClient = FakeLlmClient([
        _tools([
          _call('forget', {'kind': 'scene'}),
        ]),
        '已忘记这个偏好。',
      ], latency: Duration.zero);
      final restored = controller(
        forgetClient,
        enableMemory: true,
        memoryStore: store,
      )..restoreSession(saved, displayOnly(original.state.messages));
      expectEquivalent(saved, restored);
      await restored.send('把刚才的偏好忘掉');
      expect(store.entries, isEmpty);
      final forgotten = _jsonRoundTrip(restored.exportSession());
      expect(forgotten.isValid, isTrue);
      expect(jsonEncode(forgotten.toJson()), isNot(contains(privateFact)));
      expect(
        jsonEncode(forgotten.toJson()),
        isNot(contains(_privateReasoning)),
      );
      final nextClient = FakeLlmClient(['你好。'], latency: Duration.zero);
      final next = controller(
        nextClient,
        enableMemory: true,
        memoryStore: store,
      )..restoreSession(forgotten, displayOnly(restored.state.messages));
      await next.send('你好');
      expect(
        jsonEncode(
          nextClient.requests.first.messages
              .map((message) => message.toJson())
              .toList(),
        ),
        isNot(contains(privateFact)),
      );
    },
  );

  for (final operation in ['clear', 'disable', 'new-conversation']) {
    test(
      '$operation preserves memory-store semantics without serializing private storage',
      () async {
        const privateMemory = '只在用户记忆存储中的私有偏好';
        final store = InMemoryUserMemoryStore([
          MemoryEntry(
            MemoryKind.preference,
            privateMemory,
            at: DateTime.utc(2026),
          ),
        ]);
        final client = FakeLlmClient(['你好。'], latency: Duration.zero);
        final original = controller(
          client,
          enableMemory: true,
          memoryStore: store,
        );
        await original.send('你好');
        expect(
          client.requests.first.messages.first.content,
          contains(privateMemory),
        );
        switch (operation) {
          case 'clear':
            await original.agent.clearMemory();
            expect(store.entries, isEmpty);
          case 'disable':
            original.agent.enableUserMemory = false;
            expect(store.entries.single.text, privateMemory);
          case 'new-conversation':
            original.newConversation();
        }
        final saved = _jsonRoundTrip(original.exportSession());
        expect(jsonEncode(saved.toJson()), isNot(contains(privateMemory)));
        expect(jsonEncode(saved.toJson()), isNot(contains(_privateReasoning)));
        if (operation == 'new-conversation') {
          expect(saved.sessionState.userTurns, isEmpty);
          expect(saved.ledger.turns, isEmpty);
          expect(saved.pendingQuestion, isNull);
        }
      },
    );
  }
}
