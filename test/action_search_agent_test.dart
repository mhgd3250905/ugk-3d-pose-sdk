import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> tools) => LlmResponse(
  content: '',
  toolCalls: tools,
  finishReason: 'tool_calls',
  model: 'fake',
);

LlmResponse _ask(String id) => _calls([
  _call(id, 'ask_user', {'question': '还有其他要求吗？', 'mode': 'text'}),
]);

Map<String, dynamic> _feedback(LlmRequest request, String id) =>
    jsonDecode(
          request.messages
              .singleWhere((message) => message.toolCallId == id)
              .content,
        )
        as Map<String, dynamic>;

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');

  CoachAgent agent(FakeLlmClient client) {
    final coach = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(coach.dispose);
    return coach;
  }

  test(
    'returned IDs alone become seen and selected across a paused turn',
    () async {
      late List<String> returned;
      late String detailOnly;
      final client = FakeLlmClient([
        _calls([
          _call('start', 'start_task', {'type': 'recommend'}),
          _call('understand', 'check', {'node': 'understand'}),
          _call('params', 'set_params', {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'goal': {
                'value': ['body.core'],
                'source': 'user',
                'quote': '核心',
              },
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
            },
          }),
          _call('parameters', 'check', {'node': 'parameters'}),
          _call('search', 'search_actions', {'tags': <String>[], 'limit': 3}),
        ]),
        _ask('ask1'),
        (LlmRequest request) {
          return _calls([
            _call('detail', 'get_action', {
              'ids': [detailOnly],
            }),
            _call('check', 'check', {'node': 'actions', 'picks': returned}),
          ]);
        },
        _ask('ask2'),
      ], latency: Duration.zero);
      final coach = agent(client);
      final events = <AgentEvent>[];
      coach.events.listen(events.add);
      final first = await coach.send('在家徒手推荐核心动作');
      expect(first.question, isNotNull);
      final search = _feedback(client.requests.last, 'search');
      expect(search['ok'], isTrue);
      final rows = (search['items'] as List).cast<Map<String, dynamic>>();
      expect(rows, hasLength(3));
      returned = [for (final row in rows) row['id'] as String];
      expect(returned.toSet(), hasLength(3));
      final format = (search['format'] as Map).cast<String, dynamic>();
      final fields = (format['data'] as List).cast<String>();
      final equipmentIndex = fields.indexOf('equipment_indices');
      expect(equipmentIndex, greaterThanOrEqualTo(0));
      final equipmentCodes = (format['equipment'] as List).cast<String>();
      for (final row in rows) {
        final data = row['data'] as List;
        final encoded = (data[equipmentIndex] as List).cast<int>();
        final equipment = [for (final index in encoded) equipmentCodes[index]];
        expect(equipment, isEmpty);
        expect(catalog[row['id'] as String]!.equipment, isEmpty);
      }
      detailOnly = profile
          .scope(catalog)
          .firstWhere(
            (drill) =>
                drill.equipment.isEmpty &&
                drill.scenes.contains('home') &&
                !returned.contains(drill.id),
          )
          .id;
      expect((search['filter'] as Map)['hiddenEquipmentCount'], greaterThan(0));
      expect(
        coach.sessionState.seenActionIds,
        (search['items'] as List).map((row) => (row as Map)['id']).toSet(),
      );

      final second = await coach.send('没有其他要求');
      expect(
        second.question,
        isNotNull,
        reason:
            'status=${second.status}; records=${second.records.map((r) => r.toJson()).toList()}; requests=${client.requests.length}',
      );
      expect(_feedback(client.requests.last, 'detail')['ok'], isTrue);
      expect(_feedback(client.requests.last, 'check')['ok'], isTrue);
      expect(coach.sessionState.seenActionIds, returned.toSet());
      expect(coach.sessionState.seenActionIds, isNot(contains(detailOnly)));
      expect(coach.sessionState.picks, returned);
      final done = events
          .where(
            (e) => e.kind == AgentEventKind.node && e.node?.status == 'done',
          )
          .map((e) => e.node!.id);
      expect(done, ['understand', 'parameters', 'actions']);
      expect(
        coach.sessionState.task!.nodes
            .singleWhere((n) => n.status == 'current')
            .id,
        'output',
      );
    },
  );

  test('invalid tag, limit and IDs are rejected in runtime feedback', () async {
    final client = FakeLlmClient([
      _calls([
        _call('tag', 'search_actions', {
          'tags': ['purpose.warmup'],
        }),
        _call('too-large', 'search_actions', {'tags': <String>[], 'limit': 21}),
        _call('zero', 'search_actions', {'tags': <String>[], 'limit': 0}),
        _call('empty', 'get_action', {'ids': <String>[]}),
        _call('many', 'get_action', {
          'ids': [for (var i = 0; i < 11; i++) 'id$i'],
        }),
        _call('duplicate', 'get_action', {
          'ids': ['a', 'a'],
        }),
      ]),
      _ask('ask'),
    ], latency: Duration.zero);
    final coach = agent(client);
    await coach.send('推荐运动');
    final request = client.requests.last;
    expect(_feedback(request, 'tag')['code'], 'invalid_tags');
    expect(_feedback(request, 'too-large')['code'], 'invalid_limit');
    expect(_feedback(request, 'zero')['code'], 'invalid_limit');
    expect(_feedback(request, 'empty')['code'], 'invalid_ids');
    expect(_feedback(request, 'many')['code'], 'invalid_ids');
    expect(_feedback(request, 'duplicate')['ok'], isFalse);
    expect(coach.sessionState.seenActionIds, isEmpty);
  });
}
