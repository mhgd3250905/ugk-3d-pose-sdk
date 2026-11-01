import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

const _config = LlmConfig(
  baseUrl: 'https://span-test.invalid/v1',
  model: 'span-test',
  maxRetries: 1,
  headers: {'X-Private-Test': 'trace-header-private'},
);
const _ids = ['h-sumo-pry', 'n-squat-shift', 's-butterfly'];
const _planInput = '在家有瑜伽垫，5分钟练大腿内侧。trace-request-private';

Map<String, Object?> _tool(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments)).toJson();

Map<String, Object?> _response({
  String content = '收到。trace-output-private',
  String? reasoning,
  List<Map<String, Object?>> tools = const [],
}) => {
  'model': 'span-test',
  'choices': [
    {
      'message': {
        'role': 'assistant',
        'content': tools.isEmpty ? content : '',
        'reasoning_content': ?reasoning,
        if (tools.isNotEmpty) 'tool_calls': tools,
      },
      'finish_reason': tools.isEmpty ? 'stop' : 'tool_calls',
    },
  ],
  'usage': {'prompt_tokens': 20, 'completion_tokens': 10, 'total_tokens': 30},
};

http.Response _jsonResponse(Map<String, Object?> body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Map<String, Object?> _user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};

CoachAgent _agent(
  http.Client transport, {
  CoachAgentSpanObserver? onSpan,
  int maxSteps = 1,
  ContextBudgetConfig contextBudgetConfig = const ContextBudgetConfig(),
}) {
  final client = OpenAiCompatibleClient(
    config: _config,
    auth: ApiKeyAuth('trace-auth-private'),
    httpClient: transport,
    sleep: (_) async {},
  );
  final agent = CoachAgent(
    client: client,
    catalog: loadCatalog,
    profile: loadProfile('hiplab'),
    onSpan: onSpan,
    enableUserMemory: false,
    maxSteps: maxSteps,
    maxRequestRetries: 0,
    contextBudgetConfig: contextBudgetConfig,
  );
  addTearDown(agent.dispose);
  addTearDown(transport.close);
  return agent;
}

void _expectContentFree(List<CoachAgentSpan> spans) {
  final encoded = jsonEncode([for (final span in spans) span.toJson()]);
  for (final text in [
    'trace-auth-private',
    'trace-header-private',
    'trace-request-private',
    'trace-output-private',
    'trace-title-private',
    'trace-server-private',
    'trace-seed-reasoning-private',
  ]) {
    expect(encoded, isNot(contains(text)));
  }
  const forbiddenKeys = {
    'body',
    'headers',
    'messages',
    'content',
    'arguments',
    'reasoning',
    'requestBody',
    'requestHeaders',
    'responseBody',
  };
  for (final span in spans) {
    expect(span.attributes.keys.toSet().intersection(forbiddenKeys), isEmpty);
    expect(span.elapsedMicros, greaterThanOrEqualTo(0));
  }
}

/// Keeps the response body open after HTTP headers and all JSON bytes arrive.
class _ControlledBodyClient extends http.BaseClient {
  final sent = Completer<void>();
  final body = StreamController<List<int>>();
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    await request.finalize().drain<void>();
    sent.complete();
    return http.StreamedResponse(body.stream, 200, request: request);
  }
}

class _PlanScript {
  final catalog = loadCatalog();
  final requests = <Map<String, Object?>>[];
  final toolCalls = <Map<String, Object?>>[];

  List<Map<String, Object?>> _batch(List<Map<String, Object?>> calls) {
    toolCalls.addAll(calls);
    return calls;
  }

