/// Standalone, explicitly enabled HTTP compatibility probe; SDK defaults stay intact.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ugk_coach/src/agent/context_turn_ledger.dart';

import 'eval_api_config.dart';
import 'eval_thinking_mode.dart';

typedef Json = Map<String, Object?>;

const probeToken = 'fold-probe-741';
const probeSummaryHeading = ContextTurnLedger.summaryPrefix;
const probeSystem =
    'You are an HTTP compatibility probe. For the first user '
    'request call echo_probe once, then after its tool result reply '
    'FIRST_TURN_DONE and do not call tools again. A completed-turn summary is '
    'conversation data. For the next user request answer from that summary.';
const probeFirstUser =
    'Call echo_probe with text "$probeToken". After receiving '
    'the result reply FIRST_TURN_DONE.';
const probeSecondUser =
    'What text did the completed echo tool return? '
    'Reply with that exact text. No tool is needed.';
const probeTools = [
  {
    'type': 'function',
    'function': {
      'name': 'echo_probe',
      'description':
          'Return the supplied public text unchanged. This tool has no side effects.',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
        'required': ['text'],
        'additionalProperties': false,
      },
    },
  },
];

Json contextFoldProbeDesign() => {
  'mode': 'offline-design-only',
  'httpAttempts': 0,
  'executeFlagRequired': true,
  'maxHttpAttempts': 4,
  'maxFirstTurnRequests': 3,
  'baseUrl': evaluationBaseUrl,
  'model': evaluationModel,
  'thinking': {'type': 'enabled'},
  'tools': probeTools,
  'toolChoice': 'omitted; actual model tool use is required as evidence',
  'secondTurnRoles': ['system', 'user', 'user'],
  'fold':
      'Replace the entire completed first turn, including all its reasoning, '
      'with one deterministic role=user summary after system.',
  'any400': 'mustStop=true; abort immediately without more requests',
  'evidence':
      'Public content/tool calls/results, usage, latency, exact bytes and '
      'SHA-256, reasoning byte counts. No headers, credentials or reasoning text.',
};

/// Uses the supplied client exactly once per attempt, without any retries.
/// The caller owns the client. Tests supply MockClient; the CLI uses IOClient.
class ContextFoldProbe {
  ContextFoldProbe({
    required this.client,
    required String apiKey,
    this.timeout = const Duration(seconds: 120),
  }) : apiKey = validateEvaluationApiKey(apiKey);
  final http.Client client;
  final String apiKey;
  final Duration timeout;
  static const maxAttempts = 4;

