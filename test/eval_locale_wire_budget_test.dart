import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import '../tool/eval_api_config.dart';
import '../tool/eval_coach_agent_v2.dart';
import '../tool/eval_thinking_mode.dart';
import 'support.dart';

void main() {
  test(
    'R6 host English locale uses English schema within actual first-wire budget',
    () async {
      const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final catalog = PoseHubAppTestCatalog.fromBytes(
        File('$pack/catalog.json').readAsBytesSync(),
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final client = FakeLlmClient([
        const LlmResponse(content: 'A short answer', model: 'fake'),
      ]);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
      );
      addTearDown(agent.dispose);
      await agent.send(
        'I sit all day, help me stretch',
        context: evaluationCaseContext({'locale': 'en'}),
      );
      final serializer = OpenAiCompatibleClient(
        config: evaluationLlmConfig(EvaluationThinkingMode.on),
      );
      addTearDown(serializer.close);
      final body = serializer.buildBody(client.requests.first);
      final bytes = utf8.encode(jsonEncode(body)).length;
      print('R6 en actual first HTTP body: $bytes B');
      // Approved scene-cue guidance raises this first-request regression budget
      // to 13 KiB; production context budgets remain unchanged.
      expect(bytes, lessThanOrEqualTo(13 * 1024));
      expect(
        client.requests.first.messages.first.content,
        contains('用 en 语言回复用户'),
      );
      final ask = client.requests.first.tools.singleWhere(
        (t) => t.name == 'ask_user',
      );
      final fields = ((ask.parameters['properties'] as Map)['fields'] as Map);
      expect((fields['items'] as Map)['type'], 'object');
      expect(
        fields.containsKey('maxItems'),
        isFalse,
        reason:
            'Form display limits are normalized locally, not model rejections.',
      );
    },
  );
}