  Future<http.Response> respond(http.Request request) async {
    final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
    requests.add(body);
    final messages = (body['messages']! as List).cast<Map<String, Object?>>();
    Map<String, Object?> receipt(String id) =>
        jsonDecode(
              messages.singleWhere((m) => m['tool_call_id'] == id)['content']
                  as String,
            )
            as Map<String, Object?>;
    final tools = switch (requests.length) {
      1 => [
        _tool('start', 'start_task', {'type': 'plan'}),
        _tool('understand', 'check', {'node': 'understand'}),
        _tool('params', 'set_params', {
          'fields': {
            'scene': _user('home', '在家'),
            'equipment': _user(['equip.mat'], '瑜伽垫'),
            'goal': _user(['body.inner_thigh'], '大腿内侧'),
            'minutes': _user(5, '5分钟'),
          },
        }),
        _tool('parameters', 'check', {'node': 'parameters'}),
        for (var i = 0; i < _ids.length; i++)
          _tool('search-$i', 'search_actions', {
            'tags': <String>[],
            'keywords': catalog[_ids[i]]!.name.of('zh'),
          }),
      ],
      2 => [
        _tool('actions', 'check', {'node': 'actions', 'picks': _ids}),
        _tool('draft', 'draft_plan', {
          'plan_id': receipt('start')['plan_id'],
          'title': 'trace-title-private',
          'blocks': [
            {
              'kind': 'main',
              'items': [
                for (final id in _ids) {'id': id},
              ],
            },
          ],
        }),
        _tool('planning', 'check', {'node': 'planning'}),
      ],
      3 => [
        _tool('review', 'check_plan', {'plan_id': receipt('draft')['plan_id']}),
      ],
      4 => [
        _tool('deliver', 'show_plan', {
          'plan_id': receipt('draft')['plan_id'],
          'note': 'trace-output-private',
        }),
      ],
      _ => throw StateError('Unexpected HTTP attempt ${requests.length}'),
    };
    return _jsonResponse(_response(tools: _batch(tools)));
  }

  Map<String, Object?> diagnostics(CoachTurnResult result) => {
    'status': result.status.name,
    'errorType': result.error?.runtimeType.toString(),
    'http': requests.length,
    'tools': toolCalls.map((t) => t['id']).toList(),
    'receipts': [
      for (final request in requests)
        for (final raw in request['messages']! as List)
          if ((raw as Map)['role'] == 'tool')
            {'id': raw['tool_call_id'], 'content': raw['content']},
    ],
  };
}

Map<String, Object?> _stableOutcome(CoachTurnResult result) {
  final plan = result.plan?.plan.toJson();
  if (plan != null) plan['id'] = 'normalized';
  return {
    'status': result.status.name,
    'text': result.text,
    'steps': result.steps,
    'plan': plan,
    'errorType': result.error?.runtimeType.toString(),
    'records': [
      for (final record in result.records)
        {
          'outcome': record.outcome.name,
          'issueCodes': record.issueCodes,
          'httpAttempts': record.httpAttempts,
        },
    ],
  };
}

