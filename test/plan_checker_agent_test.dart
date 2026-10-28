import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall call(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
LlmResponse calls(List<LlmToolCall> values) => LlmResponse(
  content: '',
  toolCalls: values,
  finishReason: 'tool_calls',
  model: 'fake',
);
Map<String, dynamic> feedback(LlmRequest request, String id) =>
    jsonDecode(request.messages.singleWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;

void main() {
  const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$root/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$root/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  const warmup = ['h-step-jack', 'forearms-A', 'n-pelvis-circle'];
  const firstMain = [
    'h-squat',
    'h-good-morning',
    'h-kneeling-pushup',
    'erectors-A',
  ];
  const repairedMain = [
    'h-sumo-pry',
    'n-squat-shift',
    'o-stand-sidebend',
    'h-squat',
  ];
  const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
  final ids = {...warmup, ...firstMain, ...repairedMain, ...cooldown}.toList();
  Map<String, Object?> draft(List<String> main, {String? planId}) => {
    'plan_id': ?planId,
    'title': '居家大腿内侧拉伸',
    'blocks': [
      {
        'kind': 'warmup',
        'items': [
          for (final id in warmup) {'id': id},
        ],
      },
      {
        'kind': 'main',
        'rounds': 2,
        'items': [
          for (final id in main) {'id': id},
        ],
      },
      {
        'kind': 'cooldown',
        'items': [
          for (final id in cooldown) {'id': id},
        ],
      },
    ],
  };

  test(
    'real agent check failure returns to planning and repaired version passes',
    () async {
      late String planId;
      final client = FakeLlmClient([
        calls([
          call('start', AgentTools.startTask, {'type': 'plan'}),
          call('understand', AgentTools.check, {'node': 'understand'}),
          call('params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
              'goal': {
                'value': ['body.inner_thigh', 'purpose.stretch'],
                'source': 'user',
                'quote': '大腿内侧拉伸',
              },
              'minutes': {'value': 20, 'source': 'user', 'quote': '20分钟'},
            },
          }),
          call('parameters', AgentTools.check, {'node': 'parameters'}),
          for (var i = 0; i < ids.length; i++)
            call('search$i', AgentTools.searchActions, {
              'tags': <String>[],
              'keywords': catalog[ids[i]]!.name.of('en'),
            }),
        ]),
        (LlmRequest request) {
          for (var i = 0; i < ids.length; i++) {
            final search = feedback(request, 'search$i');
            expect(search['ok'], isTrue, reason: '$i $search');
            expect(
              (search['items'] as List).map((e) => (e as Map)['id']),
              contains(ids[i]),
            );
          }
          return calls([
            call('actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            call('draft1', AgentTools.draftPlan, draft(firstMain)),
          ]);
        },
        (LlmRequest request) {
          final first = feedback(request, 'draft1');
          expect(first['ok'], isFalse, reason: '$first');
          expect(first['version'], 1);
          planId = first['plan_id'] as String;
          final failed = first;
          expect(failed['ok'], isFalse, reason: '$failed');
          expect(failed['code'], 'plan_check_failed');
          expect((failed['check'] as Map)['ok'], isFalse);
          final errors = (failed['errors'] as List)
              .cast<Map<String, dynamic>>();
          final body = errors.singleWhere(
            (e) => e['code'] == 'plan_focus_body',
          );
          final purpose = errors.singleWhere(
            (e) => e['code'] == 'plan_focus_purpose',
          );
          expect(body['actual'], '0/4');
          expect(purpose['actual'], '0/4');
          expect(body['expected'], contains('body.inner_thigh'));
          expect(purpose['expected'], contains('purpose.stretch'));
          expect(body['candidates'], contains('h-sumo-pry'));
          expect(purpose['candidates'], contains('h-sumo-pry'));
          expect(body['fix'], isNotEmpty);
          return calls([
            call(
              'draft2',
              AgentTools.draftPlan,
              draft(repairedMain, planId: planId),
            ),
          ]);
        },
        (LlmRequest request) {
          final next = feedback(request, 'draft2');
          expect(next['ok'], isTrue, reason: '$next');
          expect(next['version'], 2);
          expect((next['check'] as Map)['ok'], isTrue);
          return calls([
            call('planning2', AgentTools.check, {'node': 'planning'}),
            call('check2', AgentTools.checkPlan, {'plan_id': planId}),
          ]);
        },
        (LlmRequest request) {
          expect(feedback(request, 'planning2')['ok'], isTrue);
          final ok = feedback(request, 'check2');
          expect(ok['ok'], isTrue, reason: '$ok');
          return calls([
            call('review', AgentTools.check, {'node': 'review'}),
          ]);
        },
        (LlmRequest request) {
          expect(feedback(request, 'review')['ok'], isTrue);
          return calls([
            call('ask', AgentTools.askUser, {
              'question': '还有其他要求吗？',
              'mode': 'text',
            }),
          ]);
        },
      ], latency: Duration.zero);
      final coach = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(coach.dispose);
      final events = <AgentEvent>[];
      final subscription = coach.events.listen(events.add);
      addTearDown(subscription.cancel);
      final result = await coach.send('在家徒手20分钟大腿内侧拉伸计划');
      expect(
        result.question,
        isNotNull,
        reason: '${result.error}; ${result.issues}',
      );
      final versions = coach.sessionState.plans[planId]!;
      expect(versions.map((v) => v.version), [1, 2]);
      expect(versions.first.check!['ok'], isFalse);
      expect(versions.last.check!['ok'], isTrue);
      expect(
        coach.sessionState.task!.nodes
            .singleWhere((n) => n.status == 'current')
            .id,
        'output',
      );
      final nodeEvents = events
          .where((e) => e.kind == AgentEventKind.node && e.node != null)
          .map((e) => '${e.node!.id}:${e.node!.status}')
          .toList();
      expect(
        nodeEvents,
        containsAllInOrder([
          'planning:done',
          'review:current',
          'planning:current',
          'review:pending',
          'planning:done',
          'review:current',
          'review:done',
          'output:current',
        ]),
      );
    },
  );
}
