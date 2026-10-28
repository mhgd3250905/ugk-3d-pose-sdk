// Real, unseeded CoachAgent evaluation for the approved v2 R1-R6 cases.
// Additional user replies and the R4 click are explicitly simulated. They enter
// through the same public controller.send API; no tool result/task is injected.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'eval_reasoning_stats.dart';
import 'eval_thinking_mode.dart';
import 'eval_turn_budget.dart';

typedef Json = Map<String, Object?>;

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln('''
dart run tool/eval_coach_agent_v2.dart --dry [--thinking on|off] [--cases R1,R2] [--out DIR]
dart run tool/eval_coach_agent_v2.dart [--thinking on|off] [--cases R1,R2] [--out DIR]

Uses the existing UGK Worker route and an existing identity. Environment:
Fixed route: https://api.uuugk.win/v1 and deepseek-v4-flash-0731.
UGK_APP_KEY must be supplied through the environment; UGK_DEVICE_ID or
UGK_DEVICE_FILE must identify the existing authorized evaluation device.
No alternate bearer route, model or newly generated device is used.
SSL_CERT_FILE optionally adds a trusted CA. UGK_EVAL_GAP_SECONDS spaces cases.
Thinking defaults to on; on sends thinking.type=enabled, off sends disabled.
The configured generation budget is retained.
--dry checks fixtures only (modelCalls=0); it does not evaluate model quality.
Evidence excludes credentials, headers, endpoint URLs, system prompt text and
reasoning text. Public messages, tool calls/results, raw usage availability,
actual UTF-8 HTTP request bytes, replayed reasoning_content byte counts,
timing and task event snapshots are retained.
''');
    return;
  }
  try {
    await _main(args);
  } on Object catch (error) {
    // Configuration failures may contain private paths or endpoint details.
    stderr.writeln('V2 evaluation stopped: ${error.runtimeType}.');
    stderr.writeln('Check the authorized configuration and local evidence.');
    exitCode = 2;
  }
}

