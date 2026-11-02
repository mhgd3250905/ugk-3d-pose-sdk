import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/src/core/app_profile.dart';
import 'package:ugk_coach_chat/src/core/chat_bindings.dart';
import 'package:ugk_coach_chat/src/core/chat_controller.dart';
import 'package:ugk_coach_chat/src/core/chat_snapshot.dart';
import 'package:ugk_trainer_runtime/engine.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart'
    show TrainingLibraryConfig;

coach.LlmToolCall chatCall(String id, String name, Object args) =>
    coach.LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
coach.LlmResponse chatCalls(List<coach.LlmToolCall> calls) => coach.LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
);

coach.Catalog chatCatalog({List<String> equipment = const []}) =>
    coach.Catalog.fromJson({
      'format': 'pose-hub-catalog',
      'formatVersion': 1,
      'version': 'chat-test-1',
      'taxonomy': {
        if (equipment.isNotEmpty)
          'equipment': {
            'mat': {'zh': '瑜伽垫'},
          },
        'muscleGroups': {
          'adductors': {'zh': '大腿内侧'},
        },
      },
      'drills': [
        for (final id in ['one', 'two', 'three', 'four', 'outside'])
          {
            'id': id,
            'name': {'zh': '$id伸展'},
            'purpose': '温和拉伸',
            'category': 'stretch',
            'muscles': ['adductors'],
            'muscleGroups': ['adductors'],
            'equipment': equipment,
            'position': 'standing',
            'unilateral': false,
            'level': 1,
            'scenes': ['home'],
            'defaultDose': {
              'mode': 'time',
              'sets': 1,
              'seconds': 90,
              'restSeconds': 0,
            },
            'doseRange': {
              'sets': [1, 3],
              'seconds': [10, 120],
              'restSeconds': [0, 30],
            },
            'cues': {
              'zh': ['缓慢完成'],
            },
            'cautions': <String>[],
            'contraindications': <String>[],
            'trainingDefinitionComplete': true,
          },
      ],
    });

coach.TrainingPlan chatPlan({
  String id = 'original',
  String third = 'three',
  List<String> equipment = const [],
}) => coach.TrainingPlan(
  id: id,
  source: 'ai',
  title: '髋部放松',
  summary: '温和完成',
  goal: 'relax',
  scene: 'home',
  equipment: equipment,
  level: 1,
  targetMinutes: 5,
  blocks: [
    coach.PlanBlock(
      id: 'main',
      name: '主训练',
      type: coach.BlockType.main,
      items: [
        for (final action in ['one', 'two', third])
          coach.PlanItem(
            exerciseId: action,
            mode: coach.DoseMode.time,
            sets: 1,
            workSeconds: 90,
            perSide: false,
            restSeconds: 0,
          ),
      ],
    ),
  ],
);

class ChatPlans extends CoachPlanStorageAdapter {
  ChatPlans([List<CoachSavedPlanSnapshot> values = const []])
    : values = [...values];
  final List<CoachSavedPlanSnapshot> values;
  final writes = <CoachPlanWriteRequest>[];
  final updates = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<List<CoachSavedPlanSnapshot>> load() async => [...values];
  @override
  Future<CoachPlanWriteResult> save(CoachPlanWriteRequest request) async {
    writes.add(request);
    final previous = values
        .where((p) => p.externalId == request.externalId)
        .firstOrNull;
    if (request.mode == CoachPlanWriteMode.update) {
      if (previous == null) {
        return const CoachPlanWriteResult.failure(CoachPlanWriteStatus.deleted);
      }
      if (previous.storageRevision != request.expectedStorageRevision) {
        return const CoachPlanWriteResult.failure(
          CoachPlanWriteStatus.conflict,
        );
      }
    }
    final saved = CoachSavedPlanSnapshot(
      externalId: previous?.externalId ?? 'new-${writes.length}',
      title: request.name,
      plan: request.plan,
      sdkVersion: request.sdkVersion,
      storageRevision: 'r${writes.length + 1}',
    );
    values.removeWhere((p) => p.externalId == saved.externalId);
    values.add(saved);
    return CoachPlanWriteResult.saved(saved);
  }
}

