import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/append_only_context.dart';
import 'package:ugk_coach/src/agent/context_turn_ledger.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

LlmResponse _call(String id, String name, Object args, {String? reasoning}) =>
    LlmResponse(
      content: '',
      reasoning: reasoning,
      toolCalls: [LlmToolCall(id: id, name: name, arguments: jsonEncode(args))],
    );
List<String> _history(LlmRequest request) => request.messages
    .where((m) => !m.content.startsWith(AppendOnlyContext.statePrefix))
    .map((m) => jsonEncode(m.toJson()))
    .toList();
int _size(LlmRequest request) => utf8
    .encode(
      jsonEncode({
        'model': 'offline',
        'messages': request.messages.map((m) => m.toJson()).toList(),
        'tools': request.tools.map((t) => t.toJson()).toList(),
      }),
    )
    .length;

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  CoachAgent agent(
    FakeLlmClient client, {
    CoachProfile? profile,
    ContextBudgetConfig? budget,
  }) {
    final coach = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile ?? loadProfile('smartfit'),
      enableUserMemory: false,
      maxRequestRetries: 0,
      contextBudgetConfig: budget ?? const ContextBudgetConfig(),
      requestSizeBytes: _size,
    );
    addTearDown(coach.dispose);
    return coach;
  }

  test(
    'normal sends keep actual raw history and reasoning while state stays outside history',
    () async {
      final client = FakeLlmClient([
        _call('read', 'read', {
          'path': 'ask/SKILL.md',
        }, reasoning: 'first reasoning\n原字节'),
        const LlmResponse(content: '可以温和活动。', reasoning: 'final reasoning'),
        const LlmResponse(content: '不客气。', reasoning: 'next reasoning'),
      ], latency: Duration.zero);
      final coach = agent(client);
      expect((await coach.send('活动前有什么建议？')).status, TurnStatus.ok);
      expect(coach.history, hasLength(2));
      expect(coach.history.where((m) => m.role == LlmRole.tool), isEmpty);
      expect((await coach.send('谢谢')).status, TurnStatus.ok);
      for (var i = 1; i < client.requests.length; i++) {
        final before = _history(client.requests[i - 1]);
        expect(_history(client.requests[i]).take(before.length), before);
        expect(
          client.requests[i].tools.map((t) => jsonEncode(t.toJson())),
          client.requests[i - 1].tools.map((t) => jsonEncode(t.toJson())),
        );
      }
      final last = client.requests.last;
      expect(
        last.messages.where((m) => m.role == LlmRole.system),
        hasLength(1),
      );
      expect(last.messages.last.role, LlmRole.user);
      expect(
        last.messages.last.content,
        startsWith(AppendOnlyContext.statePrefix),
      );
      expect(
        last.messages
            .where((m) => m.role == LlmRole.assistant)
            .map((m) => m.reasoning),
        ['first reasoning\n原字节', 'final reasoning'],
      );
      expect(
        last.messages.singleWhere((m) => m.toolCallId == 'read').content,
        contains('name: ask'),
      );
      final ledger = ContextTurnLedger.fromJson(
        coach.sessionState.completedContextLedger!,
      );
      expect(ledger.turns.map((t) => t.userText), ['活动前有什么建议？', '谢谢']);
      expect(coach.sessionState.userTurns.map((t) => t.text), [
        '活动前有什么建议？',
        '谢谢',
      ]);
      expect(
        coach.history.any(
          (m) => m.content.startsWith(AppendOnlyContext.statePrefix),
        ),
        isFalse,
      );
      expect(coach.contextRequestDiagnostics.every((d) => !d.folded), isTrue);
    },
  );

  test(
    'plan delivery retains the real show batch for the next turn; snapshot restores only lossless facts',
    () async {
      final flow = ScriptedV2PlanFlow(catalog);
      final client = FakeLlmClient([
        ...flow.initial(note: '请按舒适范围练习。'),
        const LlmResponse(content: '已保留这份计划。'),
      ], latency: Duration.zero);
      final coach = agent(
        client,
        budget: const ContextBudgetConfig(
          softOffBytes: 120000,
          softOnBytes: 120000,
          hardBytes: 200000,
        ),
      );
      final first = await coach.send('在家用瑜伽垫，10分钟髋部放松');
      expect(first.plan, isNotNull, reason: '${first.error}');
      final saved = coach.planStateFor(first.plan!);
      expect((await coach.send('谢谢')).status, TurnStatus.ok);
      expect(
        client.requests.last.messages.any((m) => m.toolCallId == 'show-plan'),
        isTrue,
      );
      final before = _history(client.requests[client.requests.length - 2]);
      expect(_history(client.requests.last).take(before.length), before);
      final rawSaved = jsonEncode(saved.toJson());
      expect(rawSaved, isNot(contains('reasoning_content')));
      expect(rawSaved, isNot(contains('tool_calls')));
      final restoreClient = FakeLlmClient([
        const LlmResponse(content: '计划已恢复。'),
      ], latency: Duration.zero);
      final restored = agent(restoreClient);
      restored.restorePlan(
        first.plan!,
        planState: CoachPlanState.fromJson(
          (jsonDecode(rawSaved) as Map).cast<String, dynamic>(),
        ),
        restoredMessages: const [
          LlmMessage.user('更早的一句原话：我每天坐很久。'),
          LlmMessage.assistant('更早的真实说明。', reasoning: ''),
          LlmMessage.user('在家用瑜伽垫，10分钟髋部放松'),
          LlmMessage.assistant('请按舒适范围练习。', reasoning: ''),
        ],
      );
      expect((await restored.send('记得我的条件吗？')).status, TurnStatus.ok);
      final request = restoreClient.requests.single;
      expect(request.messages[1].role, LlmRole.user);
      expect(
        request.messages[1].content,
        startsWith(ContextTurnLedger.summaryPrefix),
      );
      final decoded =
          jsonDecode(request.messages[1].content.split('\n').skip(1).join('\n'))
              as Map;
      final old = (decoded['turns'] as List).first as Map;
      expect(old['userText'], '在家用瑜伽垫，10分钟髋部放松');
      expect(old['finalDeliveryText'], '请按舒适范围练习。');
      expect((old['currentPlanRef'] as Map)['plan_id'], first.plan!.plan.id);
      expect(
        request.messages.where(
          (m) => m.role == LlmRole.user && m.content == '更早的一句原话：我每天坐很久。',
        ),
        hasLength(1),
      );
      expect(
        request.messages
            .where((m) => m.role == LlmRole.assistant)
            .map((m) => m.content),
        contains('更早的真实说明。'),
      );
      expect(
        request.messages
            .skip(2)
            .any(
              (m) => m.content == '在家用瑜伽垫，10分钟髋部放松' || m.content == '请按舒适范围练习。',
            ),
        isFalse,
      );
      expect(
        request.messages
            .where((m) => m.role == LlmRole.assistant)
            .every((m) => (m.reasoning ?? '').isEmpty),
        isTrue,
      );
    },
  );

  test(
    'soft folding replaces only ended turns and persists complete question answer linkage',
    () async {
      final firstReasoning = 'r' * 20000;
      final client = FakeLlmClient([
        _call('ask', 'ask_user', {
          'question': '今天在哪里训练？',
          'mode': 'choice',
          'options': ['居家', '办公室'],
        }, reasoning: firstReasoning),
        const LlmResponse(
          content: '可以按你选的场景温和活动。',
          reasoning: 'current reasoning 原文',
        ),
      ], latency: Duration.zero);
      final coach = agent(
        client,
        budget: const ContextBudgetConfig(
          softOffBytes: 15000,
          softOnBytes: 15000,
          hardBytes: 65536,
        ),
      );
      expect((await coach.send('我想活动')).question, isNotNull);
      expect((await coach.send('办公室')).status, TurnStatus.ok);
      final request = client.requests.last;
      expect(request.messages[1].role, LlmRole.user);
      expect(
        request.messages[1].content,
        startsWith(ContextTurnLedger.summaryPrefix),
      );
      expect(
        request.messages.where((m) => m.reasoning == firstReasoning),
        isEmpty,
      );
      expect(request.messages.any((m) => m.content == '办公室'), isTrue);
      expect(coach.contextRequestDiagnostics.last.completedTurnsFolded, 1);
      final ledger = ContextTurnLedger.fromJson(
        coach.sessionState.completedContextLedger!,
      );
      expect(ledger.turns.first.askQuestions.single['question'], '今天在哪里训练？');
      expect(
        ledger.turns.last.answeredAsk!.questionTurn,
        ledger.turns.first.turn,
      );
      expect(ledger.turns.last.answeredAsk!.answerJson!['text'], '办公室');
      expect(ledger.turns.last.userText, '办公室');
    },
  );

  test(
    'hard folding changes only consumed receipt bodies and allows a folded skill to be read again',
    () async {
      final hugeA = '---\nname: huge-a\n---\n${'a' * 27000}';
      final hugeB = '---\nname: huge-b\n---\n${'b' * 27000}';
      final profile = CoachProfile.fromJson({
        ...loadProfile('smartfit').toJson(),
        'skills': [
          {'name': 'huge-a', 'description': 'A', 'content': hugeA},
          {'name': 'huge-b', 'description': 'B', 'content': hugeB},
        ],
      });
      final reasoningA = 'A' * 4000;
      final reasoningB = 'B' * 4000;
      final client = FakeLlmClient([
        _call('a', 'read', {'path': 'huge-a/SKILL.md'}, reasoning: reasoningA),
        _call('b', 'read', {'path': 'huge-b/SKILL.md'}, reasoning: reasoningB),
        (LlmRequest request) {
          expect(
            request.messages.singleWhere((m) => m.toolCallId == 'a').content,
            isNot(hugeA),
          );
          expect(
            request.messages.singleWhere((m) => m.toolCallId == 'b').content,
            hugeB,
          );
          expect(
            request.messages
                .where((m) => m.role == LlmRole.assistant)
                .map((m) => m.reasoning),
            [reasoningA, reasoningB],
          );
          return _call('a-again', 'read', {
            'path': 'huge-a/SKILL.md',
          }, reasoning: 'read it again');
        },
        (LlmRequest request) {
          expect(
            request.messages
                .singleWhere((m) => m.toolCallId == 'a-again')
                .content,
            hugeA,
          );
          return const LlmResponse(content: '资料已确认。');
        },
      ], latency: Duration.zero);
      final coach = agent(client, profile: profile);
      final result = await coach.send('讲讲训练资料');
      expect(result.status, TurnStatus.ok, reason: '${result.error}');
      expect(
        coach.contextRequestDiagnostics.any((d) => d.receiptBodiesFolded > 0),
        isTrue,
      );
    },
  );

  test(
    'a current reasoning payload that cannot fit fails honestly without truncating or sending',
    () async {
      final reasoning = '原' * 25000;
      final client = FakeLlmClient([
        _call('read', 'read', {'path': 'ask/SKILL.md'}, reasoning: reasoning),
      ], latency: Duration.zero);
      final coach = agent(client);
      final result = await coach.send('请解释一下');
      expect(result.status, TurnStatus.error);
      expect(result.error, isA<AgentContextBudgetExceeded>());
      expect(client.requests, hasLength(1));
      expect(coach.contextRequestDiagnostics.last.fitsHardLimit, isFalse);
      expect(coach.contextRequestDiagnostics.last.receiptBodiesFolded, 0);
    },
  );

  test(
    'cancelled turns never enter the persisted ledger or subsequent model journal',
    () async {
      final pending = Completer<Object>();
      final started = Completer<void>();
      final client = FakeLlmClient([
        (_) {
          started.complete();
          return pending.future;
        },
        '后来这轮成功。',
      ], latency: Duration.zero);
      final coach = agent(client);
      final cancel = CancelToken();
      final first = coach.send('这一轮取消', cancel: cancel);
      await started.future;
      cancel.cancel();
      expect((await first).status, TurnStatus.cancelled);
      pending.complete(const LlmResponse(content: '迟到回复', reasoning: '迟到推理'));
      expect((await coach.send('新的一轮')).status, TurnStatus.ok);
      final ledger = ContextTurnLedger.fromJson(
        coach.sessionState.completedContextLedger!,
      );
      expect(ledger.turns.map((t) => t.userText), ['新的一轮']);
      expect(
        client.requests.last.messages.any(
          (m) => m.content == '这一轮取消' || m.reasoning == '迟到推理',
        ),
        isFalse,
      );
    },
  );

  test(
    'equal catalog factories do not restart a normal context epoch',
    () async {
      final client = FakeLlmClient([
        const LlmResponse(
          content: '第一次回答',
          reasoning: 'keep previous reasoning',
        ),
        const LlmResponse(content: '第二次回答'),
      ], latency: Duration.zero);
      final coach = CoachAgent(
        client: client,
        catalog: loadCatalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxRequestRetries: 0,
        requestSizeBytes: _size,
      );
      addTearDown(coach.dispose);
      await coach.send('第一句');
      await coach.send('第二句');
      expect(
        coach.contextRequestDiagnostics[1].epoch,
        coach.contextRequestDiagnostics[0].epoch,
      );
      expect(
        client.requests.last.messages.any(
          (m) => m.reasoning == 'keep previous reasoning',
        ),
        isTrue,
      );
    },
  );

  test(
    'successful forget invalidates a memory system snapshot without dropping remaining store entries',
    () async {
      final store = InMemoryUserMemoryStore([
        MemoryEntry(
          MemoryKind.injury,
          'deleted-memory-private-marker',
          at: DateTime.utc(2026),
        ),
        MemoryEntry(
          MemoryKind.preference,
          'remaining-memory-marker',
          at: DateTime.utc(2026),
        ),
      ]);
      final client = FakeLlmClient([
        _call('forget', 'forget', {
          'kind': 'injury',
        }, reasoning: 'reasoning with deleted-memory-private-marker'),
        (LlmRequest request) {
          expect(
            (jsonDecode(
                  request.messages
                      .singleWhere((m) => m.toolCallId == 'forget')
                      .content,
                )
                as Map)['ok'],
            isTrue,
          );
          expect(
            request.tools.any((tool) => tool.name == AgentTools.remember),
            isTrue,
          );
          expect(
            request.messages.first.content,
            contains('remaining-memory-marker'),
          );
          return _call('remember-new', 'remember', {
            'kind': 'goal',
            'text': 'new-after-forget',
          }, reasoning: 'fresh reasoning after forget');
        },
        const LlmResponse(
          content: '已经忘记旧项并记住新项。',
          reasoning: 'fresh final reasoning',
        ),
        const LlmResponse(content: '好的。'),
      ], latency: Duration.zero);
      final coach = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        memoryStore: store,
        enableUserMemory: true,
        maxRequestRetries: 0,
        requestSizeBytes: _size,
      );
      addTearDown(coach.dispose);
      expect((await coach.send('忘记伤痛记忆')).status, TurnStatus.ok);
      expect((await coach.send('继续')).status, TurnStatus.ok);
      expect((await store.load()).map((m) => m.text), [
        'remaining-memory-marker',
        'new-after-forget',
      ]);
      expect(
        client.requests.first.messages.first.content,
        contains('deleted-memory-private-marker'),
      );
      for (final request in client.requests.skip(1)) {
        expect(
          jsonEncode(request.messages.map((m) => m.toJson()).toList()),
          isNot(contains('deleted-memory-private-marker')),
        );
      }
      expect(
        client.requests.last.messages.first.content,
        contains('remaining-memory-marker'),
      );
      expect(
        coach.contextRequestDiagnostics.last.epoch,
        greaterThan(coach.contextRequestDiagnostics.first.epoch),
      );
    },
  );

  test(
    'context overflow cannot erase a receipt not consumed by a successful request',
    () async {
      final reasoning = 'must remain exactly 原字节';
      final client = FakeLlmClient([
        _call('read', 'read', {'path': 'ask/SKILL.md'}, reasoning: reasoning),
        const LlmException(
          LlmErrorKind.http,
          'context length exceeded',
          statusCode: 400,
        ),
      ], latency: Duration.zero);
      final coach = agent(client);
      final result = await coach.send('请解释');
      expect(result.status, TurnStatus.error);
      expect(result.error, isA<AgentContextBudgetExceeded>());
      expect(client.requests, hasLength(2));
      expect(
        client.requests.last.messages
            .singleWhere((m) => m.toolCallId == 'read')
            .content,
        contains('name: ask'),
      );
      expect(
        client.requests.last.messages
            .singleWhere((m) => m.role == LlmRole.assistant)
            .reasoning,
        reasoning,
      );
      expect(coach.contextRequestDiagnostics.last.receiptBodiesFolded, 0);
    },
  );

  test(
    'unfolded recommendation and plan skill reads retain exactly one visible body',
    () async {
      final body = SkillFiles.build(
        loadProfile('smartfit'),
        catalog,
        memory: false,
      ).read('plan-training/SKILL.md')!;
      final client = FakeLlmClient([
        _call('read-plan', 'read', {'path': 'plan-training/SKILL.md'}),
        _call('recommend', 'start_task', {'type': 'recommend'}),
        _call('plan', 'start_task', {'type': 'plan'}),
        _call('ask', 'ask_user', {'question': '还有什么条件？', 'mode': 'text'}),
      ], latency: Duration.zero);
      final coach = agent(client);
      final result = await coach.send('先了解流程');
      expect(result.question, isNotNull, reason: '${result.error}');
      final last = client.requests.last;
      expect(
        last.messages.singleWhere((m) => m.toolCallId == 'read-plan').content,
        body,
      );
      final start =
          jsonDecode(
                last.messages
                    .singleWhere((m) => m.toolCallId == 'plan')
                    .content,
              )
              as Map;
      expect((start['skills'] as Map)['plan-training'], '[已在前文 read 中]');
      expect(coach.contextRequestDiagnostics.every((d) => !d.folded), isTrue);
    },
  );

  test(
    'an explicitly selected admitted preset is an actual journal delivery and restores its reference',
    () async {
      final seedFlow = ScriptedV2PlanFlow(catalog);
      final seedClient = FakeLlmClient(
        seedFlow.initial(),
        latency: Duration.zero,
      );
      final seed = agent(seedClient);
      final planResult = await seed.send('在家用瑜伽垫，10分钟髋部放松');
      expect(planResult.plan, isNotNull, reason: '${planResult.error}');
      final preset = planResult.plan!.plan;
      final flow = ScriptedV2PlanFlow(catalog);
      final client = FakeLlmClient([
        flow.initial().first,
        const LlmException(LlmErrorKind.network, 'offline'),
        const LlmResponse(content: '当前计划已保留。'),
      ], latency: Duration.zero);
      final coach = agent(
        client,
        budget: const ContextBudgetConfig(
          softOffBytes: 120000,
          softOnBytes: 120000,
          hardBytes: 200000,
        ),
      );
      expect((await coach.send('在家用瑜伽垫，10分钟髋部放松')).status, TurnStatus.error);
      final beforeParams = jsonEncode(
        coach.sessionState.params.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      );
      final beforeSeen = coach.sessionState.seenActionIds.toSet();
      expect(coach.canOfferPreset(preset), isTrue);
      final chosen = coach.requestPreset(preset)!;
      expect(chosen.plan, isNotNull);
      expect(coach.sessionState.activePlanId, chosen.plan!.plan.id);
      expect(coach.sessionState.lastDeliveredPlanId, chosen.plan!.plan.id);
      expect(coach.sessionState.task, isNull);
      expect(coach.sessionState.seenActionIds, beforeSeen);
      expect(
        jsonEncode(
          coach.sessionState.params.map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
        ),
        beforeParams,
      );
      final saved = coach.planStateFor(chosen.plan!);
      expect((await coach.send('当前计划叫什么？')).status, TurnStatus.ok);
      final request = client.requests.last;
      expect(request.messages.any((m) => m.content == '用预设方案'), isTrue);
      expect(
        request.messages.any(
          (m) => m.content == chosen.text && m.role == LlmRole.assistant,
        ),
        isTrue,
      );
      final dynamicState =
          jsonDecode(
                request.messages.last.content.substring(
                  AppendOnlyContext.statePrefix.length,
                ),
              )
              as Map;
      expect((dynamicState['plan'] as Map)['plan_id'], chosen.plan!.plan.id);
      final ledger = ContextTurnLedger.fromJson(
        saved.sessionState!.completedContextLedger!,
      );
      expect(ledger.turns.last.deliveries.single.planId, chosen.plan!.plan.id);
      expect(ledger.turns.last.finalDeliveryText, chosen.text);
      final restoredClient = FakeLlmClient([
        const LlmResponse(content: '已恢复。'),
      ], latency: Duration.zero);
      final restored = agent(restoredClient);
      restored.restorePlan(
        chosen.plan!,
        planState: CoachPlanState.fromJson(
          (jsonDecode(jsonEncode(saved.toJson())) as Map)
              .cast<String, dynamic>(),
        ),
      );
      expect((await restored.send('继续')).status, TurnStatus.ok);
      expect(
        restoredClient.requests.single.messages[1].content,
        contains(chosen.plan!.plan.id),
      );
      expect(jsonEncode(saved.toJson()), isNot(contains('reasoning_content')));
    },
  );
}