Future<void> _main(List<String> args) async {
  String? argument(String flag) {
    final at = args.indexOf(flag);
    if (at < 0) return null;
    if (at + 1 == args.length || args[at + 1].startsWith('--')) {
      throw ArgumentError('Missing argument');
    }
    return args[at + 1];
  }

  final thinkingMode = parseEvaluationThinkingMode(argument('--thinking'));
  const fixturePath = 'eval/cases/coach_agent_v2.json';
  final fixtureFile = File(fixturePath);
  final fixture = _map(jsonDecode(await fixtureFile.readAsString()));
  final allCases = _list(fixture['cases']).map(_map).toList();
  final ids = {for (final item in allCases) item['id']};
  if (fixture['schemaVersion'] != 1 ||
      ids.length != 6 ||
      !ids.containsAll(['R1', 'R2', 'R3', 'R4', 'R5', 'R6'])) {
    throw const FormatException('Expected the six approved v2 cases');
  }
  for (final item in allCases) {
    if (_list(item['messages']).isEmpty ||
        _list(item['messages']).any((value) => value is! String) ||
        item['simulatedClarificationReply'] is! String) {
      throw const FormatException('Invalid scenario input');
    }
  }
  final selected = argument('--cases')?.split(',').toSet();
  if (selected != null && !ids.containsAll(selected)) {
    throw ArgumentError('Unknown case');
  }
  final cases = allCases
      .where((item) => selected == null || selected.contains(item['id']))
      .toList();
  final output = Directory(
    argument('--out') ??
        'eval/results/coach-agent-v2/${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}',
  );
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError('Refusing to overwrite an existing evidence run');
  }
  await output.create(recursive: true);
  if (args.contains('--dry')) {
    await _writeJson(File('${output.path}/summary.json'), {
      'mode': 'fixture-validation-only',
      'thinkingMode': thinkingMode.name,
      'thinkingRequestType': thinkingMode.protocolType,
      'thinkingRequested': thinkingMode == EvaluationThinkingMode.on,
      'modelCalls': 0,
      'modelQualityPassed': null,
      'cases': cases.map((item) => item['id']).toList(),
      'fixtureSha256': sha256
          .convert(await fixtureFile.readAsBytes())
          .toString(),
      'transcripts': 'no samples',
      'nodeRecords': 'no samples',
      'p50Ms': null,
      'p90Ms': null,
    });
    stdout.writeln(
      'Fixture validation complete; thinking=${thinkingMode.name}; modelCalls=0.',
    );
    return;
  }

  final env = Platform.environment;
  final redactor = EvaluationRedactor([ToolPromptBuilder().canary]);
  final auth = await _auth(env, redactor);
  const requiredBaseUrl = 'https://api.uuugk.win/v1';
  const requiredModel = 'deepseek-v4-flash-0731';
  if ((env['UGK_BASE_URL'] != null && env['UGK_BASE_URL'] != requiredBaseUrl) ||
      (env['UGK_MODEL'] != null && env['UGK_MODEL'] != requiredModel)) {
    throw StateError('The approved Worker route and model must be retained');
  }
  final config = LlmConfig.ugkWorker.copyWith(
    baseUrl: requiredBaseUrl,
    model: requiredModel,
    maxRetries: 0,
    extraBody: {...LlmConfig.ugkWorker.extraBody, ...thinkingMode.extraBody},
  );
  redactor.secrets.add(config.baseUrl);
  final security = SecurityContext(withTrustedRoots: true);
  final certificate = env['SSL_CERT_FILE'];
  if (certificate != null && certificate.isNotEmpty) {
    security.setTrustedCertificates(certificate);
  }
  final metadataFile = File(
    argument('--catalog') ??
        'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
  );
  final metadataBytes = await metadataFile.readAsBytes();
  final metadata = PoseHubAppTestCatalog.fromBytes(metadataBytes);
  final semanticFile = File(
    '${metadataFile.parent.path}/${metadata.semanticCatalogFile.path}',
  );
  final semanticBytes = await semanticFile.readAsBytes();
  final catalog = PoseHubAppTestCatalog.fromBytes(
    metadataBytes,
    semanticCatalogBytes: semanticBytes,
  ).toAiCatalog();
  final profileName = fixture['profile'] as String;
  if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(profileName)) {
    throw const FormatException('Invalid profile name');
  }
  final profileFile = File('profiles/$profileName.json');
  final profile = CoachProfile.fromJson(
    jsonDecode(await profileFile.readAsString()),
  );
  final journal = File('${output.path}/timeline.jsonl').openWrite();
  void append(Json record) =>
      journal.writeln(jsonEncode(redactor.clean(record)));
  final results = <Json>[];
  final allWireCalls = <Json>[];
  final sourceBefore = await _sourceFingerprint();
  final startedAt = DateTime.now().toUtc();
  final totalWatch = Stopwatch()..start();
  try {
    for (final item in cases) {
      final id = item['id'] as String;
      stdout.writeln('Running $id through the real public SDK path.');
      final wire = EvaluationWireClient(
        IOClient(HttpClient(context: security)),
        redactor,
        (record) => append({'case': id, ...record}),
      );
      final client = OpenAiCompatibleClient(
        config: config,
        auth: auth,
        httpClient: wire,
      );
      final sourceAtStart = await _sourceFingerprint();
      Json result;
      try {
        result = await _runCase(
          item,
          client,
          wire,
          catalog,
          profile,
          thinkingMode,
          redactor,
          (record) => append({'case': id, ...record}),
        );
      } finally {
        client.close();
      }
      final unchanged = sourceAtStart == await _sourceFingerprint();
      result['sourceUnchangedDuringCase'] = unchanged;
      if (!unchanged) {
        _list(result['automatedFailures']).add('source changed during case');
        result['automatedChecksPassed'] = false;
      }
      result['sourceSha256'] = sourceAtStart;
      results.add(result);
      allWireCalls.addAll(wire.calls);
      await _writeJson(File('${output.path}/$id.json'), redactor.clean(result));
      await File(
        '${output.path}/$id-transcript.md',
      ).writeAsString(_transcript(result));
      await journal.flush();
      stdout.writeln(
        '$id: automatedChecksPassed=${result['automatedChecksPassed']}; '
        'modelCalls=${wire.calls.length}; '
        'manual model-quality review remains required.',
      );
      final gap = int.tryParse(env['UGK_EVAL_GAP_SECONDS'] ?? '') ?? 0;
      if (gap > 0 && item != cases.last) {
        await Future<void>.delayed(Duration(seconds: gap));
      }
    }
  } finally {
    totalWatch.stop();
    await journal.flush();
    await journal.close();
  }
  final sourceUnchanged = sourceBefore == await _sourceFingerprint();
  final summary = <String, Object?>{
    'schemaVersion': 1,
    'mode': 'real-unseeded-CoachAgent-public-controller',
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'elapsedMs': totalWatch.elapsedMilliseconds,
    'requestedModel': config.model,
    'endpointSha256': sha256.convert(utf8.encode(config.baseUrl)).toString(),
    'authType': auth.runtimeType.toString(),
    'thinkingRequested': thinkingMode == EvaluationThinkingMode.on,
    'thinkingMode': thinkingMode.name,
    'thinkingRequestType': thinkingMode.protocolType,
    'maxTokens': config.maxTokens,
    'httpClientRetries': config.maxRetries,
    'sourceSha256': sourceBefore,
    'sourceUnchangedDuringRun': sourceUnchanged,
    'fixtureSha256': sha256.convert(await fixtureFile.readAsBytes()).toString(),
    'catalogVersion': catalog.version,
    'catalogSha256': sha256.convert(metadataBytes).toString(),
    'semanticCatalogSha256': sha256.convert(semanticBytes).toString(),
    'profileSha256': sha256.convert(await profileFile.readAsBytes()).toString(),
    'agentOverrides': const <String, Object?>{},
    'simulatedUserReplies': true,
    'simulatedHostClick': cases.any((item) => item['hostAction'] != null),
    'modelCalls': allWireCalls.length,
    'callStatistics': _callStatistics(allWireCalls),
    'automatedChecksPassed':
        sourceUnchanged &&
        results.every((item) => item['automatedChecksPassed'] == true),
    'modelQualityPassed': null,
    'manualReviewRequired': true,
    'cases': results,
    'limitations': [
      'Each case is one fresh agent with an empty, unseeded session and memory store.',
      'Supplementary user facts and the R4 click are scripted simulations, not model outputs.',
      'User replies enter only after real results, using the same public controller.send path.',
      'No task, skill, catalog row, model response or tool result is injected into agent history.',
      'Thinking mode is explicit and protocol replay is untouched; reasoning text is not evidence prose.',
      'Usage fields absent from upstream are null/unknown, never inferred as zero.',
      'Task-event intervals are observed wall-clock intervals, not isolated tool execution timings.',
      'The existing Worker may return 502 around 40 seconds; no Worker or alternate route is modified.',
      'Non-JSON response text is excluded because truncated payloads may contain private reasoning; byte count and SHA-256 remain recorded.',
      'Single samples do not establish reliability, native device acceptance or latency guarantees.',
    ],
  };
  await _writeJson(
    File('${output.path}/summary.json'),
    redactor.clean(summary),
  );
  await File('${output.path}/evaluation.md').writeAsString(
    _summaryTable(results, _callStatistics(allWireCalls)) +
        results.map(_transcript).join('\n\n---\n\n'),
  );
  await _writeJson(
    File('${output.path}/evaluation.json'),
    redactor.clean(summary),
  );
  stdout.writeln('Evidence: ${output.absolute.path}');
  if (summary['automatedChecksPassed'] != true) exitCode = 1;
}