class ChatHistory extends CoachChatHistoryStore {
  CoachChatSnapshot? snapshot;
  CoachChatLegacyData? legacy;
  final writes = <CoachChatSnapshot>[];
  final remembered = <coach.TrainingPlan>[];
  Completer<void>? firstWrite;
  @override
  Future<CoachChatSnapshot?> load(String namespace) async => snapshot;
  @override
  Future<CoachChatLegacyData?> loadLegacy(String namespace) async => legacy;
  @override
  Future<void> write(String namespace, CoachChatSnapshot value) async {
    if (writes.isEmpty && firstWrite != null) await firstWrite!.future;
    writes.add(value);
    snapshot = value;
  }

  @override
  Future<void> rememberStartedPlan(
    coach.TrainingPlan plan, {
    String? savedExternalId,
  }) async {
    remembered.add(plan);
  }
}

class ChatPreferences extends CoachChatPreferenceStore {
  ChatPreferences({bool accepted = true})
    : value = CoachChatPreferences(safetyAccepted: accepted);
  CoachChatPreferences value;
  final updates = StreamController<CoachChatPreferences>.broadcast();
  @override
  Future<CoachChatPreferences> load() async => value;
  @override
  Stream<CoachChatPreferences> get changes => updates.stream;
  @override
  Future<void> update(CoachChatPreferences next) async {
    value = next;
    updates.add(next);
  }
}

class ChatHarness {
  ChatHarness({
    List<Object> script = const [],
    ChatPlans? plans,
    ChatHistory? history,
    bool safetyAccepted = true,
    Future<SessionResult?> Function(BuildContext, CoachChatTrainingRequest)?
    onTraining,
    FutureOr<void> Function()? release,
    CoachChatObserver? observer,
    Future<void> Function(CoachChatSnapshot)? beforeNewConversation,
    List<String> allowedActionIds = const ['one', 'two', 'three', 'four'],
    List<String> equipment = const [],
    TrainingLibraryConfig? library,
  }) : client = coach.FakeLlmClient(script, latency: Duration.zero),
       plans = plans ?? ChatPlans(),
       history = history ?? ChatHistory(),
       preferences = ChatPreferences(accepted: safetyAccepted) {
    final catalog = chatCatalog(equipment: equipment);
    final profile = CoachAppProfile(
      library: library,
      appId: 'chat-test',
      scopeManifest: coach.CoachActionScopeManifest.fromCatalogBytes(
        appId: 'chat-test',
        catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
        allowedActionIds: allowedActionIds,
      ),
      coachProfile: const coach.CoachProfile(id: 'chat-test', appName: '训练助手'),
      conversationPolicy: coach.CoachScopeConversationPolicy(
        specialty: '本 App 专注髋部和温和拉伸。',
        suggestions: ['髋部放松'],
      ),
      executionTiming: (plan) => coach.PlanExecutionTiming(
        totalSeconds: 300,
        blocks: [
          for (final block in plan.blocks)
            coach.PlanBlockExecutionTiming(blockId: block.id, seconds: 300),
        ],
        containsManualCounting: false,
      ),
    );
    controller = CoachChatController(
      profile: profile,
      catalog: catalog,
      clock: () => DateTime(2026, 10, 30, 12),
      replyDelay: Duration.zero,
      bindings: CoachChatBindings(
        storageNamespace: 'test',
        gateway: CoachGatewayBinding(
          create: () {
            creations++;
            return release == null
                ? CoachClientLease.shared(client)
                : CoachClientLease.owned(client, release: release);
          },
        ),
        plans: this.plans,
        history: this.history,
        preferences: preferences,
        observer: observer,
        beforeNewConversation: beforeNewConversation,
        actions: CoachChatHostActions(
          onStartTraining: onTraining ?? (_, _) async => null,
          onOpenAction: (_, _) async {},
          onOpenLibrary: (_, _) async {},
          onOpenSavedPlans: (_) async {},
          onOpenCustomPlan: (_) async {},
          onOpenSettings: (_) async {},
          onSaved: (_) => savedNotifications++,
        ),
      ),
    );
  }
  final coach.FakeLlmClient client;
  final ChatPlans plans;
  final ChatHistory history;
  final ChatPreferences preferences;
  late final CoachChatController controller;
  int creations = 0, savedNotifications = 0;
  Future<void> close() async {
    await controller.close();
    controller.dispose();
    await plans.updates.close();
    await preferences.updates.close();
  }
}