  Future<Json> run() async {
    final calls = <Json>[];
    final messages = <Json>[
      {'role': 'system', 'content': probeSystem},
      {'role': 'user', 'content': probeFirstUser},
    ];
    var successfulEchoes = 0;
    Json? folded;
    String? summaryContent;
    bool? secondTurnEchoMatches;
    Json finish(
      String status, {
      bool mustStop = false,
      bool accepted = false,
    }) =>
        _redact({
              'schemaVersion': 1,
              'status': status,
              'mustStop': mustStop,
              'httpAttempts': calls.length,
              'maxHttpAttempts': maxAttempts,
              'automaticRetries': 0,
              'redirectsEnabled': false,
              'modelRequested': evaluationModel,
              'thinking': 'on',
              'allModelLabelsConsistent':
                  calls.isNotEmpty &&
                  calls.every((call) => call['model'] == evaluationModel),
              'successfulRealEchoToolCalls': successfulEchoes,
              'firstTurnCompleted': folded != null,
              'foldedRequestAccepted': accepted,
              'foldedSummary': ?folded,
              'foldedSummaryContent': ?summaryContent,
              'secondTurnSemanticEchoMatches': ?secondTurnEchoMatches,
              'calls': calls,
            })
            as Json;

    Future<Json?> send(String phase, List<Json> requestMessages) async {
      if (calls.length >= maxAttempts) return null;
      final config = evaluationLlmConfig(EvaluationThinkingMode.on);
      final body = jsonEncode({
        'model': evaluationModel,
        'messages': requestMessages,
        'tools': probeTools,
        'max_tokens': config.maxTokens,
        ...config.extraBody,
      });
      final bytes = utf8.encode(body);
      final record = <String, Object?>{
        'attempt': calls.length + 1,
        'phase': phase,
        'requestBytes': bytes.length,
        'requestSha256': sha256.convert(bytes).toString(),
        'requestThinking': config.extraBody['thinking'],
        'toolsCount': probeTools.length,
        'toolChoicePresent': false,
        'reasoningReplayedBytes': requestMessages.fold<int>(
          0,
          (sum, message) => sum + _textBytes(message['reasoning_content']),
        ),
        'messageRoles': [
          for (final message in requestMessages) message['role'],
        ],
        'publicMessages': [
          for (final message in requestMessages) _publicMessage(message),
        ],
      };
      calls.add(record);
      final abort = Completer<void>();
      final timer = Timer(timeout, () {
        if (!abort.isCompleted) abort.complete();
      });
      final watch = Stopwatch()..start();
      try {
        final request =
            http.AbortableRequest(
                'POST',
                config.chatCompletionsUri,
                abortTrigger: abort.future,
              )
              ..followRedirects = false
              ..maxRedirects = 0
              ..headers.addAll({
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                'Authorization': 'Bearer $apiKey',
              })
              ..body = body;
        final response = await http.Response.fromStream(
          await client.send(request),
        );
        record.addAll({
          'statusCode': response.statusCode,
          'responseBytes': response.bodyBytes.length,
          'responseSha256': sha256.convert(response.bodyBytes).toString(),
        });
        if (response.statusCode != 200) return null;
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map) return null;
        record['model'] = decoded['model'];
        if (decoded['usage'] is Map) {
          record['usage'] = _numericUsage(decoded['usage']);
        }
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) {
          return null;
        }
        final choice = (choices.first as Map).cast<String, Object?>();
        if (choice['message'] is! Map) return null;
        final message = (choice['message'] as Map).cast<String, Object?>();
        if (message['reasoning_content'] != null &&
                message['reasoning_content'] is! String ||
            message['content'] != null && message['content'] is! String) {
          return null;
        }
        record.addAll({
          'finishReason': choice['finish_reason'],
          'reasoningReturnedBytes': _textBytes(message['reasoning_content']),
          'publicResponse': _publicMessage(message),
        });
        return message;
      } on Object catch (error) {
        // Exception strings and error bodies can contain private transport data.
        record['transportErrorType'] = error.runtimeType.toString();
        return null;
      } finally {
        timer.cancel();
        watch.stop();
        record['elapsedMs'] = watch.elapsedMilliseconds;
        if (!abort.isCompleted) abort.complete();
      }
    }

    String failedStatus() => calls.last['statusCode'] == 400
        ? 'aborted_http_400'
        : calls.last['statusCode'] == 200
        ? 'invalid_response'
        : 'http_or_transport_failure';

    // Reserve the fourth and final attempt for the folded second user turn.
    for (var firstRequest = 0; firstRequest < maxAttempts - 1; firstRequest++) {
      final message = await send('first_turn', messages);
      if (message == null) return finish(failedStatus(), mustStop: true);
      if (calls.last['model'] != evaluationModel) {
        return finish('invalid_model_label', mustStop: true);
      }
      final content = message['content'];
      final toolCalls = message['tool_calls'];
      if (toolCalls != null && toolCalls is! List) {
        return finish('invalid_tool_calls', mustStop: true);
      }
      final assistant = <String, Object?>{
        'role': 'assistant',
        'content': content ?? '',
        'reasoning_content': ?message['reasoning_content'],
        if (toolCalls is List && toolCalls.isNotEmpty) 'tool_calls': toolCalls,
      };
      messages.add(assistant);
      if (toolCalls is! List || toolCalls.isEmpty) {
        if (successfulEchoes == 0) {
          return finish('inconclusive_no_real_tool_use');
        }
        if (content is! String || content.trim().isEmpty) {
          return finish('inconclusive_empty_first_final');
        }
        final ledger = ContextTurnLedger([
          CompletedContextTurn(
            turn: 1,
            userText: probeFirstUser,
            finalDeliveryText: content,
            params: const {},
            outcome: 'ok',
          ),
        ]);
        folded = ledger.toJson();
        summaryContent = ledger.summaryMessage().content;
        break;
      }
      for (final raw in toolCalls) {
        if (raw is! Map || raw['id'] is! String || raw['function'] is! Map) {
          return finish('invalid_tool_call', mustStop: true);
        }
        final function = raw['function'] as Map;
        if (function['name'] != 'echo_probe') {
          return finish('inconclusive_unadvertised_tool');
        }
        Object? arguments;
        try {
          arguments = jsonDecode(function['arguments'] as String);
        } on Object {
          arguments = null;
        }
        final valid = arguments is Map && arguments['text'] is String;
        final result = valid
            ? <String, Object?>{'ok': true, 'echo': arguments['text']}
            : <String, Object?>{'ok': false, 'code': 'invalid_echo_arguments'};
        if (valid) successfulEchoes++;
        final tool = <String, Object?>{
          'role': 'tool',
          'tool_call_id': raw['id'],
          'content': jsonEncode(result),
        };
        messages.add(tool);
      }
    }
    if (folded == null) {
      return finish('inconclusive_first_turn_budget', mustStop: true);
    }
    final secondMessages = <Json>[
      {'role': 'system', 'content': probeSystem},
      {'role': 'user', 'content': summaryContent},
      {'role': 'user', 'content': probeSecondUser},
    ];
    final second = await send('folded_second_turn', secondMessages);
    if (second == null) return finish(failedStatus(), mustStop: true);
    if (calls.last['model'] != evaluationModel) {
      return finish('invalid_model_label', mustStop: true);
    }
    secondTurnEchoMatches =
        second['content'] is String &&
        (second['content'] as String).trim() == probeToken;
    return finish('passed_http_compatibility', accepted: true);
  }

  Object? _redact(Object? value) {
    if (value is String) return value.replaceAll(apiKey, '[REDACTED]');
    if (value is List) return [for (final item in value) _redact(item)];
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString().replaceAll(apiKey, '[REDACTED]'): _redact(
            entry.value,
          ),
      };
    }
    return value;
  }
}