Future<Json> _runCase(
  Json scenario,
  OpenAiCompatibleClient client,
  EvaluationWireClient wire,
  Catalog catalog,
  CoachProfile profile,
  EvaluationThinkingMode thinkingMode,
  EvaluationRedactor redactor,
  void Function(Json) append,
) async {
  // Do not seed plans, task nodes, remembered facts, history or model replies.
  // All production technical limits remain the CoachAgent defaults.
  final agent = CoachAgent(
    client: client,
    catalog: () => catalog,
    profile: profile,
  );
  final controller = CoachConversationController(agent: agent);
  wire.onModelMismatch = controller.cancel;
  final watch = Stopwatch()..start();
  final turns = <Json>[];
  final events = <Json>[];
  final failures = <Object?>[];
  var currentTurn = 0;
  var previousTaskEventMs = 0;
  wire.caseElapsedMs = () => watch.elapsedMilliseconds;
  final subscription = agent.events.listen((event) {
    final at = watch.elapsedMilliseconds;
    final task = event.task;
    final record = <String, Object?>{
      'recordType': 'agent-event',
      'at': DateTime.now().toUtc().toIso8601String(),
      'caseElapsedMs': at,
      'turn': currentTurn,
      'turnId': event.turnId,
      'kind': event.kind.name,
      'step': event.step,
      'path': event.path,
      'status': event.status?.name,
      'question': event.question?.toJson(),
      'attempt': event.attempt,
      'maxAttempts': event.maxAttempts,
      'reason': event.reason?.name,
      'delayMs': event.delay?.inMilliseconds,
      'task': task?.toJson(),
      'node': event.node?.toJson(),
      if (task != null)
        'intervalSincePreviousTaskEventMs': at - previousTaskEventMs,
    };
    if (task != null) previousTaskEventMs = at;
    final clean = _map(redactor.clean(record));
    wire.agentStep = event.step;
    if (task != null) wire.taskAtRequest = _map(redactor.clean(task.toJson()));
    events.add(clean);
    append(clean);
  });
  CoachTurnResult? last;
  Future<CoachTurnResult?> send(String text, String origin) async {
    currentTurn++;
    wire.turn = currentTurn;
    final before = wire.calls.length;
    final turnWatch = Stopwatch()..start();
    final user = <String, Object?>{
      'recordType': 'user-input',
      'turn': currentTurn,
      'thinkingMode': thinkingMode.name,
      'origin': origin,
      'simulated': origin != 'approved-original',
      'text': text,
      'at': DateTime.now().toUtc().toIso8601String(),
      'caseElapsedMs': watch.elapsedMilliseconds,
    };
    append(user);
    final result = await controller.send(text);
    turnWatch.stop();
    final plan = result?.plan?.plan;
    final turn = <String, Object?>{
      'turn': currentTurn,
      'thinkingMode': thinkingMode.name,
      'origin': origin,
      'simulated': origin != 'approved-original',
      'user': text,
      'elapsedMs': turnWatch.elapsedMilliseconds,
      'caseElapsedMs': watch.elapsedMilliseconds,
      'status': result?.status.name,
      'assistant': result?.text,
      'question': result?.question?.toJson(),
      'plan': plan?.toJson(),
      'planState': controller.state.messages.lastOrNull?.planState?.toJson(),
      'actions': [
        for (final item in result?.actions?.items ?? <ValidatedAction>[])
          {
            'id': item.drill.id,
            'name': item.drill.name.toJson(),
            'note': item.note,
          },
      ],
      'actionFacts': [
        for (final id in {
          ...?plan?.exerciseIds,
          for (final item in result?.actions?.items ?? <ValidatedAction>[])
            item.drill.id,
        })
          if (catalog[id] case final drill?)
            {
              'id': id,
              'name': drill.name.toJson(),
              'category': drill.category,
              'muscleGroups': drill.muscleGroups,
              'equipment': drill.equipment,
              'scenes': drill.scenes,
              'cautions': drill.cautions,
            },
      ],
      if (plan != null)
        'estimatedPlanSeconds': const PlanDuration().estimateSeconds(
          plan,
          catalog,
        ),
      'steps': result?.steps,
      'reads': result?.reads,
      'issues': result?.issues.map((issue) => issue.toJson()).toList(),
      'warnings': result?.warnings.map((issue) => issue.toJson()).toList(),
      'error': _error(result?.error, redactor),
      'calls': wire.calls.sublist(before),
      'callStatistics': _callStatistics(wire.calls.sublist(before)),
      'params': agent.sessionState.params.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'legacyGoal': plan?.goal,
      'task': agent.sessionState.task?.toJson(),
      'activityTaskType': evaluationTurnTaskType(
        turn: currentTurn,
        events: events,
        calls: wire.calls.sublist(before),
      ),
      'agentHistoryAfterTurn': [
        for (final message in agent.history)
          publicEvaluationMessage(_map(message.toJson()), redactor),
      ],
    };
    turns.add(_map(redactor.clean(turn)));
    append({'recordType': 'turn-result', ...turn});
    if (result == null || result.status != TurnStatus.ok) {
      failures.add('turn $currentTurn did not finish with status ok');
    }
    if (plan != null) {
      final estimate = const PlanDuration().estimateSeconds(plan, catalog) / 60;
      if (plan.targetMinutes <= 0 ||
          (estimate - plan.targetMinutes).abs() / plan.targetMinutes > .10) {
        failures.add(
          'turn $currentTurn plan duration differs from its target by over 10%',
        );
      }
    }
    last = result;
    return result;
  }

  Future<void> answerQuestions() async {
    // No question-count rule is added. The real agent's technical limits own
    // termination. Every repeated simulated answer is separately recorded.
    while (last?.status == TurnStatus.ok && last?.question != null) {
      await send(
        scenario['simulatedClarificationReply'] as String,
        'simulated-clarification-reply',
      );
    }
  }

  try {
    for (final message in _list(scenario['messages']).cast<String>()) {
      await send(message, 'approved-original');
      await answerQuestions();
      if (last?.status != TurnStatus.ok) break;
    }
    if (last?.status == TurnStatus.ok && scenario['hostAction'] != null) {
      if (last?.actions == null) {
        failures.add(
          'R4 did not first deliver real validated action cards; host click not fabricated',
        );
      } else {
        final action = _map(scenario['hostAction']);
        append({
          'recordType': 'simulated-host-click',
          'label': action['label'],
          'entryPoint': action['entryPoint'],
          'userMessage': action['message'],
          'taskSeeded': false,
        });
        await send(
          action['message'] as String,
          'simulated-host-click-to-user-message',
        );
        await answerQuestions();
      }
    }
  } on Object catch (error) {
    failures.add('case stopped: ${error.runtimeType}');
    append({'recordType': 'case-error', 'error': _error(error, redactor)});
  } finally {
    watch.stop();
    await subscription.cancel();
    wire.onModelMismatch = null;
    await controller.dispose();
    await agent.dispose();
  }
  switch (scenario['expectedFinal']) {
    case 'plan':
      if (last?.plan == null) failures.add('expected a final validated plan');
    case 'actions-or-plan':
      if (last?.plan == null && last?.actions == null) {
        failures.add('expected validated actions or a validated plan');
      }
    case 'text-without-task':
      if (last == null ||
          last!.text.trim().isEmpty ||
          last?.plan != null ||
          last?.actions != null) {
        failures.add('expected an ordinary text answer without cards');
      }
      if (events.any((event) => event['task'] != null) ||
          wire.calls.any(
            (call) => _responseToolNames(call).contains('start_task'),
          )) {
        failures.add('ordinary question unexpectedly created a task');
      }
  }
  if (scenario['expectedMinutes'] case final num minutes) {
    if (last?.plan?.plan.targetMinutes != minutes) {
      failures.add('explicit target minutes were not preserved');
    }
  }
  if (scenario['expectedScene'] case final String scene) {
    if (last?.plan?.plan.scene != scene) {
      failures.add('explicit scene was not preserved');
    }
  }
  if (scenario['expectedEquipment'] case final List<Object?> equipment) {
    final actual = last?.plan?.plan.equipment.toSet();
    if (actual == null ||
        actual.length != equipment.length ||
        !actual.containsAll(equipment)) {
      failures.add('explicit equipment was not preserved');
    }
  }
  if (wire.calls.isEmpty) failures.add('no real HTTP model request was made');
  if (wire.calls.isNotEmpty &&
      (wire.calls.first['requestBytes'] as int) > 12 * 1024) {
    failures.add('actual first HTTP request body exceeded 12KB');
  }
  final rejected = _rejectedCalls(turns);
  for (final rejection in rejected) {
    if ({'show_actions', 'show_plan'}.contains(rejection['name'])) {
      failures.add('show_* was rejected: ${rejection['result']}');
    }
  }
  for (final turn in turns) {
    final task = _map(turn['task']);
    final calls = _list(turn['calls']).map(_map).toList();
    failures.addAll(
      evaluationTurnBudgetFailures(
        turn: turn['turn'] as int,
        elapsedMs: turn['elapsedMs'] as int,
        calls: calls,
        events: events,
      ),
    );
    final delivered = turn['plan'] != null || _list(turn['actions']).isNotEmpty;
    if (!delivered) continue;
    final expected = turn['plan'] != null
        ? [
            'understand',
            'parameters',
            'actions',
            'planning',
            'review',
            'output',
          ]
        : ['understand', 'parameters', 'actions', 'output'];
    final nodes = _list(task['nodes']).map(_map).toList();
    if (jsonEncode(nodes.map((node) => node['id']).toList()) !=
            jsonEncode(expected) ||
        nodes.any(
          (node) =>
              node['status'] != 'done' ||
              node['stamp'] is! String ||
              (node['stamp'] as String).trim().isEmpty,
        )) {
      failures.add(
        'turn ${turn['turn']} card lacks completed fixed nodes and stamps',
      );
    }
    final eventNodes = [
      for (final event in events)
        if (event['turn'] == turn['turn'] &&
            _map(event['node'])['status'] == 'done')
          _map(event['node'])['id'],
    ];
    if (!eventNodes.contains('output')) {
      failures.add(
        'turn ${turn['turn']} delivery lacks actual output node event',
      );
    }
  }
  if (scenario['id'] == 'R4' && last?.plan != null) {
    final reused = events.any(
      (event) =>
          _map(event['task'])['type'] == 'plan' &&
          _map(event['task'])['reused'] == true,
    );
    if (!reused) failures.add('R4 promotion lacks actual node reuse event');
  }
  final modelMismatches = [
    for (final call in wire.calls)
      if (call['modelMatchesRequest'] == false)
        {
          'call': call['call'],
          'requested': _map(call['request'])['model'],
          'actual': _map(call['response'])['model'],
        },
  ];
  if (modelMismatches.isNotEmpty) {
    failures.add('response model differs from configured model; case invalid');
  }
  return {
    'id': scenario['id'],
    'thinkingMode': thinkingMode.name,
    'originalInputs': scenario['messages'],
    'simulatedSupplementaryUserFacts': true,
    'modelCalls': wire.calls.length,
    'elapsedMs': watch.elapsedMilliseconds,
    'callStatistics': _callStatistics(wire.calls),
    'automatedChecksPassed': failures.isEmpty,
    'automatedFailures': failures,
    'caseValidity': modelMismatches.isNotEmpty
        ? 'invalid-model-mismatch'
        : wire.calls.any((call) => call['modelMatchesRequest'] == true)
        ? 'valid-model-route'
        : 'unverified-model-route',
    'modelMismatches': modelMismatches,
    'rejectedCalls': rejected,
    'modelQualityPassed': null,
    'manualReviewRequired': scenario['review'],
    'turns': turns,
    'events': events,
    'calls': wire.calls,
  };
}

