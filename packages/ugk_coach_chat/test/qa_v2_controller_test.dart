import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach/ugk_coach_qa_v2.dart' as qa;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart'
    show
        ChatHarness,
        ChatHistory,
        ChatPlans,
        ChatPreferences,
        chatCatalog,
        chatPlan,
        chatPlanScript;

/// 模型的一步：本轮上下文、上一条 tool result（本轮第一次调用时为 null）、全局第几次调用 → (工具, 参数)。
typedef _Handler =
    FutureOr<(String, Map<String, Object?>)> Function(
      String context,
      String? lastResult,
      int count,
    );

class _Model implements coach.LlmClient {
  _Model(this.handler);
  final _Handler handler;
  final requests = <coach.LlmRequest>[];
  @override
  String get model => 'qa-controller-model';
  @override
  coach.Pricing? get pricing => null;
  @override
  Future<coach.LlmResponse> complete(
    coach.LlmRequest request, {
    coach.CancelToken? cancel,
  }) async {
    requests.add(request);
    final context = request.messages
        .lastWhere(
          (m) =>
              m.role == coach.LlmRole.user && m.content.contains('[用户这句话]'),
        )
        .content;
    final last = request.messages.last;
    final (tool, args) = await handler(
      context,
      last.role == coach.LlmRole.tool ? last.content : null,
      requests.length,
    );
    return coach.LlmResponse(
      content: '',
      model: model,
      usage: const coach.TokenUsage(promptTokens: 12, completionTokens: 8),
      toolCalls: [
        coach.LlmToolCall(
          id: '$tool-${requests.length}',
          name: tool,
          arguments: jsonEncode(args),
        ),
      ],
    );
  }
}

/// 居家徒手。
(String, Map<String, Object?>) _home() => (
  'set_conditions',
  {
    'place': 'home',
    'equipment_known': true,
    'equipment': <String>[],
  },
);

/// 推荐三个动作卡。
(String, Map<String, Object?>) _answer({
  List<String> ids = const ['one', 'two', 'three'],
}) => (
  'show_actions',
  {
    'text': '按你的条件来。',
    'items': [
      for (final id in ids) {'id': id, 'why': '适合当前条件'},
    ],
    'assumption': '沿用居家徒手',
    'chips': ['换场地'],
  },
);

/// 一轮：先记居家徒手，再推荐。
(String, Map<String, Object?>) _homeThenAnswer(String? last) =>
    last == null ? _home() : _answer();

class _BackupHistory extends ChatHistory {
  final preserved = <CoachChatSnapshot>[];
  @override
  Future<void> preserveUnreadable(
    String namespace,
    CoachChatSnapshot snapshot,
    Object? error,
  ) async => preserved.add(snapshot);
}

class _Harness {
  _Harness(
    _Handler handler, {
    ChatHistory? history,
    Map<String, Map<String, Object?>> tags = const {},
    coach.UsageSink? usageSink,
    CoachChatObserver? observer,
    Future<void> Function(CoachChatSnapshot)? archive,
  }) : model = _Model(handler),
       history = history ?? ChatHistory() {
    final catalog = chatCatalog();
    final profile = CoachAppProfile(
      appId: 'chat-test',
      scopeManifest: coach.CoachActionScopeManifest.fromCatalogBytes(
        appId: 'chat-test',
        catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
        allowedActionIds: ['one', 'two', 'three', 'four'],
      ),
      coachProfile: const coach.CoachProfile(id: 'chat-test', appName: '训练助手'),
      conversationPolicy: coach.CoachScopeConversationPolicy(
        specialty: '温和拉伸',
        suggestions: ['想拉伸'],
      ),
      executionTiming: (plan) => coach.PlanExecutionTiming(
        totalSeconds: const coach.PlanDuration().estimateSeconds(plan, catalog),
        blocks: [
          for (final block in plan.blocks)
            coach.PlanBlockExecutionTiming(blockId: block.id, seconds: 0),
        ],
        containsManualCounting: false,
      ),
      agentMode: CoachChatAgentMode.qaV2,
      aiTags: tags,
    );
    controller = CoachChatController(
      profile: profile,
      catalog: catalog,
      replyDelay: Duration.zero,
      usageSink: usageSink,
      bindings: CoachChatBindings(
        storageNamespace: 'test',
        gateway: CoachGatewayBinding.shared(model),
        plans: plans,
        history: this.history,
        preferences: preferences,
        observer: observer,
        beforeNewConversation: archive,
        actions: CoachChatHostActions(
          onStartTraining: (_, _) async => null,
          onOpenAction: (_, _) async {},
          onOpenLibrary: (_, _) async {},
          onOpenSavedPlans: (_) async {},
          onOpenCustomPlan: (_) async {},
          onOpenSettings: (_) async {},
        ),
      ),
    );
  }
  final _Model model;
  final ChatHistory history;
  final plans = ChatPlans();
  final preferences = ChatPreferences();
  late final CoachChatController controller;
  Future<void> close() async {
    await controller.close();
    controller.dispose();
    await plans.updates.close();
    await preferences.updates.close();
  }
}

