import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  test(
    'failed response diagnostics and billed usage reach Agent records',
    () async {
      var attempts = 0;
      final client = OpenAiCompatibleClient(
        config: const LlmConfig(
          baseUrl: 'https://example.invalid/v1',
          model: 'test',
          maxRetries: 0,
        ),
        httpClient: MockClient((_) async {
          if (attempts++ == 0) {
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': '',
                      'tool_calls': [
                        {
                          'id': 'begin',
                          'type': 'function',
                          'function': {
                            'name': 'start_task',
                            'arguments': '{"type":"plan"}',
                          },
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': '',
                    'reasoning_content': 'private reasoning',
                  },
                  'finish_reason': 'content_filter',
                },
              ],
              'usage': {'prompt_tokens': 17, 'completion_tokens': 3},
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final catalog = loadCatalog();
      var fallbackCalled = false;
      final agent = CoachAgent(
        client: client,
        profile: loadProfile('hiplab'),
        catalog: () => catalog,
        enableUserMemory: false,
        maxRequestRetries: 0,
        fallback: (_) {
          fallbackCalled = true;
          return const SessionFallbackReply('template');
        },
      );
      addTearDown(agent.dispose);
      // Complete planning conditions let the request reach the client; a
      // failed plan now returns an error without automatically using a preset.
      final result = await agent.send('在家徒手 15 分钟安排一组训练');
      expect(result.status, TurnStatus.error);
      expect(fallbackCalled, isFalse);
      final record = result.records.last;
      expect(record.errorKind, 'badResponse');
      expect(record.finishReason, 'content_filter');
      expect(record.usage.totalTokens, 20);
      expect(record.errorMessage, contains('reasoningOnly'));
      expect(record.errorMessage, contains('bodySha256'));
      expect(record.errorMessage, isNot(contains('private reasoning')));
      expect(
        UsageRecord.fromJson(record.toJson()).finishReason,
        'content_filter',
      );
    },
  );
}
