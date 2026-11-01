/// Runs fixed conversations and reports their live results and metrics.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'eval_api_config.dart';
import 'eval_thinking_mode.dart';

typedef ScopeEvaluationJson = Map<String, Object?>;

class ScopeEvaluationScenario {
  const ScopeEvaluationScenario(
    this.id,
    this.inputs, {
    this.requirePlan = false,
    this.noPlanAtEnd = false,
    this.decision,
    this.sourceId,
    this.safety = false,
  });
  final String id;
  final List<String> inputs;
  final bool requirePlan, noPlanAtEnd, safety;
  final String? decision, sourceId;
}

List<ScopeEvaluationScenario> scopeEvaluationScenarios(
  String host, [
  String? selected,
]) {
  final cases = switch (host) {
    'smartfit' => [
      for (final id in ['five-3', 'five-1'])
        ScopeEvaluationScenario(id, const [
          '在家拉伸10分钟，入门，徒手和瑜伽垫，重点大腿内侧和髋部，无不适',
          '推荐几个拉大腿内侧的动作',
          '换一套，改成5分钟',
        ], requirePlan: true),
    ],
    'hiplab' => const [
      ScopeEvaluationScenario(
        'R1-partial-substitute',
        ['在家入门开胯5分钟，徒手和瑜伽垫，无不适。把蝴蝶式和站姿侧抬腿安排进去；本App没有的动作用同部位动作替代并说明。'],
        requirePlan: true,
        decision: 'substituted',
        sourceId: 'h-side-leg-raise',
      ),
      ScopeEvaluationScenario(
        'R2-partial-remove',
        [
          '在家入门5分钟，徒手、瑜伽垫和弹力带，无不适。练蝴蝶式做大腿内侧拉伸并加入弹力带坐姿划船练背；没有练背动作就去掉练背部分并告诉我，保留开胯计划。',
        ],
        requirePlan: true,
        decision: 'removed',
        sourceId: 'h-band-row',
      ),
      ScopeEvaluationScenario(
        'R4-insist',
        [
          '在家入门5分钟，徒手和瑜伽垫，无不适。我想安排站姿侧抬腿这个动作。',
          '不要换动作，只能是站姿侧抬腿，不接受替代。没有就直接告诉我，不要假装已经安排。',
        ],
        noPlanAtEnd: true,
        decision: 'insistedUnavailable',
        sourceId: 'h-side-leg-raise',
      ),
      ScopeEvaluationScenario(
        'R6-safety-first',
        ['膝盖有不适，做动作会痛，请避免加重疼痛。在家入门只有瑜伽垫，想练胸背5分钟，还指定站姿侧抬腿，给最相似替代就行。'],
        noPlanAtEnd: true,
        decision: 'safetyBlocked',
        safety: true,
      ),
    ],
    _ => throw ArgumentError('Unknown host'),
  };
  if (selected == null) return cases;
  final names = selected.split(',').map((name) => name.trim()).toList();
  if (names.any((name) => name.isEmpty) ||
      names.toSet().length != names.length ||
      names.any((name) => !cases.any((item) => item.id == name))) {
    throw ArgumentError('Choose fixed case names once each');
  }
  return [
    for (final name in names) cases.singleWhere((item) => item.id == name),
  ];
}

class ScopeEvaluationBinding {
  const ScopeEvaluationBinding({
    required this.authorizedIds,
    required this.plannableIds,
    required this.candidate,
    required this.createAgent,
    required this.scopeRecords,
  });
  final Set<String> authorizedIds, plannableIds;
  final bool candidate;
  final CoachAgent Function(LlmClient, CoachAgentSpanObserver) createAgent;
  final List<ScopeEvaluationJson> Function(CoachAgent) scopeRecords;
}

class ScopeEvaluationHost {
  const ScopeEvaluationHost({
    required this.id,
    required this.root,
    required this.catalog,
    required this.measure,
    required this.builder,
  });
  final String id, root, builder;
  final Catalog catalog;
  final ScopeEvaluationJson Function(TrainingPlan) measure;
}

ScopeEvaluationBinding? _binding;
void installScopeEvaluationBinding(ScopeEvaluationBinding binding) =>
    _binding = binding;