class EvaluationWireClient extends http.BaseClient {
  EvaluationWireClient(this.inner, this.redactor, this.append);
  final http.Client inner;
  final EvaluationRedactor redactor;
  final void Function(Json) append;
  final calls = <Json>[];
  int turn = 0;
  int agentStep = 0;
  int Function()? caseElapsedMs;
  Json? taskAtRequest;

  /// An invalid model route stops this case without rerunning it.
  void Function()? onModelMismatch;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is! http.Request) {
      throw StateError('Cannot measure the actual request body');
    }
    final body = request.bodyBytes;
    final decoded = _map(jsonDecode(utf8.decode(body)));
    final record = <String, Object?>{
      'recordType': 'model-call',
      'call': calls.length + 1,
      'turn': turn,
      'agentStep': agentStep,
      'caseElapsedMs': caseElapsedMs?.call(),
      'taskAtRequest': taskAtRequest,
      'at': DateTime.now().toUtc().toIso8601String(),
      'requestBytes': body.length,
      'thinkingMode': evaluationRequestThinkingMode(decoded),
      'reasoningReplay': reasoningReplayStats(decoded),
      'requestSha256': sha256.convert(body).toString(),
      'request': publicEvaluationRequest(decoded, redactor),
    };
    calls.add(record);
    append({...record, 'recordType': 'model-call-start'});
    final watch = Stopwatch()..start();
    try {
      final response = await inner.send(request);
      final bytes = await response.stream.toBytes();
      watch.stop();
      record['elapsedMs'] = watch.elapsedMilliseconds;
      record['httpStatus'] = response.statusCode;
      record['responseBytes'] = bytes.length;
      record['responseSha256'] = sha256.convert(bytes).toString();
      try {
        final result = _map(jsonDecode(utf8.decode(bytes)));
        record['response'] = publicEvaluationResponse(result, redactor);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          record['modelMatchesRequest'] = result['model'] == decoded['model'];
        }
        record['usage'] = redactor.clean(result['usage']);
      } on FormatException {
        record['response'] = {
          'bodyFormat': 'non-JSON',
          'bodyTextExcluded': true,
        };
        record['usage'] = null;
      }
      append(record);
      if (record['modelMatchesRequest'] == false) onModelMismatch?.call();
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        response.statusCode,
        contentLength: bytes.length,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
        request: response.request,
      );
    } on Object catch (error) {
      watch.stop();
      record['elapsedMs'] = watch.elapsedMilliseconds;
      record['transportErrorType'] = error.runtimeType.toString();
      record['usage'] = null;
      append(record);
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

Json publicEvaluationRequest(Json body, EvaluationRedactor redactor) => {
  for (final entry in body.entries)
    if (entry.key != 'messages') entry.key: redactor.clean(entry.value),
  'messages': [
    for (final raw in _list(body['messages']))
      publicEvaluationMessage(_map(raw), redactor),
  ],
};

Json publicEvaluationMessage(Json message, EvaluationRedactor redactor) {
  final text = message['content'];
  final reasoning = message['reasoning_content'];
  return {
    for (final entry in message.entries)
      if (entry.key != 'reasoning_content' &&
          entry.key != 'reasoning' &&
          !(message['role'] == 'system' && entry.key == 'content'))
        entry.key: redactor.clean(entry.value),
    if (message['role'] == 'system') ...{
      'contentExcluded': true,
      'contentBytes': text is String ? utf8.encode(text).length : null,
      'contentSha256': text is String
          ? sha256.convert(utf8.encode(text)).toString()
          : null,
    },
    'reasoningFieldPresent': message.containsKey('reasoning_content'),
    'reasoningCharacters': reasoning is String ? reasoning.length : null,
    'reasoningUtf8Bytes': reasoning is String
        ? utf8.encode(reasoning).length
        : null,
  };
}

Json publicEvaluationResponse(Json body, EvaluationRedactor redactor) => {
  'model': redactor.clean(body['model']),
  'usage': redactor.clean(body['usage']),
  'error': redactor.clean(body['error']),
  'choices': [
    for (final raw in _list(body['choices']))
      if (_map(raw) case final choice)
        {
          'index': choice['index'],
          'finish_reason': choice['finish_reason'],
          'message': publicEvaluationMessage(_map(choice['message']), redactor),
        },
  ],
};

List<String> _responseToolNames(Json call) => [
  for (final rawChoice in _list(_map(call['response'])['choices']))
    for (final rawTool in _list(_map(_map(rawChoice)['message'])['tool_calls']))
      if (_map(_map(rawTool)['function'])['name'] case final String name) name,
];

List<Json> _rejectedCalls(List<Json> turns) {
  final rejected = <Json>[];
  final seen = <String>{};
  void scan(Object? raw, Object? turn) {
    final messages = _list(raw).map(_map).toList();
    final calls = <String, Json>{};
    for (final message in messages) {
      for (final call in _list(message['tool_calls']).map(_map)) {
        if (call['id'] case final String id) calls[id] = call;
      }
      if (message['role'] != 'tool' || message['content'] is! String) continue;
      try {
        final result = _map(jsonDecode(message['content'] as String));
        if (result['ok'] != false) continue;
        final id = message['tool_call_id'];
        final function = _map(calls[id]?['function']);
        final key = jsonEncode([id, function, result]);
        if (!seen.add(key)) continue;
        rejected.add({
          'turnObserved': turn,
          'toolCallId': id,
          'name': function['name'],
          'arguments': function['arguments'],
          'result': result,
        });
      } on FormatException {
        // An archived text result does not add a new rejection.
      }
    }
  }

  for (final turn in turns) {
    for (final call in _list(turn['calls']).map(_map)) {
      scan(_map(call['request'])['messages'], turn['turn']);
    }
    scan(turn['agentHistoryAfterTurn'], turn['turn']);
  }
  return rejected;
}

String _summaryTable(List<Json> results, Json statistics) {
  final output = StringBuffer()
    ..writeln('# Coach Agent v2 real evaluation')
    ..writeln()
    ..writeln(
      'Overall single-call P50=${statistics['p50Ms']} ms; P90=${statistics['p90Ms']} ms; '
      'calls over 40 seconds=${statistics['callsOver40Seconds']}.',
    )
    ..writeln()
    ..writeln(
      '| Case | Turn | Thinking | Task | Validity | Calls | Time ms | Max request B | Tokens | Replayed reasoning B | Model |',
    )
    ..writeln('|---|---:|---|---|---|---:|---:|---:|---:|---:|---|');
  for (final result in results) {
    for (final turn in _list(result['turns']).map(_map)) {
      final stats = _map(turn['callStatistics']);
      output.writeln(
        '| ${result['id']} | ${turn['turn']} | ${turn['thinkingMode'] ?? result['thinkingMode'] ?? 'unknown'} | ${turn['activityTaskType'] ?? 'qa'} | '
        '${result['caseValidity']} | ${stats['modelCalls']} | ${turn['elapsedMs']} | '
        '${stats['maxRequestBytes']} | ${_map(stats['totalTokens'])['knownTotal'] ?? 'unknown'} | '
        '${stats['reasoningReplayUtf8Bytes']} | ${stats['responseModels']} |',
      );
    }
  }
  output.writeln();
  return output.toString();
}

class EvaluationRedactor {
  EvaluationRedactor(this.secrets);
  final List<String> secrets;
  Object? clean(Object? value) => switch (value) {
    String() => text(value),
    Map() => {
      for (final entry in value.entries)
        if (entry.key != 'reasoning_content' && entry.key != 'reasoning')
          entry.key.toString(): clean(entry.value),
    },
    Iterable() => value.map(clean).toList(),
    _ => value,
  };
  String text(String input) {
    var result = input;
    for (final secret in secrets) {
      if (secret.isEmpty) continue;
      // Header validation errors may JSON-escape CR/LF, quotes and slashes.
      // Match those representations too before any diagnostic is persisted.
      final variants = <String>{secret};
      var escaped = secret;
      for (var depth = 0; depth < 2; depth++) {
        final encoded = jsonEncode(escaped);
        escaped = encoded.substring(1, encoded.length - 1);
        variants.add(escaped);
      }
      final longestFirst = variants.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final variant in longestFirst) {
        result = result.replaceAll(variant, '[REDACTED]');
      }
    }
    return result.replaceAll(
      RegExp(r'''https?://[^\s<>"']+'''),
      '[URL_REDACTED]',
    );
  }
}