List<Object> chatPlanScript() => [
  chatCalls([
    chatCall('start', coach.AgentTools.startTask, {'type': 'plan'}),
    chatCall('params', coach.AgentTools.setParams, {
      'fields': {
        'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
        'goal': {
          'value': ['purpose.stretch'],
          'source': 'user',
          'quote': '拉伸',
        },
        'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
      },
    }),
    chatCall('search', coach.AgentTools.searchActions, {
      'tags': <String>[],
      'limit': 20,
    }),
  ]),
  chatCalls([
    chatCall('draft', coach.AgentTools.draftPlan, {
      'title': '髋部放松',
      'blocks': [
        {
          'kind': 'main',
          'items': [
            for (final id in ['one', 'two', 'three']) {'id': id},
          ],
        },
      ],
    }),
    chatCall('show', coach.AgentTools.showPlan, {'note': '温和完成。'}),
  ]),
];

List<Object> chatEditScript(String third) => [
  chatCalls([
    chatCall('start', coach.AgentTools.startTask, {
      'type': 'plan',
      'reuse': true,
    }),
    chatCall('params', coach.AgentTools.setParams, {
      'fields': {
        'operation': {'value': 'edit', 'source': 'user', 'quote': '替换第3个动作'},
      },
    }),
    chatCall('search', coach.AgentTools.searchActions, {
      'tags': <String>[],
      'limit': 20,
    }),
  ]),
  chatCalls([
    chatCall('draft', coach.AgentTools.draftPlan, {
      'title': '髋部放松新版',
      'blocks': [
        {
          'kind': 'main',
          'items': [
            {'id': 'one', 'sourceIndex': 1},
            {'id': 'two', 'sourceIndex': 2},
            {'id': third},
          ],
        },
      ],
    }),
    chatCall('show', coach.AgentTools.showPlan, {'note': '温和完成。'}),
  ]),
];