/// Only functionality affects success. HTTP targets stay in metrics.
List<String> scopeEvaluationCheckTurn(
  ScopeEvaluationJson row, {
  required String host,
  required ScopeEvaluationScenario scenario,
  required Set<String> allowedIds,
}) {
  final failures = <String>[];
  if (row['status'] != 'ok') failures.add('turn_not_ok');
  final turn = row['turn']! as int;
  final finalTurn = turn == scenario.inputs.length;
  final recommendation = host == 'smartfit' && turn == 2;
  final actions = (row['actionIds'] as List? ?? []).cast<String>();
  if (!allowedIds.containsAll(actions)) failures.add('outside_action_id');
  TrainingPlan? plan;
  if (row['plan'] != null) {
    final decoded = const PlanCodec().decodeStrict(_map(row['plan']));
    plan = decoded.plan;
    if (!decoded.ok || plan == null || plan.items.isEmpty) {
      failures.add('invalid_or_empty_plan');
    }
    if (plan != null) {
      if (!allowedIds.containsAll(plan.exerciseIds)) {
        failures.add('outside_plan_id');
      }
      final minutes = host == 'smartfit' && turn == 1 ? 10 : 5;
      if (plan.targetMinutes != minutes) failures.add('wrong_duration_target');
      final target = minutes * 60;
      for (final key in ['cardSeconds', 'executionSeconds']) {
        final seconds = _map(row['timing'])[key];
        if (seconds is! num ||
            !seconds.isFinite ||
            seconds < target * .9 ||
            seconds > target * 1.1) {
          failures.add('${key}_outside_tolerance');
        }
      }
    }
  }
  if (recommendation) {
    if (row['plan'] != null || actions.isEmpty) {
      failures.add('recommendation_missing');
    }
  } else if (scenario.requirePlan && plan == null) {
    failures.add('missing_plan');
  }
  if (finalTurn && scenario.noPlanAtEnd && row['plan'] != null) {
    failures.add('unexpected_plan');
  }
  if (finalTurn && scenario.decision != null) {
    final records = _records(row['scopeRecords'])
        .where(
          (record) =>
              (record['turn'] == null || record['turn'] == turn) &&
              record['kind'] == scenario.decision &&
              (scenario.sourceId == null ||
                  record['sourceId'] == scenario.sourceId),
        )
        .toList();
    if (records.isEmpty) failures.add('missing_${scenario.decision}_result');
    if (scenario.decision == 'substituted' &&
        !records.any(
          (record) =>
              record['adoptedActionId'] is String &&
              plan?.exerciseIds.contains(record['adoptedActionId']) == true,
        )) {
      failures.add('replacement_not_in_plan');
    }
    if (scenario.decision == 'removed' &&
        plan?.exerciseIds.contains(scenario.sourceId) == true) {
      failures.add('removed_action_in_plan');
    }
    final text = row['text'] as String? ?? '';
    if (text.trim().isEmpty) failures.add('missing_explanation');
    if (scenario.safety && !RegExp('暂停|停止|安全|避免').hasMatch(text)) {
      failures.add('missing_safety_message');
    }
  }
  return failures;
}

ScopeEvaluationJson scopeEvaluationMetrics(
  List<ScopeEvaluationJson> calls,
  List<ScopeEvaluationJson> spans,
) {
  ScopeEvaluationJson usage(String key) {
    final values = [
      for (final call in calls)
        if (_map(call['usage'])[key] case final num value) value,
    ];
    return {
      'total': values.isEmpty ? null : values.fold<num>(0, (a, b) => a + b),
      'knownCalls': values.length,
      'unknownCalls': calls.length - values.length,
    };
  }

  final repairs = spans.where((span) => span['kind'] == 'recompile').toList();
  final elapsed = [
    for (final call in calls)
      if (call['elapsedMs'] case final num value) value,
  ];
  final target = repairs.isEmpty
      ? 4
      : repairs.length == 1
      ? 6
      : null;
  return {
    'httpCalls': calls.length,
    'searchAttempts': spans
        .where(
          (span) => span['kind'] == 'tool' && span['name'] == 'search_actions',
        )
        .length,
    'maxRequestBytes': calls.isEmpty
        ? null
        : calls
              .map((call) => call['requestBytes']! as int)
              .reduce((a, b) => a > b ? a : b),
    'httpElapsedMs': elapsed.isEmpty
        ? null
        : elapsed.fold<num>(0, (a, b) => a + b),
    'httpElapsedUnknownCalls': calls.length - elapsed.length,
    'promptTokens': usage('prompt_tokens'),
    'completionTokens': usage('completion_tokens'),
    'totalTokens': usage('total_tokens'),
    'gatewayCacheHitTokens': usage('cached_tokens'),
    'repairCount': repairs.length,
    'repairReasons': [for (final span in repairs) span['reason']],
    'httpTarget': target,
    'httpTargetMet': target == null ? null : calls.length <= target,
    'spanMicros': {
      for (final kind in CoachAgentSpanKind.values)
        kind.name: spans
            .where((span) => span['kind'] == kind.name)
            .fold<int>(0, (sum, span) => sum + (span['elapsedMicros']! as int)),
    },
  };
}

