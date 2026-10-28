import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../tool/eval_thinking_mode.dart';

void main() {
  test('thinking defaults to on and accepts only explicit on or off', () {
    expect(parseEvaluationThinkingMode(null), EvaluationThinkingMode.on);
    expect(parseEvaluationThinkingMode('on'), EvaluationThinkingMode.on);
    expect(parseEvaluationThinkingMode('off'), EvaluationThinkingMode.off);
    for (final value in ['', 'enabled', 'disabled', 'false', 'ON']) {
      expect(() => parseEvaluationThinkingMode(value), throwsArgumentError);
    }
  });

  for (final mode in EvaluationThinkingMode.values) {
    test('${mode.name} maps to an explicit real request protocol value', () {
      final client = OpenAiCompatibleClient(
        config: LlmConfig.ugkWorker.copyWith(
          extraBody: {...LlmConfig.ugkWorker.extraBody, ...mode.extraBody},
        ),
      );
      addTearDown(client.close);
      final body = client.buildBody(
        const LlmRequest(messages: [LlmMessage.user('你好')]),
      );
      final decoded = (jsonDecode(jsonEncode(body)) as Map)
          .cast<String, Object?>();
      expect(
        (decoded['thinking'] as Map)['type'],
        mode == EvaluationThinkingMode.on ? 'enabled' : 'disabled',
      );
      expect(evaluationRequestThinkingMode(decoded), mode.name);
      expect(decoded['model'], 'deepseek-v4-flash-0731');
    });
  }
  test('missing request thinking is explicitly unknown', () {
    expect(evaluationRequestThinkingMode({}), 'unknown');
  });
}