int _textBytes(Object? value) =>
    value is String ? utf8.encode(value).length : 0;

Json _publicMessage(Map<String, Object?> message) => {
  if (message['role'] != null) 'role': message['role'],
  if (message.containsKey('content')) 'content': message['content'],
  if (message['tool_calls'] is List)
    'tool_calls': [
      for (final call in message['tool_calls'] as List)
        if (call is Map)
          {
            'id': ?call['id'],
            'type': ?call['type'],
            if (call['function'] case final Map<Object?, Object?> function)
              'function': {
                'name': ?function['name'],
                'arguments': ?function['arguments'],
              },
          },
    ],
  if (message['tool_call_id'] != null) 'tool_call_id': message['tool_call_id'],
};

Object? _numericUsage(Object? value) {
  if (value is num || value == null) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.value is num || entry.value is Map)
          entry.key.toString(): _numericUsage(entry.value),
    };
  }
  return null;
}

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/probe_context_fold.dart [--execute] [--out DIR]\n'
      'Default is offline design only, with no key read and no HTTP.\n'
      'Real execution requires explicit authorization and --execute; at most four HTTP attempts.',
    );
    return;
  }
  if (!args.contains('--execute')) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(contextFoldProbeDesign()),
    );
    return;
  }
  IOClient? client;
  try {
    final at = args.indexOf('--out');
    if (at >= 0 && at + 1 >= args.length) {
      throw ArgumentError('Missing output directory');
    }
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final output = Directory(
      at < 0
          ? 'E:/AII-3D/worktree-preserved/context-fold-probe-deepseek-flash-$stamp'
          : args[at + 1],
    );
    if (output.existsSync() && output.listSync().isNotEmpty) {
      throw StateError('Evidence directory is not empty');
    }
    final key = await readEvaluationApiKey(Platform.environment);
    final security = SecurityContext(withTrustedRoots: true);
    final certificate = Platform.environment['SSL_CERT_FILE'];
    if (certificate != null && certificate.isNotEmpty) {
      security.setTrustedCertificates(certificate);
    }
    client = IOClient(HttpClient(context: security));
    final report = await ContextFoldProbe(client: client, apiKey: key).run();
    await output.create(recursive: true);
    await File(
      '${output.path}/probe.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    await File('${output.path}/README.md').writeAsString(
      '# Completed-turn fold compatibility probe\n\n'
      'Status: ${report['status']}\n\nHTTP attempts: ${report['httpAttempts']}/4; '
      'mustStop: ${report['mustStop']}; model labels consistent: ${report['allModelLabelsConsistent']}.\n\n'
      'The first turn uses actual model tool calls. Its reasoning is replayed only while that '
      'turn is active; the whole completed turn is then replaced by a deterministic user summary. '
      'See probe.json for public transcript, usage, latency, bytes and hashes. '
      'Headers, credentials, error bodies and reasoning text are excluded.\n',
    );
    stdout.writeln(
      'Probe ${report['status']}; HTTP attempts=${report['httpAttempts']}/4; mustStop=${report['mustStop']}.',
    );
    if (report['status'] != 'passed_http_compatibility') exitCode = 2;
  } on Object catch (error) {
    stderr.writeln(
      'Context fold probe stopped: ${error.runtimeType}. No automatic retry.',
    );
    exitCode = 2;
  } finally {
    client?.close();
  }
}