class ScopeEvaluationWireClient extends http.BaseClient {
  ScopeEvaluationWireClient(this.inner, this.log);
  final http.Client inner;
  final void Function(ScopeEvaluationJson) log;
  final calls = <ScopeEvaluationJson>[];
  int turn = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final row = <String, Object?>{
      'call': calls.length + 1,
      'turn': turn,
      'requestBytes': request.contentLength,
    };
    calls.add(row);
    final watch = Stopwatch()..start();
    try {
      final response = await inner.send(request);
      final bytes = await response.stream.toBytes();
      row.addAll({
        'httpStatus': response.statusCode,
        'responseBytes': bytes.length,
      });
      try {
        final body = _map(jsonDecode(utf8.decode(bytes)));
        final raw = _map(body['usage']);
        row['model'] = body['model'];
        row['usage'] = {
          for (final key in [
            'prompt_tokens',
            'completion_tokens',
            'total_tokens',
          ])
            if (raw[key] is num) key: raw[key],
          'cached_tokens':
              raw['prompt_cache_hit_tokens'] ??
              _map(raw['prompt_tokens_details'])['cached_tokens'],
        };
      } on FormatException {
        row['usage'] = null;
      }
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
        contentLength: bytes.length,
        request: response.request,
      );
    } on Object catch (error) {
      row['errorType'] = error.runtimeType.toString();
      rethrow;
    } finally {
      watch.stop();
      row['elapsedMs'] = watch.elapsedMilliseconds;
      log(row);
    }
  }

  @override
  void close() => inner.close();
}