void main() {
  test(
    'startup is idempotent and keeps the original greeting without a model request',
    () async {
      final h = ChatHarness();
      addTearDown(h.close);
      final first = h.controller.start();
      final again = h.controller.start();
      expect(identical(first, again), isTrue);
      expect((await first).ok, isTrue);
      expect(h.creations, 1);
      expect(h.client.requests, isEmpty);
      expect(h.controller.messages.single.text, '中午好\n说说今天想怎么练？');
    },
  );

  test(
    'a delivered card uses the same canonical admitted plan and core conversation',
    () async {
      final h = ChatHarness(script: chatPlanScript());
      addTearDown(h.close);
      await h.controller.start();
      final result = await h.controller.send('在家拉伸5分钟');
      expect(
        result?.plan,
        isNotNull,
        reason: '${result?.issues} ${result?.error}',
      );
      final message = h.controller.messages.lastWhere((m) => m.plan != null);
      expect(identical(message.plan, result!.plan!.plan), isTrue);
      expect(message.plan!.items, isNotEmpty);
      expect(
        message.plan!.exerciseIds.difference(
          h.controller.profile.allowedActionIds,
        ),
        isEmpty,
      );
      expect(
        identical(h.controller.conversation.agent, h.controller.agent),
        isTrue,
      );
      expect(h.client.requests.length, 2);
    },
  );

  for (final mode in ['text', 'choice', 'form']) {
    test(
      '$mode clarification answers delegate to the existing conversation',
      () async {
        final h = ChatHarness(
          script: [
            chatCalls([
              chatCall('ask', coach.AgentTools.askUser, {
                'question': '想练哪个部位？',
                'mode': mode,
                if (mode == 'choice') 'options': ['髋部', '臀部'],
                if (mode == 'form')
                  'fields': [
                    {
                      'key': 'scene',
                      'label': '地点',
                      'options': ['在家', '办公室'],
                    },
                  ],
              }),
            ]),
            '收到。',
          ],
        );
        addTearDown(h.close);
        await h.controller.send('我想拉伸');
        final question = h.controller.messages.lastWhere(
          (m) => m.question != null,
        );
        expect(question.question!.mode.name, mode);
        expect(h.controller.canAnswerQuestion(question), isTrue);
        if (mode == 'choice') {
          await h.controller.answerChoices(question, ['髋部']);
        } else if (mode == 'form') {
          await h.controller.answerForm(question, {
            'scene': ['在家'],
          });
        } else {
          await h.controller.answerQuestion(question, '髋部');
        }
        expect(h.controller.canAnswerQuestion(question), isFalse);
        expect(h.controller.messages.last.text, '收到。');
        expect(h.client.requests, hasLength(2));
      },
    );
  }

  test('cancellation discards a late custom-transport reply', () async {
    final pending = Completer<coach.LlmResponse>();
    final h = ChatHarness(script: [(coach.LlmRequest _) => pending.future]);
    addTearDown(h.close);
    final send = h.controller.send('我想拉伸');
    while (h.client.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    h.controller.cancelRequest();
    final count = h.controller.messages.length;
    pending.complete(
      const coach.LlmResponse(
        content: '迟到的回复',
        toolCalls: [],
        finishReason: 'stop',
      ),
    );
    await send;
    expect(h.controller.typing, isFalse);
    expect(h.controller.messages, hasLength(count));
    expect(h.controller.messages.any((m) => m.text == '迟到的回复'), isFalse);
  });

  test(
    'the safety talk retains its four questions and a yes blocks training',
    () async {
      final h = ChatHarness(safetyAccepted: false);
      addTearDown(h.close);
      await h.controller.start();
      expect(h.controller.inSafetyCheck, isTrue);
      await h.controller.choose(h.controller.messages.last, 0);
      expect(h.controller.messages.last.text, startsWith('1/4'));
      await h.controller.choose(h.controller.messages.last, 1);
      expect(h.controller.inSafetyCheck, isFalse);
      expect(h.controller.preferences.trainingAllowed, isFalse);
      expect(h.controller.messages.last.text, contains('先不为你生成训练计划'));
      await h.controller.send('在家练5分钟');
      expect(h.client.requests, isEmpty);
    },
  );

  test(
    'close flushes the captured snapshot and releases an owned gateway once',
    () async {
      var releases = 0;
      final h = ChatHarness(release: () => releases++);
      await h.controller.start();
      final before = h.controller.exportSnapshot().toJson();
      await h.controller.close();
      await h.controller.close();
      h.controller.dispose();
      expect(releases, 1);
      expect(h.history.writes.last.toJson(), before);
      await h.plans.updates.close();
      await h.preferences.updates.close();
    },
  );

  testWidgets(
    'host training freezes before input dismissal and returns one canonical receipt',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        final events = <String>[];
        late ChatHarness h;
        final receipt = SessionResult(
          sessionId: 'session-one',
          planId: 'original',
          planTitle: '髋部放松',
          startedAt: DateTime(2026),
          endedAt: DateTime(2026, 1, 1, 0, 5),
          activeSeconds: 300,
          endedEarly: false,
          completedExercises: 3,
          totalExercises: 3,
          items: const [],
        );
        h = ChatHarness(
          onTraining: (_, request) async {
            final release = request.holdTransition();
            events.add('hold');
            final first = request.onStarting();
            final again = request.onStarting();
            expect(identical(first, again), isTrue);
            expect(await first, isTrue);
            events.add('started');
            release();
            return receipt;
          },
        );
        try {
          await h.controller.sendPlanToConversation(
            CoachSavedPlanSnapshot(
              externalId: 'saved',
              title: '我的计划',
              plan: chatPlan(),
              storageRevision: 'r1',
            ),
          );
          final card = h.controller.messages.lastWhere(
            (message) => message.plan != null,
          );
          final result = await h.controller.startTraining(
            context,
            card,
            beforeStarting: () {
              expect(h.controller.transitionActivity.active, isTrue);
              events.add('dismiss');
            },
            afterStarting: () async {
              events.add('retire');
              return true;
            },
          );
          expect(identical(result, receipt), isTrue);
          expect(events, ['hold', 'dismiss', 'retire', 'started']);
          expect(h.history.remembered, hasLength(1));
          final count = h.controller.messages.length;
          h.controller.completeTraining(card.plan!, receipt);
          expect(h.controller.messages, hasLength(count));
          expect(h.controller.messages.last.receiptSessionId, 'session-one');
          expect(h.plans.writes, isEmpty);
        } finally {
          await h.close();
        }
      });
    },
  );
}
