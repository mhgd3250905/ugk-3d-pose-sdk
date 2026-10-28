import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/tool_arguments.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall call(String id, String name, Map<String, Object?> args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

void main() {
  test(
    'form display is repaired while full English labels and choice values survive',
    () {
      const full = 'Which equipment is actually available to you right now';
      final result = AskUserGate.check(
        jsonEncode({
          'question': 'What is available?',
          'mode': 'form',
          'skipLabel': 'Skip',
          'fields': [
            {
              'key': 'equipment',
              'label': full,
              'options': ['No extra equipment', 'Dumbbells', 'Dumbbells'],
              'multiple': 'true',
              'presentationOnly': true,
            },
          ],
        }),
        language: 'en',
      );
      expect(result.ok, isTrue);
      expect(result.notes, isNotEmpty);
      expect(result.question!.fields.single.label.split(' '), hasLength(6));
      expect(result.question!.question, contains(full));
      expect(result.question!.fields.single.options, [
        'No extra equipment',
        'Dumbbells',
      ]);
      expect(result.question!.fields.single.multiple, isTrue);
      expect(result.question!.skipLabel, 'Show suggestions');
    },
  );

  test(
    'oversized choices become text without cutting or inventing meanings',
    () {
      final values = [
        for (var i = 0; i < 7; i++)
          'Complete original option number $i with its complete meaning',
      ];
      final result = AskUserGate.check(
        jsonEncode({
          'question': 'Which option?',
          'mode': 'choice',
          'options': values,
        }),
        language: 'en',
      );
      expect(result.ok, isTrue);
      expect(result.question!.mode, AskUserMode.text);
      for (final value in values) {
        expect(result.question!.question, contains(value));
      }
      expect(result.notes, isNotEmpty);
    },
  );

  test(
    'batch scheduling repairs IDs and pauses before delivery with reasoning untouched',
    () {
      const reasoning = '原始 reasoning\nwith bytes exactly preserved.';
      final original = LlmResponse(
        content: '',
        reasoning: reasoning,
        toolCalls: [
          call('same', AgentTools.askUser, {
            'question': '准备多久？',
            'mode': 'text',
          }),
          call('same', AgentTools.setParams, {'fields': {}}),
          call('same__sdk2', AgentTools.showPlan, {
            'plan_id': 'p',
            'note': '说明',
          }),
        ],
      );
      final result = normalizeToolBatch(original);
      expect(result.response.toolCalls.map((c) => c.name), [
        AgentTools.setParams,
        AgentTools.askUser,
        AgentTools.showPlan,
      ]);
      final ids = result.response.toolCalls.map((c) => c.id).toList();
      expect(ids.toSet(), hasLength(3));
      expect(ids, ['same__sdk3', 'same', 'same__sdk2']);
      expect(result.notes['same__sdk3'], isNotEmpty);
      expect(result.response.reasoning, reasoning);
      expect(original.toolCalls.map((c) => c.id), [
        'same',
        'same',
        'same__sdk2',
      ]);
    },
  );

  test(
    'a taskless search keeps only this user turn pending pool and never guesses a task type',
    () {
      final search = ActionSearch(
        loadProfile('smartfit'),
        loadCatalog(),
        minPicks: 3,
      );
      final input = CoachSessionState().appendUserTurn('推荐动作');
      final first = search.search(input, limit: 1);
      expect(first.ok, isTrue);
      expect(first.state.task, isNull);
      expect(first.state.pendingSearchTurn, 1);
      expect(first.state.seenActionIds, {first.items.single['id']});
      final next = search.search(
        first.state.appendUserTurn('另一个任务'),
        tags: ['body.inner_thigh'],
      );
      expect(next.ok, isTrue);
      expect(next.state.pendingSearchTurn, 2);
      expect(next.state.seenActionIds, next.items.map((i) => i['id']).toSet());
      expect(next.state.task, isNull);
    },
  );

  test(
    'zero legal candidates finish normally without an empty card or a retry',
    () async {
      final base = loadCatalog();
      final catalog = Catalog(
        version: 'one',
        taxonomy: base.taxonomy,
        drills: [
          Drill(
            id: 'inner-gear',
            name: LocalizedText({'zh': '器械内收'}),
            category: 'stretch',
            muscleGroups: const ['inner_thigh'],
            position: 'standing',
            level: 1,
            equipment: const ['dumbbell'],
            scenes: const ['home'],
            unilateral: false,
            defaultDose: const Dose(
              mode: DoseMode.time,
              sets: 1,
              seconds: 30,
              restSeconds: 0,
            ),
          ),
        ],
      );
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          toolCalls: [
            call('start', AgentTools.startTask, {'type': 'recommend'}),
            call('params', AgentTools.setParams, {
              'fields': {
                'goal': {
                  'value': ['body.inner_thigh'],
                  'source': 'user',
                  'quote': '练内收',
                },
              },
            }),
            call('search', AgentTools.searchActions, {
              'tags': ['body.inner_thigh'],
            }),
            call('show', AgentTools.showActions, {
              'ids': <String>[],
              'note': '暂无动作',
            }),
          ],
        ),
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: const CoachProfile(id: 'test', appName: 'Test'),
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final result = await agent.send('我想练内收');
      expect(result.status, TurnStatus.ok, reason: '${result.error}');
      expect(result.text, contains('当前条件没有合规动作'));
      expect(result.actions, isNull);
      expect(result.plan, isNull);
      expect(agent.sessionState.task, isNull);
      expect(client.requests, hasLength(1));
      expect(result.records.single.issueCodes, isEmpty);
    },
  );

  test(
    'an impossible derived duration pauses locally and defers a later delivery',
    () async {
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          toolCalls: [
            call('shorter', AgentTools.setParams, {
              'fields': {
                'minutes': {
                  'value': 5,
                  'source': 'derived',
                  'direction': 'shorter',
                  'quote': '短一点',
                },
              },
            }),
            call('show-old', AgentTools.showPlan, {
              'plan_id': 'old',
              'note': '旧计划',
            }),
          ],
        ),
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: loadCatalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final result = await agent.send(
        '短一点',
        context: const CoachContext(minutes: 5),
      );
      expect(result.status, TurnStatus.ok, reason: '${result.error}');
      expect(result.question, isNotNull);
      expect(result.plan, isNull);
      expect(agent.sessionState.params['minutes']!.value, 5);
      expect(result.records.single.issueCodes, isEmpty);
      final receipt =
          jsonDecode(
                agent.history
                    .singleWhere((m) => m.toolCallId == 'show-old')
                    .content,
              )
              as Map;
      expect(receipt['ok'], isTrue);
      expect(receipt['deferred'], isTrue);
      expect(client.requests, hasLength(1));
    },
  );
}