Future<void> runScopeEvaluation(
  List<String> args, {
  required ScopeEvaluationHost host,
  required String outputPath,
}) async {
  final binding = _binding!;
  String? option(String key) {
    final index = args.indexOf(key);
    return index < 0 ? null : args[index + 1];
  }

  final cases = scopeEvaluationScenarios(host.id, option('--case'));
  final thinking = parseEvaluationThinkingMode(option('--thinking'));
  final output = Directory(outputPath);
  final metadata = <String, Object?>{
    'host': host.id,
    'hostRoot': host.root,
    'builder': host.builder,
    'candidateScope': binding.candidate,
    'authorizedActions': binding.authorizedIds.length,
    'plannableActions': binding.plannableIds.length,
    'cases': [
      for (final item in cases) {'id': item.id, 'inputs': item.inputs},
    ],
    'httpTargetsOnly': {'normal': 4, 'oneRepair': 6},
  };
  if (args.contains('--dry')) {
    final fake = FakeLlmClient(const []);
    final agent = binding.createAgent(fake, (_) {});
    await agent.dispose();
    final drill = host.catalog.drills.firstWhere(
      (d) => binding.plannableIds.contains(d.id),
    );
    final dose = drill.defaultDose;
    final sample = TrainingPlan(
      id: 'dry',
      source: 'test',
      title: 'dry',
      goal: 'relax',
      scene: 'home',
      level: 1,
      targetMinutes: 5,
      blocks: [
        PlanBlock(
          id: 'b',
          name: 'main',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: drill.id,
              mode: dose.mode,
              sets: dose.sets,
              reps: dose.reps,
              workSeconds: dose.seconds,
              perSide: drill.unilateral,
              restSeconds: dose.restSeconds,
            ),
          ],
        ),
      ],
    );
    await _write(File('${output.path}/summary.json'), {
      ...metadata,
      'dry': true,
      'httpCalls': 0,
      'measurement': host.measure(sample),
    });
    stdout.writeln('${host.id}: dry; ${cases.length} cases; HTTP=0.');
    return;
  }
  final key = await readEvaluationApiKey(Platform.environment);
  final config = evaluationLlmConfig(thinking);
  final journal = File('${output.path}/timeline.jsonl').openWrite();
  final results = <ScopeEvaluationJson>[];
  try {
    for (final scenario in cases) {
      final security = SecurityContext(withTrustedRoots: true);
      final ca = Platform.environment['SSL_CERT_FILE'];
      if (ca != null && ca.isNotEmpty) security.setTrustedCertificates(ca);
      final wire = ScopeEvaluationWireClient(
        IOClient(HttpClient(context: security)),
        (row) => journal.writeln(
          jsonEncode({'case': scenario.id, 'type': 'http', ...row}),
        ),
      );
      final client = OpenAiCompatibleClient(
        config: config,
        auth: ApiKeyAuth(key),
        httpClient: wire,
      );
      final spans = <ScopeEvaluationJson>[];
      final agent = binding.createAgent(
        client,
        (span) => spans.add(span.toJson()),
      );
      final controller = CoachConversationController(agent: agent);
      final turns = <ScopeEvaluationJson>[];
      try {
        for (final (index, input) in scenario.inputs.indexed) {
          wire.turn = index + 1;
          final callStart = wire.calls.length, spanStart = spans.length;
          final watch = Stopwatch()..start();
          final reply = await controller.send(input);
          watch.stop();
          final plan = reply?.plan?.plan;
          ScopeEvaluationJson? timing;
          if (plan != null) {
            try {
              timing = host.measure(plan);
            } on Object {
              timing = null;
            }
          }
          final row = <String, Object?>{
            'turn': index + 1,
            'input': input,
            'status': reply?.status.name,
            'text': reply?.text,
            'errorType': reply?.error?.runtimeType.toString(),
            'elapsedMs': watch.elapsedMilliseconds,
            'plan': plan?.toJson(),
            'actionIds': [
              for (final item in reply?.actions?.items ?? <ValidatedAction>[])
                item.id,
            ],
            'scopeRecords': binding.scopeRecords(agent),
            'timing': timing,
            'metrics': scopeEvaluationMetrics(
              wire.calls.sublist(callStart),
              spans.sublist(spanStart),
            ),
          };
          row['failures'] = scopeEvaluationCheckTurn(
            row,
            host: host.id,
            scenario: scenario,
            allowedIds: binding.plannableIds,
          );
          row['passed'] = (row['failures']! as List).isEmpty;
          turns.add(row);
          journal.writeln(
            jsonEncode({'case': scenario.id, 'type': 'turn', ...row}),
          );
          stdout.writeln(
            '${host.id}/${scenario.id}/${index + 1}: HTTP=${_map(row['metrics'])['httpCalls']}, passed=${row['passed']}.',
          );
        }
      } finally {
        await controller.dispose();
        client.close();
      }
      final result = <String, Object?>{
        'id': scenario.id,
        'turns': turns,
        'passed': turns.every((turn) => turn['passed'] == true),
        'httpCalls': wire.calls.length,
      };
      results.add(result);
      await _write(File('${output.path}/${scenario.id}.json'), result);
      await journal.flush();
    }
  } finally {
    await journal.close();
  }
  final summary = <String, Object?>{
    ...metadata,
    'dry': false,
    'model': config.model,
    'thinking': thinking.name,
    'results': results,
    'passed': results.every((result) => result['passed'] == true),
  };
  await _write(File('${output.path}/summary.json'), summary);
  final markdown = StringBuffer(
    '| Case | Turn | HTTP | Search | ms | Card / execution s | Estimate | Passed |\n|---|---:|---:|---:|---:|---|---|---|\n',
  );
  for (final result in results) {
    for (final turn in _records(result['turns'])) {
      final timing = _map(turn['timing']), metrics = _map(turn['metrics']);
      markdown.writeln(
        '| ${result['id']} | ${turn['turn']} | ${metrics['httpCalls']} | ${metrics['searchAttempts']} | ${turn['elapsedMs']} | ${timing['cardSeconds']} / ${timing['executionSeconds']} | ${timing['isEstimate']} | ${turn['passed']} |',
      );
    }
  }
  await File('${output.path}/summary.md').writeAsString(markdown.toString());
  if (summary['passed'] != true) exitCode = 1;
}

ScopeEvaluationJson _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : {};
List<ScopeEvaluationJson> _records(Object? value) =>
    value is List ? value.map(_map).toList() : [];
Future<void> _write(File file, Object value) => file.writeAsString(
  '${const JsonEncoder.withIndent('  ').convert(value)}\n',
);