/// Checks the supplied environment token without echoing it in diagnostics.
/// Configuration prose and multi-line files must be parsed by the launcher,
/// never passed through as an HTTP header value.
String validateEvaluationAppKey(String value) {
  if (value.isEmpty ||
      value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
    throw StateError(
      'UGK_APP_KEY must be a single nonempty ASCII token without whitespace or header controls',
    );
  }
  return value;
}

Future<AuthProvider> _auth(
  Map<String, String> env,
  EvaluationRedactor redactor,
) async {
  final appKey = validateEvaluationAppKey(env['UGK_APP_KEY'] ?? '');
  var device = env['UGK_DEVICE_ID'] ?? '';
  final deviceFile = env['UGK_DEVICE_FILE'];
  if (device.isEmpty && deviceFile != null) {
    device = (await File(deviceFile).readAsString()).trim();
  }
  if (appKey.isEmpty ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(device)) {
    throw StateError(
      'Existing authorized Worker key and device identity required',
    );
  }
  redactor.secrets.addAll([appKey, device]);
  return UgkWorkerAuth(appKey: appKey, deviceId: () async => device);
}

Object? _error(Object? error, EvaluationRedactor redactor) {
  if (error == null) return null;
  if (error is LlmException) {
    return {
      'type': 'LlmException',
      'kind': error.kind.name,
      'statusCode': error.statusCode,
      'message': redactor.text(error.message),
      'finishReason': error.finishReason,
    };
  }
  return {
    'type': error.runtimeType.toString(),
    'message': redactor.text(error.toString()),
  };
}

