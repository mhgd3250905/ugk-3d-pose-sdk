import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _tool(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));
LlmResponse _tools(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);
Map<String, dynamic> _feedback(LlmRequest request, String id) =>
    jsonDecode(request.messages.singleWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;

void main() {
  test('unsupported park request resumes as a confirmed home plan', () async {
    const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
    final catalog = PoseHubAppTestCatalog.fromBytes(
      File('$root/catalog.json').readAsBytesSync(),
      semanticCatalogBytes: File(
        '$root/catalog/catalog.json',
      ).readAsBytesSync(),
    ).toAiCatalog();
    final profile = loadProfile('smartfit');
    const warmup = ['n-squat-shift', 'forearms-A', 'n-pelvis-circle'];
    const main = ['h-squat', 'h-good-morning', 'erectors-A', 'obliques-A'];
    const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
    const ids = [...warmup, ...main, ...cooldown];
    late String planId;
    final client = FakeLlmClient([
      _tools([
        _tool('start', AgentTools.startTask, {'type': 'plan'}),
        _tool('understand', AgentTools.check, {'node': 'understand'}),
        _tool('minutes', AgentTools.setParams, {
          'fields': {
            'minutes': {'value': 20, 'source': 'user', 'quote': '20分钟'},
          },
        }),
      ]),
      _tools([
        _tool('ask', AgentTools.askUser, {
          'question': '目前不能提供户外动作，愿意改为居家徒手吗？',
          'mode': 'choice',
          'options': ['居家徒手', '只在户外'],
        }),
      ]),
      _tools([
        _tool('answer', AgentTools.setParams, {
          'fields': {
            'scene': {'value': 'home', 'source': 'user', 'quote': '居家徒手'},
            'equipment': {
              'value': <String>[],
              'source': 'user',
              'quote': '居家徒手',
            },
          },
        }),
      ]),
      _tools([
        _tool('ask-goal', AgentTools.askUser, {
          'question': '你想重点练哪里？',
          'mode': 'text',
        }),
      ]),
      _tools([
        _tool('goal', AgentTools.setParams, {
          'fields': {
            'goal': {
              'value': ['body.core'],
              'source': 'user',
              'quote': '练核心',
            },
          },
        }),
        _tool('parameters', AgentTools.check, {'node': 'parameters'}),
        for (var i = 0; i < ids.length; i++)
          _tool('search$i', AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[ids[i]]!.name.of('en'),
          }),
      ]),
      (LlmRequest request) {
        expect(_feedback(request, 'goal')['ok'], isTrue);
        expect(_feedback(request, 'parameters')['ok'], isTrue);
        for (var i = 0; i < ids.length; i++) {
          final search = _feedback(request, 'search$i');
          expect(search['ok'], isTrue, reason: '$search');
          expect(
            (search['items'] as List).map((e) => (e as Map)['id']),
            contains(ids[i]),
          );
        }
        return _tools([
          _tool('actions', AgentTools.check, {'node': 'actions', 'picks': ids}),
          _tool('draft', AgentTools.draftPlan, {
            'title': '居家徒手训练',
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
          }),
        ]);
      },
      (LlmRequest request) {
        expect(_feedback(request, 'actions')['ok'], isTrue);
        final draft = _feedback(request, 'draft');
        expect(draft['ok'], isTrue, reason: '$draft');
        planId = draft['plan_id'] as String;
        return _tools([
          _tool('planning', AgentTools.check, {'node': 'planning'}),
          _tool('check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        expect(_feedback(request, 'planning')['ok'], isTrue);
        final check = _feedback(request, 'check');
        expect(check['ok'], isTrue, reason: '$check');
        return _tools([
          _tool('review', AgentTools.check, {'node': 'review'}),
        ]);
      },
      (LlmRequest request) {
        expect(_feedback(request, 'review')['ok'], isTrue);
        return _tools([
          _tool('show', AgentTools.showPlan, {
            'plan_id': planId,
            'note': '以核心为重点安排居家训练。',
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
    coach.events.listen(events.add);
    final first = await coach.send('我在公园想练20分钟');
    expect(first.question, isNotNull, reason: '${first.error} ${first.issues}');
    expect(first.question!.question, contains('不能提供户外'));
    expect(first.question!.options, contains('居家徒手'));
    expect(coach.sessionState.params.containsKey('scene'), isFalse);
    final second = await coach.send('居家徒手');
    expect(
      second.question,
      isNotNull,
      reason: '${second.error} ${second.issues}',
    );
    expect(second.question!.question, contains('重点练哪里'));
    expect(coach.sessionState.params.containsKey('goal'), isFalse);
    final result = await coach.send('练核心');
    expect(
      result.status,
      TurnStatus.ok,
      reason: '${result.error} ${result.issues}',
    );
    expect(result.plan, isNotNull);
    final scene = coach.sessionState.params['scene']!;
    final equipment = coach.sessionState.params['equipment']!;
    final goal = coach.sessionState.params['goal']!;
    expect((scene.value, scene.source, scene.quote), ('home', 'user', '居家徒手'));
    expect(equipment.value, isEmpty);
    expect((equipment.source, equipment.quote), ('user', '居家徒手'));
    expect(goal.value, ['body.core']);
    expect((goal.source, goal.quote), ('user', '练核心'));
    final parameterNode = coach.sessionState.task!.nodes.singleWhere(
      (n) => n.id == 'parameters',
    );
    expect(parameterNode.stamp, contains('居家（你说的）'));
    expect(parameterNode.stamp, contains('徒手（可用'));
    expect(parameterNode.stamp, contains('墙'));
    expect(parameterNode.stamp, contains('（你说的）'));
    expect(
      coach.sessionState.task!.nodes.map((n) => n.status),
      everyElement('done'),
    );
    final completed = events
        .where((e) => e.kind == AgentEventKind.node && e.node?.status == 'done')
        .map((e) => e.node!.id);
    expect(completed, [
      'understand',
      'parameters',
      'actions',
      'planning',
      'review',
      'output',
    ]);
  });
}
