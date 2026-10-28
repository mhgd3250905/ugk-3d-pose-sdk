import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
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
          _call('search', 'search_actions', {
            'tags': ['body.core'],
            'limit': 3,
          }),
        ]),
        _ask('ask1'),
        (LlmRequest request) {
          return _calls([
            _call('detail', 'get_action', {
              'ids': [detailOnly],
            }),
          ]);
        },
        (LlmRequest request) {
          final detail = _feedback(request, 'detail');
          expect(detail['ok'], isTrue);
          final items = (detail['items'] as List).cast<Map<String, Object?>>();
          expect(items.single['id'], detailOnly);
          expect(items.single, contains('cues'));
          return _calls([
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
      final actionTags = ActionTags(profile, catalog);
      final goals = actionTags.expandCodes(['body.core']);
      expect(
        returned.every(
          (id) => actionTags.forActionId(id).intersection(goals).isNotEmpty,
        ),
        isTrue,
      );
      final format = (search['format'] as Map).cast<String, dynamic>();
      final fields = (format['data'] as List).cast<String>();
      final equipmentIndex = fields.indexOf('equipment_indices');
      expect(equipmentIndex, greaterThanOrEqualTo(0));
      final equipmentCodes = (format['equipment'] as List).cast<String>();
      for (final row in rows) {
        final data = row['data'] as List;
        final encoded = (data[equipmentIndex] as List).cast<int>();
        final equipment = [for (final index in encoded) equipmentCodes[index]];
        expect(
          equipment,
          everyElement(isIn(['equip.mat', 'equip.wall', 'equip.chair'])),
        );
        expect(
          catalog[row['id'] as String]!.equipment,
          everyElement(isIn(['mat', 'wall', 'chair'])),
        );
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
      expect(
        (jsonDecode(
              client.requests.last.messages
                  .singleWhere((message) => message.toolCallId == 'detail')
                  .content,
            )
            as Map)['items'],
        contains(
          predicate<Map<Object?, Object?>>((item) => item['id'] == detailOnly),
        ),
      );
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

  final invalidCases = [
    (
      id: 'tag',
      name: 'search_actions',
      args: <String, Object?>{
        'tags': ['purpose.warmup'],
      },
      code: 'invalid_tags',
    ),
    (
      id: 'too-large',
      name: 'search_actions',
      args: <String, Object?>{'tags': <String>[], 'limit': 21},
      code: null,
    ),
    (
      id: 'zero',
      name: 'search_actions',
      args: <String, Object?>{'tags': <String>[], 'limit': 0},
      code: null,
    ),
    (
      id: 'empty',
      name: 'get_action',
      args: <String, Object?>{'ids': <String>[]},
      code: null,
    ),
    (
      id: 'many',
      name: 'get_action',
      args: <String, Object?>{
        'ids': [for (var i = 0; i < 11; i++) 'id$i'],
      },
      code: 'incompatible_actions',
    ),
    (
      id: 'duplicate',
      name: 'get_action',
      args: <String, Object?>{
        'ids': ['a', 'a'],
      },
      code: 'incompatible_actions',
    ),
  ];
  for (final invalid in invalidCases) {
    test(
      '${invalid.id} rejects invalid input and skips later search',
      () async {
        final client = FakeLlmClient([
          _calls([
            _call('start-invalid-case', AgentTools.startTask, {
              'type': 'recommend',
            }),
            _call(invalid.id, invalid.name, invalid.args),
            _call('skipped-search', 'search_actions', {'tags': <String>[]}),
          ]),
          _ask('ask'),
        ], latency: Duration.zero);
        final coach = agent(client);
        await coach.send('推荐运动');
        final request = client.requests.last;
        if (invalid.code == null) {
          expect(_feedback(request, invalid.id)['ok'], isTrue);
          expect(_feedback(request, invalid.id)['notes'], isNotEmpty);
          expect(_feedback(request, 'skipped-search')['ok'], isTrue);
          expect(coach.sessionState.seenActionIds, isNotEmpty);
          return;
        }
        expect(_feedback(request, invalid.id)['code'], invalid.code);
        expect(
          _feedback(request, 'skipped-search')['code'],
          'skipped_after_error',
        );
        expect(coach.sessionState.seenActionIds, isEmpty);
      },
    );
  }
}