Json _callStatistics(List<Json> calls) {
  final times = [
    for (final call in calls)
      if (call['elapsedMs'] case final num value) value.toDouble(),
  ]..sort();
  Json field(String key) {
    final values = [
      for (final call in calls)
        if (_map(call['usage'])[key] case final num value) value,
    ];
    return {
      'knownTotal': values.isEmpty
          ? null
          : values.fold<num>(0, (a, b) => a + b),
      'knownCalls': values.length,
      'unknownCalls': calls.length - values.length,
    };
  }

  return {
    'modelCalls': calls.length,
    'responseModels': calls
        .map((call) => _map(call['response'])['model'])
        .toSet()
        .toList(),
    'maxRequestBytes': calls.isEmpty
        ? null
        : calls
              .map((call) => call['requestBytes'] as int)
              .reduce((a, b) => a > b ? a : b),
    'reasoningReplayUtf8Bytes': calls.fold<int>(
      0,
      (total, call) =>
          total +
          (_map(call['reasoningReplay'])['totalUtf8Bytes'] as int? ?? 0),
    ),
    'elapsedKnownCalls': times.length,
    'totalModelCallMs': times.isEmpty ? null : times.reduce((a, b) => a + b),
    'p50Ms': _percentile(times, .5),
    'p90Ms': _percentile(times, .9),
    'percentileMethod':
        'linear interpolation over actual HTTP attempt durations',
    'callsOver40Seconds': times.where((value) => value > 40000).length,
    'promptTokens': field('prompt_tokens'),
    'completionTokens': field('completion_tokens'),
    'totalTokens': field('total_tokens'),
  };
}

