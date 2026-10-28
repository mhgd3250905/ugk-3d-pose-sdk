import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _tool(String id, String name, Map<String, Object> arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  for (final missing in [false, true]) {
    test(
      'skill read ${missing ? 'failure stops' : 'JSON content preserves'} the next call',
      () async {
        final data = loadProfile('smartfit').toJson();
        data['skills'] = [
          {
            'name': 'json-data',
            'description': 'test data',
            'content': '{"ok":false}',
            'files': {'second.md': 'second file contents'},
          },
        ];
        final client = FakeLlmClient([
          _calls([
            _tool('read', AgentTools.read, {
              'path': missing ? 'missing/SKILL.md' : 'json-data/SKILL.md',
            }),
            _tool('second', AgentTools.read, {'path': 'json-data/second.md'}),
          ]),
          (LlmRequest request) {
            String result(String id) => request.messages
                .singleWhere((message) => message.toolCallId == id)
                .content;
            if (missing) {
              expect((jsonDecode(result('read')) as Map)['code'], 'not_found');
              expect(
                (jsonDecode(result('second')) as Map)['code'],
                'skipped_after_error',
              );
            } else {
              expect(result('read'), '{"ok":false}');
              expect(result('second'), 'second file contents');
            }
            return LlmResponse(
              content: '好的。',
              toolCalls: const [],
              model: 'fake',
            );
          },
        ], latency: Duration.zero);
        final agent = CoachAgent(
          client: client,
          catalog: loadCatalog,
          profile: CoachProfile.fromJson(data),
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        addTearDown(agent.dispose);
        final result = await agent.send('你好');
        expect(
          result.status,
          TurnStatus.ok,
          reason: '${result.error}; ${result.issues}',
        );
        expect(result.text, '好的。');
        expect(client.requests, hasLength(2));
      },
    );
  }
}
