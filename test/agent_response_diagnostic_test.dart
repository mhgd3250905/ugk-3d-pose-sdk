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
      final client = OpenAiCompatibleClient(
        config: const LlmConfig(
          baseUrl: 'https://example.invalid/v1',
          model: 'test',
          maxRetries: 0,
        ),
        httpClient: MockClient(
          (_) async => http.Response(
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
          ),
        ),
      );
      addTearDown(client.close);
      final catalog = loadCatalog();
      final agent = CoachAgent(
        client: client,
        profile: loadProfile('hiplab'),
        catalog: () => catalog,
        enableUserMemory: false,
        maxRequestRetries: 0,
        fallback: (_) => const SessionFallbackReply('template'),
      );
      addTearDown(agent.dispose);
      final result = await agent.send('训练建议');
      expect(result.status, TurnStatus.fallback);
      final record = result.records.single;
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