double? _percentile(List<double> values, double fraction) {
  if (values.isEmpty) return null;
  final at = (values.length - 1) * fraction;
  final lower = at.floor();
  final upper = at.ceil();
  return values[lower] + (values[upper] - values[lower]) * (at - lower);
}

String _transcript(Json result) {
  const pretty = JsonEncoder.withIndent('  ');
  final output = StringBuffer()
    ..writeln(
      '# ${result['id']} real model transcript — thinking ${result['thinkingMode'] ?? 'unknown'}',
    )
    ..writeln()
    ..writeln(
      'Additional user replies and the host click are simulations. Assistant/tool output is real.',
    )
    ..writeln(
      'System prompts, credentials, endpoint URLs and internal reasoning text are excluded.',
    )
    ..writeln(
      'Automated checks are structural; model quality still requires review.',
    )
    ..writeln();
  for (final rawTurn in _list(result['turns'])) {
    final turn = _map(rawTurn);
    output
      ..writeln('## Turn ${turn['turn']} — ${turn['origin']}')
      ..writeln()
      ..writeln('User: ${turn['user']}')
      ..writeln()
      ..writeln('Assistant: ${turn['assistant']}')
      ..writeln()
      ..writeln('Status: ${turn['status']}; elapsed: ${turn['elapsedMs']} ms')
      ..writeln();
    for (final field in ['question', 'plan', 'actions', 'actionFacts']) {
      if (turn[field] != null) {
        output
          ..writeln('$field:')
          ..writeln('```json')
          ..writeln(pretty.convert(turn[field]))
          ..writeln('```')
          ..writeln();
      }
    }
    for (final rawCall in _list(turn['calls'])) {
      final call = _map(rawCall);
      output
        ..writeln('### HTTP call ${call['call']}')
        ..writeln()
        ..writeln(
          'Thinking: ${call['thinkingMode']}; request bytes: ${call['requestBytes']}; replayed reasoning UTF-8 bytes: ${_map(call['reasoningReplay'])['totalUtf8Bytes']}; elapsed: ${call['elapsedMs']} ms; HTTP: ${call['httpStatus']}; model: ${_map(call['response'])['model']}',
        )
        ..writeln()
        ..writeln('```json')
        ..writeln(
          pretty.convert({
            'request': call['request'],
            'response': call['response'],
            'usage': call['usage'],
            'reasoningReplay': call['reasoningReplay'],
          }),
        )
        ..writeln('```')
        ..writeln();
    }
    output
      ..writeln('### Public SDK history after this turn')
      ..writeln()
      ..writeln(
        'Final tool acknowledgements may be stored here without another HTTP request.',
      )
      ..writeln()
      ..writeln('```json')
      ..writeln(pretty.convert(turn['agentHistoryAfterTurn']))
      ..writeln('```')
      ..writeln();
  }
  output
    ..writeln('## Timestamped node/event record')
    ..writeln()
    ..writeln('```json')
    ..writeln(pretty.convert(result['events']))
    ..writeln('```')
    ..writeln()
    ..writeln('## Automated checks and manual review')
    ..writeln()
    ..writeln('```json')
    ..writeln(
      pretty.convert({
        'automatedChecksPassed': result['automatedChecksPassed'],
        'automatedFailures': result['automatedFailures'],
        'manualReviewRequired': result['manualReviewRequired'],
        'caseValidity': result['caseValidity'],
        'modelMismatches': result['modelMismatches'],
        'rejectedCalls': result['rejectedCalls'],
        'callStatistics': result['callStatistics'],
      }),
    )
    ..writeln('```');
  return output.toString();
}

Future<String> _sourceFingerprint() async {
  final files = <File>[
    for (final dir in ['lib', 'profiles', 'prompts', 'skills'])
      for (final entry in Directory(dir).listSync(recursive: true))
        if (entry is File) entry,
    File('pubspec.yaml'),
    File('tool/eval_coach_agent_v2.dart'),
    File('tool/eval_reasoning_stats.dart'),
    File('tool/eval_thinking_mode.dart'),
    File('tool/eval_turn_budget.dart'),
    File('eval/cases/coach_agent_v2.json'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final bytes = BytesBuilder(copy: false);
  for (final file in files) {
    bytes.add(utf8.encode(file.path.replaceAll('\\', '/')));
    bytes.addByte(0);
    bytes.add(await file.readAsBytes());
    bytes.addByte(0);
  }
  return sha256.convert(bytes.takeBytes()).toString();
}

Json _map(Object? value) => value is Map
    ? {for (final entry in value.entries) entry.key.toString(): entry.value}
    : <String, Object?>{};
List<Object?> _list(Object? value) => value is List ? value : <Object?>[];
Future<void> _writeJson(File file, Object? value) =>
    file.writeAsString(const JsonEncoder.withIndent('  ').convert(value));
