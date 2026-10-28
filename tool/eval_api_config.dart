/// Evaluation-only route and credential loading. App SDK defaults stay intact.
library;

import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';

import 'eval_thinking_mode.dart';

const evaluationBaseUrl = 'https://ai.uuugk.win/v1';
const evaluationModel = 'deepseek-flash';
const evaluationKeyFile = r'E:\AII-3D\coach.local.apikey.txt';

LlmConfig evaluationLlmConfig(EvaluationThinkingMode mode) => LlmConfig(
  baseUrl: evaluationBaseUrl,
  model: evaluationModel,
  maxTokens: 6000,
  timeout: const Duration(seconds: 120),
  maxRetries: 0,
  extraBody: mode.extraBody,
);

/// Never echo the supplied value in configuration diagnostics.
String validateEvaluationApiKey(String value) {
  if (value.isEmpty ||
      value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
    throw StateError(
      'UGK_API_KEY must be a single nonempty ASCII token without whitespace or header controls',
    );
  }
  return value;
}

Future<String> readEvaluationApiKey(
  Map<String, String> env, {
  Future<String> Function(String path)? readFile,
}) async {
  final configured = env['UGK_API_KEY'];
  if (configured != null && configured.trim().isNotEmpty) {
    return validateEvaluationApiKey(configured.trim());
  }
  final text = await (readFile ?? (path) => File(path).readAsString())(
    evaluationKeyFile,
  );
  final lines = RegExp(
    r'^[ \t]*API Key[ \t]*[:：][ \t]*([^\r\n]*)\r?$',
    multiLine: true,
  ).allMatches(text).toList();
  if (lines.length != 1) {
    throw StateError('Expected one API Key field in the authorized local file');
  }
  return validateEvaluationApiKey(lines.single.group(1)!.trim());
}