Future<CoachChatSnapshot> roundtrip(CoachChatController c) async {
  await c.flushPersistence();
  return CoachChatSnapshot.fromJson(
    jsonDecode(jsonEncode(c.exportSnapshot().toJson())) as Map<String, Object?>,
  );
}

void main() {
  test(
    'existing profile remains legacy and does not create QA state',
    () async {
      final h = ChatHarness(script: chatPlanScript());
      addTearDown(h.close);
      expect(h.controller.profile.agentMode, CoachChatAgentMode.legacy);
      expect((await h.controller.send('在家拉伸5分钟'))?.plan, isNotNull);
      expect(h.controller.lastQaReply, isNull);
      expect(
        h.controller.exportSnapshot().toJson().containsKey('qaState'),
        isFalse,
      );
      expect(h.controller.messages.any((m) => m.qaV2), isFalse);
    },
  );

  test(
    'App tags enrich only allowed actions and never enter the snapshot',
    () async {
      final tags = {
        for (final id in ['one', 'outside'])
          id: <String, Object?>{
            'format': 'pose-hub-ai-tags@1',
            'primaryMuscles': ['adductors'],
            'scenes': ['home'],
            'trainingType': ['static-stretch'],
            'sessionRole': ['cooldown'],
            'aiSummary': {'zh': 'host-private-tag'},
          },
      };
      final h = _Harness(
        (_, last, _) => _homeThenAnswer(last),
        tags: tags,
      );
      addTearDown(h.close);
      await h.controller.start();
      expect(h.controller.qaAgent.index['one']!.source, 'ai-tags');
      expect(h.controller.qaAgent.index['two']!.source, 'catalog');
      expect(h.controller.qaAgent.index['outside'], isNull);
      expect(
        jsonEncode(h.controller.exportSnapshot().toJson()),
        isNot(contains('host-private-tag')),
      );
      expect(h.model.requests, isEmpty);
    },
  );

  test(
    'model single and multi choice text is submitted once and usage is per call',
    () async {
      final records = <coach.UsageRecord>[];
      final h = _Harness((context, last, count) {
        return switch (count) {
          1 => (
            'ask_user',
            {
              'step': 'place',
              'question': '在哪儿练？',
              'options': ['居家', '健身房', '办公室', '直接推荐'],
            },
          ),
          2 => ('set_conditions', {'place': 'home'}),
          3 => (
            'ask_user',
            {
              'step': 'equipment',
              'question': '有哪些器械？',
              'options': ['瑜伽垫', '椅子', '哑铃', '弹力带', '徒手', '直接推荐'],
              'multi': true,
            },
          ),
          4 => (
            'set_conditions',
            {
              'equipment_known': true,
              'equipment': ['mat', 'chair'],
            },
          ),
          _ => _answer(),
        };
      }, usageSink: coach.CallbackUsageSink(records.add));
      addTearDown(h.close);
      expect((await h.controller.send('想拉伸'))?.status, coach.TurnStatus.ok);
      final place = h.controller.messages.last;
      expect(place.question!.multiple, isFalse);
      expect(await h.controller.answerChoices(place, ['居家', '健身房']), isNull);
      expect(h.model.requests, hasLength(1));
      await h.controller.answerChoices(place, ['居家']);
      expect(h.controller.canAnswerQuestion(place), isFalse);
      final equipment = h.controller.messages.last;
      expect(equipment.question!.multiple, isTrue);
      await h.controller.answerChoices(equipment, ['瑜伽垫', '椅子']);
      expect(h.controller.messages.where((m) => m.isUser).last.text, '瑜伽垫、椅子');
      expect(h.model.requests[3].messages.last.content, contains('瑜伽垫、椅子'));
      expect(
        h.controller.lastQaReply!.conditions['equipment'],
        containsAll(['mat', 'chair']),
      );
      expect(h.controller.messages.last.quickActions, ['换场地']);
      expect(records, hasLength(h.model.requests.length));
      expect(
        records.every(
          (r) => r.model == h.model.model && r.usage.promptTokens == 12,
        ),
        isTrue,
      );
      final before = h.model.requests.length;
      expect(await h.controller.answerChoices(equipment, ['徒手']), isNull);
      expect(h.model.requests, hasLength(before));
    },
  );

  test(
    'QA state roundtrip keeps card order and swaps only second recommendation',
    () async {
      final first = _Harness(
        (_, last, _) => _homeThenAnswer(last),
      );
      addTearDown(first.close);
      await first.controller.send('在家徒手拉伸');
      final snapshot = CoachChatSnapshot.fromJson(
        jsonDecode(jsonEncode(first.controller.exportSnapshot().toJson()))
            as Map<String, Object?>,
      );
      final next = _Harness(
        (_, _, _) => (
          'swap',
          {
            'mode': 'swap',
            'text': '已替换',
            'changes': [
              {'position': 2, 'new_id': 'four', 'why': '同部位替换'},
            ],
            'chips': ['换场地'],
          },
        ),
      );
      addTearDown(next.close);
      expect((await next.controller.restoreSnapshot(snapshot)).ok, isTrue);
      expect(next.controller.qaAgent.state.lastShown, ['one', 'two', 'three']);
      expect(next.model.requests, isEmpty);
      final result = await next.controller.send('换第 2 个');
      expect(result?.status, coach.TurnStatus.ok, reason: '${result?.error}');
      expect(result!.actions!.items.map((a) => a.id), ['one', 'four', 'three']);
      expect(next.controller.qaAgent.state.lastShown, ['one', 'four', 'three']);
      expect(next.controller.messages.last.actionReasons['four'], '同部位替换');
    },
  );

  test(
    'saved plan focus preserves all block positions and can save QA replacement',
    () async {
      final h = _Harness(
        (_, _, _) => (
          'swap',
          {
            'mode': 'swap',
            'text': '第 2 个换成 four伸展',
            'changes': [
              {'position': 2, 'new_id': 'four', 'why': '同部位替换'},
            ],
            'chips': <String>[],
          },
        ),
      );
      addTearDown(h.close);
      final base = chatPlan();
      final plan = const coach.PlanCodec().decodeStrict({
        ...base.toJson(),
        'blocks': [
          for (final (i, type) in [
            coach.BlockType.warmup,
            coach.BlockType.main,
            coach.BlockType.cooldown,
          ].indexed)
            coach.PlanBlock(
              id: 'b$i',
              name: type.name,
              type: type,
              items: [base.items.elementAt(i)],
            ).toJson(),
        ],
      });
      final selection = CoachSavedPlanSnapshot(
        externalId: 'saved',
        title: '已保存计划',
        plan: plan.plan!,
        storageRevision: 'r1',
      );
      h.plans.values.add(selection);
      final focused = await h.controller.sendPlanToConversation(selection);
      expect(focused.ok, isTrue, reason: '${focused.errors}');
      expect(h.controller.qaAgent.state.lastPlan!.orderedIds, [
        'one',
        'two',
        'three',
      ]);
      final result = await h.controller.send('换第2个');
      expect(result?.status, coach.TurnStatus.ok, reason: '${result?.error}');
      expect(
        h.model.requests.last.messages.last.content,
        allOf(contains('[当前卡片]'), contains('2. [main')),
      );
      expect(h.controller.lastQaReply!.planOrderedIds, ['one', 'four', 'three']);
      final card = h.controller.messages.lastWhere((m) => m.plan != null);
      expect(card.plan!.blocks.map((b) => b.type), [
        coach.BlockType.warmup,
        coach.BlockType.main,
        coach.BlockType.cooldown,
      ]);
      final saved = await h.controller.savePlanCard(card);
      expect(saved.plan.exerciseIds, {'one', 'four', 'three'});
      expect(h.plans.writes, hasLength(1));
    },
  );

  test(
    'generated QA plan passes the existing training gate and saves the shown plan',
    () async {
      final h = _Harness(
        (_, last, _) => last == null
            ? _home()
            : (
                'build_plan',
                {
                  'mode': 'new',
                  'text': '这一套按5分钟安排。',
                  'title': '拉伸计划',
                  'minutes': 5,
                  'main_ids': ['one', 'two', 'three'],
                  'chips': ['换场地'],
                  'block_names': {'main': '主训练'},
                },
              ),
      );
      addTearDown(h.close);
      final result = await h.controller.send('在家徒手拉伸5分钟');
      expect(result?.status, coach.TurnStatus.ok, reason: '${result?.error}');
      expect(result?.plan, isNotNull);
      final shown = h.controller.messages.last;
      expect(identical(shown.plan, result!.plan!.plan), isTrue);
      expect(shown.plan!.source, 'ai');
      expect(shown.plan!.summary, '这一套按5分钟安排。');
      expect(h.controller.qaAgent.state.lastPlan!.orderedIds, [
        for (final block in shown.plan!.blocks)
          for (final item in block.items) item.exerciseId,
      ]);
      final saved = await h.controller.savePlanCard(shown);
      expect(saved.plan.toJson(), shown.plan!.toJson());
      expect(h.plans.writes.single.plan.toJson(), shown.plan!.toJson());
      final restored = _Harness(
        (tool, _, _) => throw StateError('Restore must not call the model'),
      );
      addTearDown(restored.close);
      final snapshot = CoachChatSnapshot.fromJson(
        jsonDecode(jsonEncode(h.controller.exportSnapshot().toJson()))
            as Map<String, Object?>,
      );
      expect((await restored.controller.restoreSnapshot(snapshot)).ok, isTrue);
      final restoredCard = restored.controller.messages.lastWhere(
        (m) => m.plan != null,
      );
      expect(restoredCard.plan!.source, 'ai');
      expect(restoredCard.validatedPlan, isNotNull);
      expect(
        restored.controller.qaAgent.state.lastPlan!.plan.toJson(),
        shown.plan!.toJson(),
      );
      expect(restored.model.requests, isEmpty);
    },
  );

  test(
    'new conversation cancels late model work and clears committed QA state',
    () async {
      final pending = Completer<(String, Map<String, Object?>)>();
      final h = _Harness((_, _, count) => count == 1 ? pending.future : _answer());
      addTearDown(h.close);
      final sending = h.controller.send('想拉伸');
      while (h.model.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect((await h.controller.newConversation()).ok, isTrue);
      pending.complete(_home());
      await sending;
      expect(h.controller.typing, isFalse);
      expect(h.controller.messages, hasLength(1));
      expect(h.controller.messages.single.greeting, isTrue);
      expect(h.controller.qaAgent.state.turn, 0);
      expect(h.controller.qaAgent.state.lastShown, isEmpty);
      expect(h.controller.lastQaReply, isNull);
      expect(h.model.requests, hasLength(1));
    },
  );

  test('restoring a pending QA question retains selection and focus', () async {
    final first = _Harness(
      (_, last, _) => last == null
          ? (
              'search_actions',
              {
                'muscles': ['adductors'],
                'types': ['static-stretch'],
              },
            )
          : (
              'ask_user',
              {
                'step': 'place',
                'question': 'Where to train?',
                'options': ['At home', 'Gym', 'Office', 'Recommend now'],
              },
            ),
    );
    addTearDown(first.close);
    await first.controller.send('I want to stretch');
    final next = _Harness((_, last, _) => _homeThenAnswer(last));
    addTearDown(next.close);
    expect(
      (await next.controller.restoreSnapshot(
        first.controller.exportSnapshot(),
      )).ok,
      isTrue,
    );
    final question = next.controller.messages.lastWhere(
      (m) => m.question != null,
    );
    expect(question.question!.question, 'Where to train?');
    expect(next.controller.canAnswerQuestion(question), isTrue);
    expect(next.controller.qaAgent.state.lastAsk, qa.QaAskStep.place);
    await next.controller.answerChoices(question, ['At home']);
    expect(
      next.model.requests.first.messages.last.content,
      contains('At home'),
    );
    expect(next.controller.qaAgent.state.focus!.muscles, {'adductors'});
    expect(next.controller.canAnswerQuestion(question), isFalse);
  });

  for (final mains in [
    ['one', 'two'],
    <String>[],
  ]) {
    test(
      'QA respond + build_plan snapshot survives JSON roundtrip ($mains)',
      () async {
        final first = _Harness((context, last, count) {
          if (count <= 2) return _homeThenAnswer(last);
          // 验收退回后，模型改用 reply 如实说明。
          if (last != null && last.startsWith('不合规')) {
            return ('reply', {'text': '这几个动作排不满时长。', 'chips': <String>[]});
          }
          return (
            'build_plan',
            {
              'mode': 'new',
              'title': '拉伸计划',
              'text': '排好了',
              'minutes': 10,
              'main_ids': mains,
              'chips': ['开始'],
            },
          );
        });
        addTearDown(first.close);
        await first.controller.send('在家徒手拉伸');
        final r = await first.controller.send('请把刚才推荐的动作排成计划。');
        expect(r, isNotNull);
        final snapshot = await roundtrip(first.controller);
        final next = _Harness(
          (_, last, _) => _homeThenAnswer(last),
          history: ChatHistory()..snapshot = snapshot,
        );
        addTearDown(next.close);
        final started = await next.controller.start();
        expect(
          started.ok,
          isTrue,
          reason: '${started.error} ${started.issues.map((i) => i.message)}',
        );
        final sent = await next.controller.send('再来一组');
        expect(sent, isNotNull);
        expect(
          next.controller.messages.where((m) => m.isUser).last.text,
          '再来一组',
        );
      },
    );
  }

  test(
    'QA ask_user + respond + failed build_plan + respond roundtrip',
    () async {
      final first = _Harness((context, last, count) {
        if (count == 1) {
          return (
            'ask_user',
            {
              'step': 'place',
              'question': '在哪儿练？',
              'options': ['居家', '健身房', '办公室', '直接推荐'],
            },
          );
        }
        // 排计划这一轮模型调用一直出错：按连续错误上限报错。
        if (context.contains('请把刚才推荐的动作排成计划。')) throw StateError('boom');
        return _homeThenAnswer(last);
      });
      addTearDown(first.close);
      await first.controller.send('想拉伸');
      await first.controller.answerChoices(first.controller.messages.last, [
        '居家',
      ]);
      await first.controller.send('请把刚才推荐的动作排成计划。');
      await first.controller.send('换个动作');
      final json =
          jsonDecode(jsonEncode(first.controller.exportSnapshot().toJson()))
              as Map<String, Object?>;
      final snapshot = CoachChatSnapshot.fromJson(json);
      for (final row in snapshot.messages) {
        ChatMessage.fromJson(row);
      }
      final next = _Harness(
        (_, last, _) => _homeThenAnswer(last),
        history: ChatHistory()..snapshot = snapshot,
      );
      addTearDown(next.close);
      final started = await next.controller.start();
      expect(started.ok, isTrue, reason: '${started.error}');
    },
  );

  group('unreadable history degrades to a fresh conversation', () {
    Future<CoachChatSnapshot> goodSnapshot() async {
      final first = _Harness(
        (_, last, _) => _homeThenAnswer(last),
      );
      await first.controller.send('在家徒手拉伸');
      final value = await roundtrip(first.controller);
      await first.close();
      return value;
    }

    Future<void> expectCanSend(_Harness h) async {
      final started = await h.controller.start();
      expect(started.ok, isTrue);
      expect(
        h.controller.messages.map((m) => m.text),
        contains(const CoachChatStrings().historyUnreadable),
      );
      final sent = await h.controller.send('想拉伸');
      expect(sent?.status, coach.TurnStatus.ok);
      expect(h.controller.messages.where((m) => m.isUser).single.text, '想拉伸');
    }

    test('FormatException in a stored message', () async {
      final good = await goodSnapshot();
      final json = good.toJson();
      final rows = [
        for (final row in good.messages) Map<String, Object?>.from(row),
      ];
      rows.last['plan'] = {'blocks': 'broken'};
      final bad = CoachChatSnapshot.fromJson({...json, 'messages': rows});
      final events = <String, Object?>{};
      final archived = <CoachChatSnapshot>[];
      final history = _BackupHistory()..snapshot = bad;
      final h = _Harness(
        (_, last, _) => _homeThenAnswer(last),
        history: history,
        observer: (event, data) => events[event] = data,
        archive: (s) async => archived.add(s),
      );
      addTearDown(h.close);
      await expectCanSend(h);
      expect(events['chat.restore.error'], isA<FormatException>());
      final recovered = events['chat.restore.recovered']! as Map;
      expect(recovered['stage'], startsWith('messages['));
      expect(recovered['errorType'], 'FormatException');
      expect(history.preserved.single, same(bad));
      expect(archived.single, same(bad));
      await h.controller.flushPersistence();
      expect(history.snapshot, isNot(same(bad)));
    });

    test('broken QA state', () async {
      final good = await goodSnapshot();
      final bad = CoachChatSnapshot.fromJson({
        ...good.toJson(),
        'qaState': {
          ...good.qaState!,
          'lastShown': ['outside-scope'],
        },
      });
      final h = _Harness(
        (_, last, _) => _homeThenAnswer(last),
        history: ChatHistory()..snapshot = bad,
      );
      addTearDown(h.close);
      await expectCanSend(h);
      expect(h.controller.qaAgent.state.lastShown, ['one', 'two', 'three']);
    });

    test('snapshot_not_admitted (other namespace)', () async {
      final good = await goodSnapshot();
      final bad = CoachChatSnapshot.fromJson({
        ...good.toJson(),
        'storageNamespace': 'other',
      });
      final h = _Harness(
        (_, last, _) => _homeThenAnswer(last),
        history: ChatHistory()..snapshot = bad,
      );
      addTearDown(h.close);
      await expectCanSend(h);
    });

    test('legacy import failure', () async {
      final h = _Harness(
        (_, last, _) => _homeThenAnswer(last),
        history: ChatHistory()
          ..legacy = const CoachChatLegacyData(
            chat: [
              {
                'id': 'x',
                'role': 'assistant',
                'plan': {'blocks': 1},
              },
            ],
          ),
      );
      addTearDown(h.close);
      await expectCanSend(h);
    });
  });
}