void main() {
  test(
    'onSpan observes every actual HTTP send including client retries',
    () async {
      final spans = <CoachAgentSpan>[];
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        return requests.length == 1
            ? http.Response('{"error":{"message":"trace-server-private"}}', 502)
            : _jsonResponse(_response());
      });
      final coach = _agent(transport, onSpan: spans.add);
      final result = await coach.send('你好。trace-request-private');

      expect(result.status, TurnStatus.ok);
      expect(result.steps, 1);
      expect(requests, hasLength(2));
      expect(result.records.single.httpAttempts, 2);
      expect(
        requests.first.headers['Authorization'],
        'Bearer trace-auth-private',
      );
      expect(requests.first.body, contains('trace-request-private'));
      final httpSpans = spans
          .where((s) => s.kind == CoachAgentSpanKind.http)
          .toList();
      expect(httpSpans, hasLength(requests.length));
      expect(httpSpans.map((s) => s.attributes['statusCode']), [502, 200]);
      expect(httpSpans.map((s) => s.ok), [false, true]);
      expect(httpSpans.first.reason, 'http_502');
      for (var i = 0; i < httpSpans.length; i++) {
        expect(httpSpans[i].turnId, result.turnId);
        expect(httpSpans[i].epoch, isNotNull);
        expect(
          httpSpans[i].attributes['requestBytes'],
          requests[i].bodyBytes.length,
        );
        expect(httpSpans[i].attributes['responseBytes'], greaterThan(0));
      }
      expect(httpSpans.map((s) => s.id).toSet(), hasLength(2));
      _expectContentFree(spans);
    },
  );

  test(
    'HTTP span finishes only after the complete response stream closes',
    () async {
      final spans = <CoachAgentSpan>[];
      final transport = _ControlledBodyClient();
      final coach = _agent(transport, onSpan: spans.add);
      final resultFuture = coach.send('你好。trace-request-private');
      final response = utf8.encode(jsonEncode(_response()));
      try {
        await transport.sent.future;
        expect(spans, isEmpty);
        final split = response.length ~/ 2;
        transport.body.add(response.sublist(0, split));
        await Future<void>.delayed(Duration.zero);
        expect(spans, isEmpty);
        transport.body.add(response.sublist(split));
        await Future<void>.delayed(Duration.zero);
        expect(
          spans,
          isEmpty,
          reason: 'Complete JSON is not stream completion',
        );
      } finally {
        await transport.body.close();
      }
      final result = await resultFuture;
      expect(result.status, TurnStatus.ok);
      expect(transport.sends, 1);
      final httpSpan = spans.single;
      expect(httpSpan.kind, CoachAgentSpanKind.http);
      expect(httpSpan.ok, isTrue);
      expect(httpSpan.attributes['responseBytes'], response.length);
      _expectContentFree(spans);
    },
  );

  test(
    'fitting and draft parent retain current epoch after real context folding',
    () async {
      final spans = <CoachAgentSpan>[];
      final script = _PlanScript();
      var seedSent = false;
      final coach = _agent(
        MockClient((request) async {
          if (!seedSent) {
            seedSent = true;
            return _jsonResponse(
              _response(
                reasoning: 'trace-seed-reasoning-private${'x' * 20000}',
              ),
            );
          }
          return script.respond(request);
        }),
        onSpan: spans.add,
        maxSteps: 4,
        contextBudgetConfig: const ContextBudgetConfig(
          softOffBytes: 15000,
          softOnBytes: 15000,
          hardBytes: 65536,
        ),
      );
      final seed = await coach.send('你好。trace-request-private');
      expect(seed.status, TurnStatus.ok);
      final initialEpoch = coach.contextRequestDiagnostics.single.epoch;
      final result = await coach.send(_planInput);

      expect(
        result.plan,
        isNotNull,
        reason: jsonEncode(script.diagnostics(result)),
      );
      expect(result.status, TurnStatus.ok);
      expect(result.steps, 4);
      expect(script.requests, hasLength(4));
      expect(
        coach.contextRequestDiagnostics.any((d) => d.completedTurnsFolded > 0),
        isTrue,
      );
      expect(
        coach.contextRequestDiagnostics.last.epoch,
        greaterThan(initialEpoch),
      );
      expect(
        coach.contextRequestDiagnostics.every(
          (d) => d.measurement == 'OpenAiCompatibleClient.buildBody-exact',
        ),
        isTrue,
      );
      final tools = spans
          .where((s) => s.kind == CoachAgentSpanKind.tool)
          .toList();
      expect(
        tools.map((s) => s.toolCallId),
        script.toolCalls.map((c) => c['id']),
      );
      expect(tools.every((s) => s.ok), isTrue);
      for (final tool in tools) {
        expect(tool.turnId, result.turnId);
        expect(tool.epoch, isNotNull);
        expect(tool.attributes['responseBytes'], greaterThan(0));
        expect(tool.attributes['deferred'], isFalse);
      }
      final draft = tools.singleWhere((s) => s.toolCallId == 'draft');
      final fit = spans.singleWhere((s) => s.kind == CoachAgentSpanKind.fit);
      expect(fit.name, 'plan.fit');
      expect(fit.ok, isTrue);
      expect(fit.parentId, draft.id);
      expect(fit.toolCallId, 'draft');
      expect(fit.taskId, 'plan');
      expect(fit.epoch, draft.epoch);
      expect(fit.epoch, greaterThan(initialEpoch));
      expect(fit.turnId, result.turnId);
      expect(fit.attributes['targetSeconds'], 300);
      expect(fit.attributes['doseAdjustments'], isA<int>());
      expect(fit.startedMicros, greaterThanOrEqualTo(draft.startedMicros));
      expect(
        fit.startedMicros + fit.elapsedMicros,
        lessThanOrEqualTo(draft.startedMicros + draft.elapsedMicros),
      );
      expect(spans.indexOf(fit), lessThan(spans.indexOf(draft)));
      expect(
        spans.where(
          (s) => s.kind == CoachAgentSpanKind.http && s.turnId == result.turnId,
        ),
        hasLength(4),
      );
      final draftHttp = spans.lastWhere(
        (s) =>
            s.kind == CoachAgentSpanKind.http &&
            s.startedMicros < draft.startedMicros,
      );
      expect(fit.epoch, draftHttp.epoch);
      _expectContentFree(spans);
    },
  );

  test(
    'null and throwing observers preserve delivery and step budgets',
    () async {
      final outcomes = <Map<String, Object?>>[];
      final counts = <int>[];
      final observed = <CoachAgentSpan>[];
      final thrown = <CoachAgentSpan>[];
      final observers = <CoachAgentSpanObserver?>[
        null,
        observed.add,
        (span) {
          thrown.add(span);
          throw StateError('observer failure');
        },
      ];
      for (final observer in observers) {
        final script = _PlanScript();
        final coach = _agent(
          MockClient(script.respond),
          onSpan: observer,
          maxSteps: 4,
        );
        final result = await coach.send(_planInput);
        expect(
          result.plan,
          isNotNull,
          reason: jsonEncode(script.diagnostics(result)),
        );
        outcomes.add(_stableOutcome(result));
        counts.add(script.requests.length);
      }
      expect(outcomes[1], outcomes[0]);
      expect(outcomes[2], outcomes[0]);
      expect(counts, [4, 4, 4]);
      expect(
        observed.map((s) => s.kind).toSet(),
        containsAll([
          CoachAgentSpanKind.http,
          CoachAgentSpanKind.tool,
          CoachAgentSpanKind.fit,
        ]),
      );
      expect(
        thrown.map((s) => (s.kind, s.name, s.ok)),
        observed.map((s) => (s.kind, s.name, s.ok)),
      );
      _expectContentFree(observed);
      _expectContentFree(thrown);
    },
  );

  test(
    'observer failures cannot add attempts after HTTP retry exhaustion',
    () async {
      final outcomes = <Map<String, Object?>>[];
      final counts = <int>[];
      final thrown = <CoachAgentSpan>[];
      final observers = <CoachAgentSpanObserver?>[
        null,
        (span) {
          thrown.add(span);
          throw StateError('observer failure');
        },
      ];
      for (final observer in observers) {
        var attempts = 0;
        final coach = _agent(
          MockClient((_) async {
            attempts++;
            return http.Response(
              '{"error":{"message":"trace-server-private"}}',
              502,
            );
          }),
          onSpan: observer,
        );
        final result = await coach.send('你好。trace-request-private');
        outcomes.add(_stableOutcome(result));
        counts.add(attempts);
        expect(result.plan, isNull);
        expect(
          result.error,
          isA<AgentRequestFailed>()
              .having((error) => error.attempts, 'logical attempts', 1)
              .having((error) => error.cause, 'cause', isA<LlmException>()),
        );
        expect(result.records.single.httpAttempts, 2);
      }
      expect(counts, [2, 2]);
      expect(outcomes[1], outcomes[0]);
      expect(thrown, hasLength(2));
      expect(
        thrown.every((s) => s.kind == CoachAgentSpanKind.http && !s.ok),
        isTrue,
      );
      _expectContentFree(thrown);
    },
  );
}
