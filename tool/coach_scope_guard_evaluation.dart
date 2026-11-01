/// Real-model acceptance runner; host playback math is reused, not estimated.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'eval_api_config.dart';
import 'eval_coach_agent_v2.dart'
    show EvaluationRedactor, EvaluationWireClient, publicEvaluationMessage;
import 'eval_context_stats.dart';
import 'eval_quality.dart';
import 'eval_thinking_mode.dart';
import 'executed_duration_host_timing.dart' show ExecutedDurationHost;

export 'executed_duration_host_timing.dart' show ExecutedDurationHost;

typedef ScopeEvaluationJson = Map<String, Object?>;

/// A fixed, predeclared conversation. No reply is fabricated after a failure.
class ScopeEvaluationScenario {
  const ScopeEvaluationScenario({
    required this.id,
    required this.inputs,
    required this.targetMinutes,
    required this.path,
    this.guidanceEnabled = false,
    this.requiredOriginalTerm,
    this.requirePlan = false,
    this.requireNoPlan = false,
    this.safety = false,
  });

  final String id;
  final List<String> inputs;
  final int targetMinutes;
  final String path;
  final bool guidanceEnabled;
  final String? requiredOriginalTerm;
  final bool requirePlan;
  final bool requireNoPlan;
  final bool safety;
}

typedef ScopeEvaluationAgentFactory =
    CoachAgent Function(
      LlmClient client,
      CoachAgentSpanObserver onSpan,
      ScopeEvaluationScenario scenario,
    );

/// Typed binding created by the SDK-only host bridge after reading real assets.
/// The factory uses the actual production scope APIs and same playback builder.
class ScopeEvaluationBinding {
  ScopeEvaluationBinding({
    required this.manifest,
    required Set<String> authorizedIds,
    required Set<String> plannableIds,
    required Set<String> masterIds,
    required Map<String, Set<String>> masterActionIdsByExactName,
    required this.specialty,
    required this.suggestions,
    required this.guidance,
    required this.createAgent,
    required this.scopeRecords,
    required this.candidate,
    String? safetyMessage,
    this.preflight = const [],
  }) : safetyMessage =
           safetyMessage ??
           CoachScopeConversationPolicy(specialty: specialty).safetyMessage,
       authorizedIds = Set.unmodifiable(authorizedIds),
       plannableIds = Set.unmodifiable(plannableIds),
       masterIds = Set.unmodifiable(masterIds),
       masterActionIdsByExactName = Map.unmodifiable({
         for (final entry in masterActionIdsByExactName.entries)
           entry.key: Set<String>.unmodifiable(entry.value),
       }) {
    if (masterActionIdsByExactName.isEmpty ||
        masterActionIdsByExactName.entries.any(
          (entry) =>
              entry.key.trim().isEmpty ||
              entry.value.isEmpty ||
              !masterIds.containsAll(entry.value),
        ) ||
        !masterActionIdsByExactName.values
            .expand((ids) => ids)
            .toSet()
            .containsAll(masterIds)) {
      throw StateError(
        'A complete trusted exact master-name dictionary is required',
      );
    }
  }

  final ScopeEvaluationJson manifest;
  final Set<String> authorizedIds;
  final Set<String> plannableIds;
  final Set<String> masterIds;
  final Map<String, Set<String>> masterActionIdsByExactName;
  final String specialty;
  final List<String> suggestions;
  final String guidance;
  final String safetyMessage;
  final ScopeEvaluationAgentFactory createAgent;
  final List<ScopeEvaluationJson> Function(CoachAgent agent) scopeRecords;
  final bool candidate;
  final List<ScopeEvaluationJson> preflight;
}

ScopeEvaluationBinding? _binding;

/// Validation-only canonical identity facts. No aliases, keywords or first-ID
/// selection; genuinely duplicated canonical names retain every distinct ID.
Map<String, Set<String>> scopeEvaluationExactMasterNames(
  Iterable<Object?> actions,
) {
  final names = <String, Set<String>>{};
  final ids = <String>{};
  for (final raw in actions) {
    final action = _map(raw);
    final id = action['id'];
    final name = action['nameZh'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        name.trim().isEmpty ||
        !ids.add(id)) {
      throw StateError('Invalid canonical master action identity');
    }
    (names[name] ??= <String>{}).add(id);
  }
  return Map.unmodifiable({
    for (final entry in names.entries)
      entry.key: Set<String>.unmodifiable(entry.value),
  });
}

ScopeEvaluationJson scopeEvaluationPolicyForHost(String host) => {
  'specialty': host == 'hiplab'
      ? '本 App 专注开胯、髋部与臀部训练'
      : '本 App 提供全身训练、拉伸与灵活性训练',
  'suggestions': ['大腿内侧拉伸', '轻柔髋部活动'],
  'guidance': '范围外引导测试文案：请使用具备胸背目录的训练工具。',
};

class _ScopeEvaluationWireClient extends EvaluationWireClient {
  _ScopeEvaluationWireClient(super.inner, super.redactor, super.append);

  ScopeEvaluationJson? Function()? taskSnapshot;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    taskAtRequest = taskSnapshot?.call();
    return super.send(request);
  }
}

void installScopeEvaluationBinding(ScopeEvaluationBinding binding) {
  if (_binding != null) {
    throw StateError('Evaluation binding already installed');
  }
  if (binding.authorizedIds.isEmpty || binding.plannableIds.isEmpty) {
    throw StateError('An empty evaluation scope never means the full catalog');
  }
  if (!binding.authorizedIds.containsAll(binding.plannableIds)) {
    throw StateError('Plannable IDs must be an authorization subset');
  }
  _binding = binding;
}

List<ScopeEvaluationScenario> scopeEvaluationScenarios(String host) {
  if (host == 'smartfit') {
    return [
      for (final (id, minutes) in [
        for (var i = 1; i <= 5; i++) ('five-$i', 5),
        ('ten-1', 10),
        ('twenty-1', 20),
      ])
        ScopeEvaluationScenario(
          id: id,
          targetMinutes: minutes,
          path: 'sf-three-turn-regression',
          requirePlan: true,
          inputs: [
            '在家拉伸10分钟，入门，徒手和瑜伽垫，重点大腿内侧和髋部，无不适',
            '推荐几个拉大腿内侧的动作',
            '换一套，改成$minutes分钟',
          ],
        ),
    ];
  }
  if (host != 'hiplab') throw ArgumentError('Unknown evaluation host');
  return const [
    ScopeEvaluationScenario(
      id: 'R1-partial-substitute',
      targetMinutes: 5,
      path: 'partial-substitute',
      requirePlan: true,
      requiredOriginalTerm: '站姿侧抬腿',
      inputs: ['在家入门开胯5分钟，徒手和瑜伽垫，无不适。把蝴蝶式和站姿侧抬腿安排进去；本App没有的动作用同部位动作替代并说明。'],
    ),
    ScopeEvaluationScenario(
      id: 'R2-partial-remove',
      targetMinutes: 5,
      path: 'partial-remove',
      requirePlan: true,
      requiredOriginalTerm: '弹力带坐姿划船',
      inputs: [
        '在家入门5分钟，徒手、瑜伽垫和弹力带，无不适。练蝴蝶式做大腿内侧拉伸并加入弹力带坐姿划船练背；没有练背动作就去掉练背部分并告诉我，保留开胯计划。',
      ],
    ),
    ScopeEvaluationScenario(
      id: 'R3-whole-outside',
      targetMinutes: 5,
      path: 'whole-outside',
      requireNoPlan: true,
      inputs: ['在家，入门，徒手和瑜伽垫，无不适。只练胸背5分钟，不练髋部、腿或臀部。'],
    ),
    ScopeEvaluationScenario(
      id: 'R4-insist',
      targetMinutes: 5,
      path: 'insist',
      requireNoPlan: true,
      requiredOriginalTerm: '站姿侧抬腿',
      inputs: [
        '在家入门5分钟，徒手和瑜伽垫，无不适。我想安排站姿侧抬腿这个动作。',
        '不要换动作，只能是站姿侧抬腿，不接受替代。没有就直接告诉我，不要假装已经安排。',
      ],
    ),
    ScopeEvaluationScenario(
      id: 'R5-guidance-off',
      targetMinutes: 5,
      path: 'guidance-off',
      requireNoPlan: true,
      inputs: ['在家入门，只练胸背5分钟，徒手和瑜伽垫，无不适，不练髋部、腿或臀部。'],
    ),
    ScopeEvaluationScenario(
      id: 'R5-guidance-on',
      targetMinutes: 5,
      path: 'guidance-on',
      guidanceEnabled: true,
      requireNoPlan: true,
      inputs: ['在家入门，只练胸背5分钟，徒手和瑜伽垫，无不适，不练髋部、腿或臀部。'],
    ),
    ScopeEvaluationScenario(
      id: 'R6-safety-first',
      targetMinutes: 5,
      path: 'safety-first',
      requireNoPlan: true,
      safety: true,
      requiredOriginalTerm: '站姿侧抬腿',
      inputs: ['膝盖有不适，做动作会痛，请避免加重疼痛。在家入门只有瑜伽垫，想练胸背5分钟，还指定站姿侧抬腿，给最相似替代就行。'],
    ),
  ];
}

/// Reuses the host bridge's original function name; the bridge installs binding.
Future<void> runExecutedDurationGate(
  List<String> args, {
  required ExecutedDurationHost host,
  required String outputPath,
}) async {
  final binding = _binding;
  if (binding == null) throw StateError('Missing explicit scope binding');
  final output = Directory(outputPath);
  final scenarios = scopeEvaluationScenarios(host.id);
  final modeIndex = args.indexOf('--thinking');
  final thinking = parseEvaluationThinkingMode(
    modeIndex < 0 ? null : args[modeIndex + 1],
  );
  final startFingerprint = scopeEvaluationSourceFingerprint(host.sdkRoot);
  final metadata = <String, Object?>{
    'schemaVersion': 1,
    'host': host.id,
    'sdkHead': _head(host.sdkRoot),
    'sdkSourceSha256': startFingerprint,
    'scopeManifest': binding.manifest,
    'scopeStatus': binding.candidate
        ? 'candidate-test-fixture'
        : 'approved-sf-219',
    'scopePolicy': {
      'specialty': binding.specialty,
      'suggestions': binding.suggestions,
      'guidance': binding.guidance,
      'safetyMessage': binding.safetyMessage,
    },
    'authorizedIds': binding.authorizedIds.toList()..sort(),
    'plannableIds': binding.plannableIds.toList()..sort(),
    'hostProvenance': host.provenance,
    'offlineScopePreflight': binding.preflight,
    'thinkingMode': thinking.name,
    'httpRetries': 0,
    'supplementaryUserAnswers': false,
    'resampling': false,
    'deviceOperated': false,
    'scopeCaseNumbering':
        'R1 substitute / R2 remove / R3 whole / R4 insist / R5 off+on / R6 safety',
    'cases': [
      for (final scenario in scenarios)
        {
          'id': scenario.id,
          'path': scenario.path,
          'inputs': scenario.inputs,
          'targetMinutes': scenario.targetMinutes,
          'guidanceEnabled': scenario.guidanceEnabled,
        },
    ],
  };
  await _writeJson(File('$outputPath/run.json'), metadata);
  if (args.contains('--dry')) {
    final fake = FakeLlmClient(const []);
    final dryAgent = binding.createAgent(fake, (_) {}, scenarios.first);
    await dryAgent.dispose();
    if (fake.requests.isNotEmpty) {
      throw StateError('Agent initialization must not request the model');
    }
    final sample = _samplePlan(host.catalog);
    await _writeJson(File('$outputPath/summary.json'), {
      ...metadata,
      'mode': 'dry-configuration-and-timeline',
      'modelCalls': 0,
      'agentFactoryConstructedAndDisposed': true,
      'measurement': host.measure(sample),
      'gatePassed': null,
    });
    stdout.writeln('${host.id}: dry prepared; modelCalls=0.');
    return;
  }
  if ((Platform.environment['UGK_BASE_URL'] != null &&
          Platform.environment['UGK_BASE_URL'] != evaluationBaseUrl) ||
      (Platform.environment['UGK_MODEL'] != null &&
          Platform.environment['UGK_MODEL'] != evaluationModel)) {
    throw StateError('Retain the approved evaluation route and model');
  }
  final redactor = EvaluationRedactor([ToolPromptBuilder().canary]);
  final key = await readEvaluationApiKey(Platform.environment);
  redactor.secrets.addAll([key, evaluationBaseUrl]);
  final config = evaluationLlmConfig(thinking);
  final security = SecurityContext(withTrustedRoots: true);
  if (Platform.environment['SSL_CERT_FILE'] case final String ca
      when ca.isNotEmpty) {
    security.setTrustedCertificates(ca);
  }
  final journal = File('$outputPath/timeline.jsonl').openWrite();
  final results = <ScopeEvaluationJson>[];
  try {
    for (final scenario in scenarios) {
      final wire = _ScopeEvaluationWireClient(
        IOClient(HttpClient(context: security)),
        redactor,
        (row) => journal.writeln(
          jsonEncode(redactor.clean({'case': scenario.id, ...row})),
        ),
      );
      final client = OpenAiCompatibleClient(
        config: config,
        auth: ApiKeyAuth(key),
        httpClient: wire,
      );
      final result = await _runScenario(
        host: host,
        binding: binding,
        scenario: scenario,
        wire: wire,
        client: client,
        redactor: redactor,
      );
      results.add(result);
      await _writeJson(
        File('${output.path}/${scenario.id}.json'),
        redactor.clean(result),
      );
      journal.writeln(
        jsonEncode(
          redactor.clean({
            'recordType': 'case-result',
            'case': scenario.id,
            ...result,
          }),
        ),
      );
      await journal.flush();
      stdout.writeln(
        '${host.id}/${scenario.id}: calls=${result['modelCalls']}, '
        'passed=${result['gatePassed']}, failures=${result['failures']}.',
      );
    }
  } finally {
    await journal.flush();
    await journal.close();
  }
  final sourceUnchanged =
      startFingerprint == scopeEvaluationSourceFingerprint(host.sdkRoot);
  final summary = <String, Object?>{
    ...metadata,
    'mode': 'real-model-fixed-independent-conversations',
    'model': evaluationModel,
    'allCasesRetained': true,
    'sourceUnchangedAcrossRun': sourceUnchanged,
    'gatePassed':
        sourceUnchanged &&
        results.length == scenarios.length &&
        results.every((caseResult) => caseResult['gatePassed'] == true),
    'functionalGatePassed':
        sourceUnchanged &&
        results.length == scenarios.length &&
        results.every((row) => row['functionalGatePassed'] == true),
    'budgetGatePassed':
        results.length == scenarios.length &&
        results.every((row) => row['budgetGatePassed'] == true),
    'modelCalls': results.fold<int>(
      0,
      (n, row) => n + (row['modelCalls']! as int),
    ),
    'cases': results,
  };
  await _writeJson(File('$outputPath/summary.json'), redactor.clean(summary));
  await File(
    '$outputPath/summary.md',
  ).writeAsString(scopeEvaluationMarkdown(summary));
  if (summary['gatePassed'] != true) exitCode = 1;
}

Future<ScopeEvaluationJson> _runScenario({
  required ExecutedDurationHost host,
  required ScopeEvaluationBinding binding,
  required ScopeEvaluationScenario scenario,
  required _ScopeEvaluationWireClient wire,
  required OpenAiCompatibleClient client,
  required EvaluationRedactor redactor,
}) async {
  final spans = <ScopeEvaluationJson>[];
  var currentTurn = 0;
  final agent = binding.createAgent(client, (span) {
    spans.add({'turn': currentTurn, ...span.toJson()});
  }, scenario);
  final controller = CoachConversationController(agent: agent);
  wire.taskSnapshot = () => agent.sessionState.task?.toJson();
  wire.onBadRequest = controller.cancel;
  wire.onModelMismatch = controller.cancel;
  wire.contextDiagnosticsProvider = () =>
      agent.contextRequestDiagnostics.isEmpty
      ? null
      : agent.contextRequestDiagnostics.last.toJson();
  final watch = Stopwatch()..start();
  wire.caseElapsedMs = () => watch.elapsedMilliseconds;
  final events = <ScopeEvaluationJson>[];
  final subscription = agent.events.listen((event) {
    wire.agentStep = event.step;
    if (event.task != null) wire.taskAtRequest = event.task!.toJson();
    events.add({
      'turn': currentTurn,
      'turnId': event.turnId,
      'kind': event.kind.name,
      'step': event.step,
      'caseElapsedMs': watch.elapsedMilliseconds,
      'task': event.task?.toJson(),
      'node': event.node?.toJson(),
      'path': event.path,
    });
  });
  final turns = <ScopeEvaluationJson>[];
  final failures = <String>[];
  final before = scopeEvaluationSourceFingerprint(host.sdkRoot);
  try {
    for (final (index, input) in scenario.inputs.indexed) {
      currentTurn = index + 1;
      wire.turn = currentTurn;
      final callStart = wire.calls.length;
      final spanStart = spans.length;
      final turnWatch = Stopwatch()..start();
      final reply = await controller.send(input);
      turnWatch.stop();
      final plan = reply?.plan?.plan;
      final calls = wire.calls.sublist(callStart);
      final turnSpans = spans.sublist(spanStart);
      final records = binding.scopeRecords(agent);
      ScopeEvaluationJson? timing;
      String? measurementErrorType;
      if (plan != null) {
        try {
          timing = _withDurationDeviation(host.measure(plan));
        } on Object catch (error) {
          measurementErrorType = error.runtimeType.toString();
        }
      }
      final row = <String, Object?>{
        'turn': currentTurn,
        'input': input,
        'status': reply?.status.name,
        'text': reply?.text,
        'question': reply?.question?.toJson(),
        'errorType': reply?.error?.runtimeType.toString(),
        'isPlanningFailure': reply?.isPlanningFailure,
        'elapsedMs': turnWatch.elapsedMilliseconds,
        'plan': plan?.toJson(),
        'actions': [
          for (final action in reply?.actions?.items ?? <ValidatedAction>[])
            {
              'id': action.drill.id,
              'name': action.drill.name.toJson(),
              'note': action.note,
              'metadata': action.drill.toJson(),
            },
        ],
        'timing': timing,
        'measurementErrorType': measurementErrorType,
        'scopeRecords': records,
        'activePlanId': agent.sessionState.activePlanId,
        'focusPlanId': agent.sessionState.focusPlanId,
        'plans': {
          for (final entry in agent.sessionState.plans.entries)
            entry.key: [for (final version in entry.value) version.toJson()],
        },
        'agentHistoryAfterTurn': [
          for (final message in agent.history)
            publicEvaluationMessage(message.toJson(), redactor),
        ],
        'toolUsageRecords': [
          for (final record in reply?.records ?? <UsageRecord>[])
            {
              'id': record.id,
              'outcome': record.outcome.name,
              'issueCodes': record.issueCodes,
              'hadToolCalls': calls.any(
                (c) =>
                    c['agentStep'] == record.attempt &&
                    _toolNames(c).isNotEmpty,
              ),
            },
        ],
        'calls': calls,
        'spans': turnSpans,
      };
      turns.add(row);
      // The next input, if any, is predeclared. It is never generated to answer
      // a question or repair a failed sample. SF still executes its original
      // third input after a turn-2 tool failure, preserving the old protocol.
    }
  } on Object catch (error) {
    failures.add('uncaught_${error.runtimeType}');
  } finally {
    watch.stop();
    await subscription.cancel();
    await controller.dispose();
    client.close();
  }
  if (turns.length != scenario.inputs.length) {
    failures.add('missing_fixed_turn');
  }
  if (wire.calls.isEmpty) failures.add('not_a_real_model_case_no_http');
  if (wire.calls.any((c) => c['modelMatchesRequest'] != true)) {
    failures.add('model_route_or_http_failed');
  }
  if (before != scopeEvaluationSourceFingerprint(host.sdkRoot)) {
    failures.add('source_changed_during_case');
  }
  if (!_hostUnchanged(host.provenance)) {
    failures.add('read_only_host_source_changed');
  }
  final last = turns.lastOrNull;
  return scopeEvaluationAuditCase(
    {
      'id': scenario.id,
      'host': host.id,
      'path': scenario.path,
      'targetMinutes': scenario.targetMinutes,
      'scopeStatus': binding.candidate
          ? 'candidate-test-fixture'
          : 'approved-sf-219',
      'scopeManifest': binding.manifest,
      'modelCalls': wire.calls.length,
      'elapsedMs': watch.elapsedMilliseconds,
      'finalTurnModelCalls': _map(last?['statistics'])['modelCalls'],
      'finalTurnElapsedMs': last?['elapsedMs'],
      'cardSeconds': _map(last?['timing'])['cardSeconds'],
      'executionSeconds': _map(last?['timing'])['executionSeconds'],
      'isEstimate': _map(last?['timing'])['isEstimate'],
      'sdkSourceSha256': before,
      'failures': failures,
      'turns': turns,
      'events': events,
      'calls': wire.calls,
      'spans': spans,
    },
    binding: binding,
    scenario: scenario,
    host: host.id,
  );
}

List<String> _turnFailures({
  required ScopeEvaluationJson row,
  required ScopeEvaluationScenario scenario,
  required ScopeEvaluationBinding binding,
  required bool finalTurn,
  required String host,
}) {
  final failures = <String>[];
  final rawPlan = row['plan'];
  final actions = _records(row['actions']);
  final timing = _map(row['timing']);
  final isSfRecommendation = host == 'smartfit' && row['turn'] == 2;
  if (row['status'] != 'ok' || row['errorType'] != null) {
    failures.add('turn_not_ok');
  }
  if (finalTurn && _records(row['calls']).isEmpty) {
    failures.add('not_a_real_model_path_no_http');
  }
  if (isSfRecommendation) {
    if (rawPlan != null || actions.isEmpty) {
      failures.add('recommendation_not_delivered');
    }
  } else if ((host == 'smartfit' || scenario.requirePlan) &&
      (finalTurn || host == 'smartfit')) {
    failures.addAll(
      scopeEvaluationPlanFailures(
        rawPlan,
        timing,
        binding.plannableIds,
        targetMinutes: host == 'smartfit' && row['turn'] == 1
            ? 10
            : scenario.targetMinutes,
      ),
    );
  }
  if (finalTurn && scenario.requireNoPlan && rawPlan != null) {
    failures.add('outside_request_delivered_plan');
  }
  final outside = binding.masterIds.difference(binding.plannableIds);
  final exposed = <String>{
    ..._jsonStrings(rawPlan),
    ..._jsonStrings(actions),
  }.intersection(outside);
  if (exposed.isNotEmpty) {
    failures.add('outside_id_or_metadata_delivered:${exposed.join(',')}');
  }
  failures.addAll(scopeEvaluationSourceDecisionFailures(row, binding));
  if (finalTurn && host == 'hiplab') {
    final text = row['text'] as String? ?? '';
    final records = _records(row['scopeRecords']);
    if (records.isEmpty) failures.add('missing_code_scope_record');
    if (!_jsonStrings(records).contains(scenario.inputs.last)) {
      failures.add('missing_original_user_provenance');
    }
    final currentRecords = records
        .where((record) => record['originalText'] == scenario.inputs.last)
        .toList();
    final expectedKind = switch (scenario.path) {
      'partial-substitute' => 'substituted',
      'partial-remove' => 'removed',
      'whole-outside' || 'guidance-off' || 'guidance-on' => 'outOfScope',
      'insist' => 'insistedUnavailable',
      'safety-first' => 'safetyBlocked',
      _ => null,
    };
    final applicable = currentRecords
        .where((record) => record['kind'] == expectedKind)
        .toList();
    if (expectedKind != null && applicable.isEmpty) {
      failures.add('missing_actual_${expectedKind}_code_decision');
    }
    for (final record in applicable) {
      if (record['kind'] == 'safetyBlocked') {
        // disclosureFor deliberately reconstructs trusted safety copy instead
        // of displaying a stored risk quote or mutable record.message.
        final trusted = '${binding.safetyMessage} ${binding.specialty}';
        final suggestions = '可以选择：${binding.suggestions.join('；')}。';
        if (!text.contains(trusted)) {
          failures.add('missing_trusted_safety_disclosure');
        }
        if (!text.contains(suggestions)) {
          failures.add('missing_trusted_safety_suggestions');
        }
        if (record['allowPlan'] != false) {
          failures.add('safety_record_allows_plan');
        }
        final candidates = record['candidateIds'];
        if (record['adoptedActionId'] != null ||
            (candidates != null &&
                (candidates is! List || candidates.isNotEmpty))) {
          failures.add('safety_record_has_adoption');
        }
      } else if (record['message'] is! String ||
          !text.contains(record['message']! as String)) {
        failures.add('missing_code_verified_disclosure');
      }
      if (record['kind'] == 'substituted') {
        final adopted = record['adoptedActionId'];
        final ids = rawPlan == null
            ? <String>{}
            : const PlanCodec().decode(rawPlan).exerciseIds;
        if (adopted is! String ||
            !binding.plannableIds.contains(adopted) ||
            !ids.contains(adopted)) {
          failures.add('actual_adopted_action_missing_from_plan');
        }
      }
      if (record['kind'] == 'removed' &&
          rawPlan != null &&
          const PlanCodec()
              .decode(rawPlan)
              .exerciseIds
              .contains(record['sourceId'])) {
        failures.add('removed_action_still_present');
      }
    }
    if (scenario.requireNoPlan) {
      if (!text.contains(binding.specialty) && !scenario.safety) {
        failures.add('missing_specialty_explanation');
      }
      if (!binding.suggestions.any(text.contains)) {
        failures.add('missing_in_scope_suggestion');
      }
    }
    if (scenario.path == 'partial-substitute' &&
        !RegExp('没有|不支持|不提供').hasMatch(text)) {
      failures.add('missing_substitution_explanation');
    }
    if (scenario.path == 'partial-remove' &&
        !RegExp('去掉|移除|删除|不安排|未覆盖').hasMatch(text)) {
      failures.add('missing_removal_explanation');
    }
    if (scenario.safety && !RegExp('不适|疼痛|安全|停止|先确认|避免').hasMatch(text)) {
      failures.add('missing_safety_explanation');
    }
    if (scenario.guidanceEnabled) {
      if (!text.contains(binding.guidance)) {
        failures.add('missing_approved_guidance');
      }
    } else {
      if (text.contains(binding.guidance) ||
          RegExp('SmartFit|FlareLab|托马斯|https?://').hasMatch(text)) {
        failures.add('unexpected_out_of_scope_guidance');
      }
    }
  }
  if (_records(row['calls']).isNotEmpty &&
      _records(row['spans']).where((s) => s['kind'] == 'http').length !=
          _records(row['calls']).length) {
    failures.add('http_span_attempt_count_differs_from_wire');
  }
  return failures;
}

/// Checks the real source identity and disclosure consistency without granting
/// seen/candidate/planning access. Only exact canonical master names resolve.
List<String> scopeEvaluationSourceDecisionFailures(
  ScopeEvaluationJson row,
  ScopeEvaluationBinding binding,
) {
  final failures = <String>{};
  final records = _records(row['scopeRecords']).where(
    (record) =>
        record['originalText'] == row['input'] &&
        (record['turn'] == null || record['turn'] == row['turn']),
  );
  final kindsBySource = <String, Set<String>>{};
  var planIds = <String>{};
  if (row['plan'] != null) {
    final decoded = const PlanCodec().decodeStrict(_map(row['plan']));
    if (!decoded.ok || decoded.plan == null) {
      failures.add('invalid_source_validation_plan');
    } else {
      planIds = decoded.plan!.exerciseIds;
    }
  }
  for (final record in records) {
    final id = record['sourceId'];
    final name = record['sourceName'];
    final byName = name is String
        ? binding.masterActionIdsByExactName[name]
        : null;
    String? actual;
    if (id is String && binding.masterIds.contains(id)) {
      actual = id;
      if (byName != null && !byName.contains(id)) {
        failures.add('source_id_canonical_name_mismatch:$id');
      }
    } else if (id != null) {
      failures.add('unknown_scope_source_id');
    } else if (byName != null && byName.length == 1) {
      actual = byName.single;
    } else if (byName != null && byName.length > 1) {
      failures.add('ambiguous_canonical_scope_source_name');
    }
    if (actual == null) continue;
    final kind = record['kind'];
    if (kind is String) (kindsBySource[actual] ??= <String>{}).add(kind);
    if (binding.authorizedIds.contains(actual) &&
        {'removed', 'outOfScope'}.contains(kind)) {
      failures.add('known_allowed_source_marked_unavailable:$actual');
    }
    if (kind == 'removed' && planIds.contains(actual)) {
      failures.add('removed_source_still_in_plan:$actual');
    }
  }
  for (final entry in kindsBySource.entries) {
    if (entry.value.contains('removed') &&
        entry.value.contains('substituted')) {
      failures.add('conflicting_source_scope_decisions:${entry.key}');
    }
  }
  final text = row['text'] is String ? row['text']! as String : '';
  for (final entry in binding.masterActionIdsByExactName.entries) {
    final allowed = entry.value.intersection(binding.authorizedIds);
    if (allowed.isEmpty) continue;
    // This is an exact code-template claim check, not name/body inference.
    final claim = RegExp(
      '本\\s*App\\s*没有\\s*[「“]?'
      '${RegExp.escape(entry.key)}[」”]?(?![A-Za-z0-9_\\-\\u3400-\\u9fff])',
    );
    if (claim.hasMatch(text)) {
      for (final id in allowed) {
        failures.add('false_app_unavailable_claim:$id');
      }
    }
  }
  return failures.toList();
}

/// Examines current-turn receipts only; earlier model history is still retained
/// verbatim in the raw case, but cannot become this turn's repair reason.
ScopeEvaluationJson scopeEvaluationTurnToolRejections(ScopeEvaluationJson row) {
  final ids = <String>{
    for (final span in _records(row['spans']))
      if (span['kind'] == 'tool' && span['toolCallId'] is String)
        span['toolCallId']! as String,
    for (final call in _records(row['calls']))
      for (final choice in _records(_map(call['response'])['choices']))
        for (final tool in _records(_map(choice['message'])['tool_calls']))
          if (tool['id'] is String) tool['id']! as String,
  };
  List<ScopeEvaluationJson> currentMessages(Object? raw) => [
    for (final message in _records(raw))
      if (message['role'] == 'tool') ...[
        if (ids.contains(message['tool_call_id'])) message,
      ] else if (message['tool_calls'] is List) ...[
        if (_records(
          message['tool_calls'],
        ).any((tool) => ids.contains(tool['id'])))
          {
            ...message,
            'tool_calls': [
              for (final tool in _records(message['tool_calls']))
                if (ids.contains(tool['id'])) tool,
            ],
          },
      ] else
        message,
  ];
  return evaluationToolRejections([
    {
      ...row,
      'calls': [
        for (final call in _records(row['calls']))
          {
            ...call,
            'request': {
              ..._map(call['request']),
              'messages': currentMessages(_map(call['request'])['messages']),
            },
          },
      ],
      'agentHistoryAfterTurn': currentMessages(row['agentHistoryAfterTurn']),
    },
  ]);
}

/// Strict retained-version comparison. Only the derived top-level check cache
/// may change; plan/dose/list order and every other key remain immutable.
List<String> scopeEvaluationVersionFailures({
  required String? planId,
  required List<ScopeEvaluationJson> baseline,
  required List<ScopeEvaluationJson> current,
  required bool requireAppend,
  ScopeEvaluationJson? deliveredPlan,
}) {
  if (planId == null || planId.isEmpty || baseline.isEmpty) {
    return ['missing_nonempty_version_baseline'];
  }
  final failures = <String>[];
  Object? immutable(ScopeEvaluationJson version) => _canonicalJson({
    for (final entry in version.entries)
      if (entry.key != 'check') entry.key: entry.value,
  });
  for (final versions in [baseline, current]) {
    for (var index = 0; index < versions.length; index++) {
      final version = versions[index];
      final number = version['version'];
      final estimate = version['estimateSec'];
      if (number is! int ||
          number <= 0 ||
          version['plan'] is! Map ||
          _map(version['plan'])['id'] != planId ||
          estimate is! num ||
          !estimate.isFinite ||
          estimate < 0 ||
          version['fitLog'] is! List) {
        failures.add('invalid_version_payload');
      }
      final previous = index > 0 ? versions[index - 1]['version'] : null;
      if (index > 0 &&
          (number is! int || previous is! int || number != previous + 1)) {
        failures.add('nonconsecutive_version_history');
      }
    }
  }
  if (current.length < baseline.length) {
    failures.add('retained_version_missing');
  }
  for (
    var index = 0;
    index < baseline.length && index < current.length;
    index++
  ) {
    if (immutable(baseline[index]) != immutable(current[index])) {
      failures.add('retained_version_payload_changed:$index');
    }
  }
  if (!requireAppend && current.length != baseline.length) {
    failures.add('recommendation_changed_version_count');
  }
  if (requireAppend) {
    if (current.length <= baseline.length) {
      failures.add('new_version_not_appended');
    }
    if (deliveredPlan == null || deliveredPlan['id'] != planId) {
      failures.add('delivered_plan_id_changed');
    }
    if (current.isNotEmpty) {
      final latest = current.last;
      final check = _map(latest['check']);
      if (check['ok'] != true ||
          (check.containsKey('errors') &&
              (check['errors'] is! List ||
                  (check['errors']! as List).isNotEmpty))) {
        failures.add('latest_delivered_version_not_checked');
      }
      if (_canonicalJson(latest['plan']) != _canonicalJson(deliveredPlan)) {
        failures.add('delivered_plan_differs_from_latest_version');
      }
    }
  }
  return failures.toSet().toList();
}

String _canonicalJson(Object? value) {
  Object? ordered(Object? item) {
    if (item is Map) {
      final map = _map(item);
      final keys = map.keys.toList()..sort();
      return {for (final key in keys) key: ordered(map[key])};
    }
    if (item is List) return item.map(ordered).toList();
    return item;
  }

  return jsonEncode(ordered(value));
}

/// Pure recalculation over captured public records: no Agent, key, I/O or HTTP.
/// The input is copied; archived verdicts and raw artifacts are never mutated.
ScopeEvaluationJson scopeEvaluationAuditCase(
  ScopeEvaluationJson original, {
  required ScopeEvaluationBinding binding,
  required ScopeEvaluationScenario scenario,
  required String host,
  bool retainOriginalVerdicts = false,
}) {
  final result = _map(jsonDecode(jsonEncode(original)));
  final turns = _records(result['turns']);
  final oldTurnFailures = {
    for (final turn in turns)
      for (final failure in _strings(turn['failures']))
        'turn${turn['turn']}:$failure',
  };
  final functional = <String>[
    for (final failure in _strings(result['failures']))
      if (!oldTurnFailures.contains(failure)) failure,
  ];
  final budgetFailures = <String>[];
  if (turns.length != scenario.inputs.length) {
    functional.add('missing_fixed_turn');
  }
  final first = turns.firstOrNull;
  final planId = _map(first?['plan'])['id'] as String?;
  final baseline = _records(_map(first?['plans'])[planId]);
  for (var index = 0; index < turns.length; index++) {
    final row = turns[index];
    if (retainOriginalVerdicts) row['originalFailures'] = row['failures'];
    row['toolRejections'] = scopeEvaluationTurnToolRejections(row);
    row['statistics'] = scopeEvaluationCallStatistics(
      _records(row['calls']),
      _records(row['spans']),
      _map(row['toolRejections']),
      retainedMessages: _records(row['agentHistoryAfterTurn']),
    );
    final rowFailures = _turnFailures(
      row: row,
      scenario: scenario,
      binding: binding,
      finalTurn: index == scenario.inputs.length - 1,
      host: host,
    );
    final recheckedSafety =
        scenario.safety &&
        _records(row['scopeRecords']).any(
          (record) =>
              record['kind'] == 'safetyBlocked' &&
              record['originalText'] == scenario.inputs.last,
        );
    // Recompute only known derived-verdict defects. A real safety decision or
    // missing trusted copy still fails above; original verdicts remain attached.
    rowFailures.addAll(
      _strings(row['failures']).where(
        (failure) =>
            !{
              'edit_did_not_preserve_first_plan_baseline',
              'recommendation_changed_first_plan',
              'http_call_budget_exceeded',
            }.contains(failure) &&
            !(recheckedSafety && failure == 'missing_code_verified_disclosure'),
      ),
    );
    if (index >= scenario.inputs.length ||
        row['turn'] != index + 1 ||
        row['input'] != scenario.inputs[index]) {
      rowFailures.add('fixed_turn_input_changed');
    }
    if (host == 'smartfit' && index > 0) {
      rowFailures.addAll(
        scopeEvaluationVersionFailures(
          planId: planId,
          baseline: baseline,
          current: _records(_map(row['plans'])[planId]),
          requireAppend: index == 2,
          deliveredPlan: row['plan'] == null ? null : _map(row['plan']),
        ),
      );
      if (index == 2 && row['activePlanId'] != planId) {
        rowFailures.add('active_edit_plan_id_changed');
      }
    }
    final rowBudget = <String>[
      if (_map(row['statistics'])['callBudgetPassed'] != true)
        'http_call_budget_exceeded',
    ];
    row['functionalFailures'] = rowFailures.toSet().toList();
    row['budgetFailures'] = rowBudget;
    row['functionalGatePassed'] = rowFailures.isEmpty;
    row['budgetGatePassed'] = rowBudget.isEmpty;
    row['gatePassed'] = rowFailures.isEmpty && rowBudget.isEmpty;
    row['failures'] = [..._strings(row['functionalFailures']), ...rowBudget];
    functional.addAll(
      _strings(row['functionalFailures']).map((f) => 'turn${index + 1}:$f'),
    );
    budgetFailures.addAll(rowBudget.map((f) => 'turn${index + 1}:$f'));
  }
  final calls = _records(result['calls']);
  if (calls.isEmpty) functional.add('not_a_real_model_case_no_http');
  if (calls.any((call) => call['modelMatchesRequest'] != true)) {
    functional.add('model_route_or_http_failed');
  }
  if (result['modelCalls'] != calls.length ||
      turns.fold<int>(0, (sum, row) => sum + _records(row['calls']).length) !=
          calls.length) {
    functional.add('recorded_http_count_mismatch');
  }
  final last = turns.lastOrNull;
  return {
    ...result,
    if (retainOriginalVerdicts) ...{
      'originalGatePassed': original['gatePassed'],
      'originalFailures': original['failures'],
    },
    'turns': turns,
    'finalTurnModelCalls': _map(last?['statistics'])['modelCalls'],
    'functionalGatePassed': functional.isEmpty,
    'budgetGatePassed': budgetFailures.isEmpty,
    'gatePassed': functional.isEmpty && budgetFailures.isEmpty,
    'functionalFailures': functional.toSet().toList(),
    'budgetFailures': budgetFailures.toSet().toList(),
    'failures': {...functional, ...budgetFailures}.toList(),
  };
}

/// Never treats an absent or empty plan as a passing ID-subset assertion.
List<String> scopeEvaluationPlanFailures(
  Object? rawPlan,
  ScopeEvaluationJson timing,
  Set<String> allowedIds, {
  required int targetMinutes,
}) {
  if (rawPlan == null) return ['missing_plan'];
  final decoded = const PlanCodec().decodeStrict(_map(rawPlan));
  if (!decoded.ok || decoded.plan == null) return ['invalid_plan'];
  final plan = decoded.plan!;
  if (plan.items.isEmpty) return ['empty_plan'];
  final failures = <String>[];
  if (!allowedIds.containsAll(plan.exerciseIds)) {
    failures.add('outside_plan_id');
  }
  if (plan.targetMinutes != targetMinutes ||
      timing['targetSeconds'] != targetMinutes * 60) {
    failures.add('wrong_duration_target');
  }
  if (timing['cardWithinTolerance'] != true) {
    failures.add('card_duration_failed');
  }
  if (timing['executionWithinTolerance'] != true) {
    failures.add('execution_duration_failed');
  }
  final targetSeconds = targetMinutes * 60;
  for (final field in ['cardSeconds', 'executionSeconds']) {
    final actual = timing[field];
    if (actual is! num ||
        !actual.isFinite ||
        actual < targetSeconds * .9 ||
        actual > targetSeconds * 1.1) {
      failures.add('${field}_measured_value_outside_tolerance');
    }
  }
  if (timing['timelineAssertionPassed'] != true) {
    failures.add('host_timeline_assertion_failed');
  }
  if (timing['isEstimate'] == true && timing['manualCountingLabel'] != '估算') {
    failures.add('manual_counting_not_labeled_estimate');
  }
  return failures;
}

ScopeEvaluationJson scopeEvaluationCallStatistics(
  List<ScopeEvaluationJson> calls,
  List<ScopeEvaluationJson> spans,
  ScopeEvaluationJson rejections, {
  List<ScopeEvaluationJson> retainedMessages = const [],
}) {
  ScopeEvaluationJson tokens(String key) {
    final values = [
      for (final call in calls)
        if (_map(call['usage'])[key] case final num n
            when n.isFinite && n >= 0 && n.roundToDouble() == n)
          n,
    ];
    return {
      'knownTotal': values.isEmpty
          ? null
          : values.fold<num>(0, (a, b) => a + b),
      'knownCalls': values.length,
      'unknownCalls': calls.length - values.length,
    };
  }

  final repairCount = rejections['count'] as int?;
  final httpTimes = [
    for (final call in calls)
      if (call['elapsedMs'] case final num n when n.isFinite && n >= 0) n,
  ];
  final budget = repairCount == null
      ? null
      : repairCount == 0
      ? 4
      : repairCount == 1
      ? 6
      : null;
  final spanTimes = <String, Object?>{};
  for (final kind in CoachAgentSpanKind.values) {
    final selected = spans.where((s) => s['kind'] == kind.name).toList();
    spanTimes[kind.name] = {
      'count': selected.length,
      'inclusiveMicros': selected.fold<int>(
        0,
        (sum, span) => sum + (span['elapsedMicros']! as int),
      ),
      'reasons': [
        for (final span in selected)
          if (span['reason'] != null) span['reason'],
      ],
    };
  }
  final searches = spans
      .where((s) => s['kind'] == 'tool' && s['name'] == 'search_actions')
      .toList();
  final searchIds = {
    for (final span in searches)
      if (span['toolCallId'] is String) span['toolCallId']! as String,
  };
  final searchReceipts = <String, ScopeEvaluationJson>{};
  void scanSearchReceipts(List<ScopeEvaluationJson> messages) {
    for (final message in messages) {
      final id = message['tool_call_id'];
      if (message['role'] != 'tool' ||
          id is! String ||
          !searchIds.contains(id) ||
          message['content'] is! String) {
        continue;
      }
      try {
        final receipt = _map(jsonDecode(message['content']! as String));
        if (receipt['ok'] is! bool) continue;
        // A request can repeat the same receipt many times. Prefer an actual
        // cache flag over a later compacted receipt, without counting it again.
        if (!searchReceipts.containsKey(id) || receipt['cacheHit'] is bool) {
          searchReceipts[id] = receipt;
        }
      } on FormatException {
        // A folded or unavailable result cannot prove an uncached search.
      }
    }
  }

  for (final call in calls) {
    scanSearchReceipts(_records(_map(call['request'])['messages']));
  }
  scanSearchReceipts(retainedMessages);
  var freshSearches = 0;
  var localCacheHits = 0;
  var rejectedSearches = 0;
  var deferredSearches = 0;
  var unknownSearches = 0;
  for (final span in searches) {
    final receipt = searchReceipts[span['toolCallId']];
    final attributes = _map(span['attributes']);
    final cacheHit = receipt?['cacheHit'] ?? attributes['cacheHit'];
    if (attributes['deferred'] == true ||
        receipt?['deferred'] == true ||
        receipt?['skipped'] == true ||
        {
          'skipped_after_error',
          'skipped_after_completion',
        }.contains(receipt?['code'])) {
      deferredSearches++;
    } else if (span['ok'] == false || receipt?['ok'] == false) {
      rejectedSearches++;
    } else if (cacheHit == true) {
      localCacheHits++;
    } else if (cacheHit == false) {
      freshSearches++;
    } else {
      unknownSearches++;
    }
  }
  return {
    'modelCalls': calls.length,
    'searchActionsRequested': calls.fold<int>(
      0,
      (n, c) =>
          n + _toolNames(c).where((name) => name == 'search_actions').length,
    ),
    'searchActionsAttempts': searches.length,
    'searchActionsExecuted': freshSearches,
    'searchActionsLocalCacheHits': localCacheHits,
    'searchActionsRejected': rejectedSearches,
    'searchActionsDeferred': deferredSearches,
    'searchActionsUnknown': unknownSearches,
    'searchStatisticsCoverage':
        'Attempts are completed search tool spans. Uncached executions and local '
        'cache hits require explicit receipt/cache flags, deduplicated by tool '
        'call ID. Missing flags remain unknown; rejected attempts are not '
        'assumed to have run the search service. This is separate from gateway '
        'prompt-cache token usage.',
    'maxRequestBytes': calls.isEmpty
        ? null
        : calls
              .map((c) => c['requestBytes']! as int)
              .reduce((a, b) => a > b ? a : b),
    'httpElapsedMs': httpTimes.isEmpty
        ? null
        : httpTimes.fold<num>(0, (sum, value) => sum + value),
    'httpElapsedKnownCalls': httpTimes.length,
    'httpElapsedUnknownCalls': calls.length - httpTimes.length,
    'promptTokens': tokens('prompt_tokens'),
    'completionTokens': tokens('completion_tokens'),
    'totalTokens': tokens('total_tokens'),
    'context': evaluationContextStatistics(calls),
    'toolRepairCount': repairCount,
    'callBudget': budget,
    'callBudgetPassed': budget != null && calls.length <= budget,
    'budgetClassification': repairCount == 0
        ? 'normal'
        : repairCount == 1
        ? 'one_repair'
        : 'multiple_or_unknown_repairs',
    'spans': spanTimes,
    'spanAggregation':
        'inclusive per-kind durations; nested spans are not summed into elapsed',
  };
}

String scopeEvaluationMarkdown(ScopeEvaluationJson summary) {
  final output = StringBuffer('# ${summary['host']} scope / budget real gate\n\n')
    ..writeln(
      'Fixed inputs, no resampling, no supplementary answers; failures retained. Manual phases are estimates with the same numeric dual gate.\n',
    )
    ..writeln(
      '| Case | Turn | Status | HTTP | search requested / attempts | search uncached / local hit / rejected / deferred / unknown | ms | max request B | prompt / completion / total tokens | gateway prompt-cache hit tokens / unknown calls | repair reasons | card / execution s | estimate | pass |',
    )
    ..writeln('|---|---:|---|---:|---|---|---:|---:|---|---|---|---|---|---|');
  for (final caseResult in _records(summary['cases'])) {
    for (final turn in _records(caseResult['turns'])) {
      final s = _map(turn['statistics']);
      final context = _map(s['context']);
      final timing = _map(turn['timing']);
      final codes = _map(turn['toolRejections']);
      output.writeln(
        '| ${caseResult['id']} | ${turn['turn']} | ${turn['status']} | ${s['modelCalls']} | ${s['searchActionsRequested']} / ${s['searchActionsAttempts']} | ${s['searchActionsExecuted']} / ${s['searchActionsLocalCacheHits']} / ${s['searchActionsRejected']} / ${s['searchActionsDeferred']} / ${s['searchActionsUnknown']} | ${turn['elapsedMs']} | ${s['maxRequestBytes']} | ${_map(s['promptTokens'])['knownTotal']} / ${_map(s['completionTokens'])['knownTotal']} / ${_map(s['totalTokens'])['knownTotal']} | ${_map(context['cache'])['knownHitTokensTotal']} / ${_map(context['cache'])['unknownCalls']} | ${_records(codes['entries']).map((e) => _map(e['result'])['code']).join(',')} | ${timing['cardSeconds']} / ${timing['executionSeconds']} | ${timing['isEstimate']} | ${_strings(turn['failures']).isEmpty} |',
      );
    }
  }
  output.writeln(
    '\n| Case | Turn | HTTP / tool / fit / recompile inclusive μs | Recompile reasons | Card / execution deviation % |',
  );
  output.writeln('|---|---:|---|---|---|');
  for (final caseResult in _records(summary['cases'])) {
    for (final turn in _records(caseResult['turns'])) {
      final kinds = _map(_map(turn['statistics'])['spans']);
      final timing = _map(turn['timing']);
      output.writeln(
        '| ${caseResult['id']} | ${turn['turn']} | ${_map(kinds['http'])['inclusiveMicros']} / ${_map(kinds['tool'])['inclusiveMicros']} / ${_map(kinds['fit'])['inclusiveMicros']} / ${_map(kinds['recompile'])['inclusiveMicros']} | ${_map(kinds['recompile'])['reasons']} | ${timing['cardDeviationPercent']} / ${timing['executionDeviationPercent']} |',
      );
    }
  }
  output.writeln(
    '\n| Case | Final HTTP/ms | Previous final HTTP/ms | HTTP/ms delta | Current card/execution | Functional / budget / overall |',
  );
  output.writeln('|---|---|---|---|---|---|');
  for (final row in _records(summary['cases'])) {
    final baseline = _baselineFinal[row['id']];
    final callDelta = baseline != null && row['finalTurnModelCalls'] is num
        ? (row['finalTurnModelCalls']! as num) - baseline.$1
        : null;
    final timeDelta = baseline != null && row['finalTurnElapsedMs'] is num
        ? (row['finalTurnElapsedMs']! as num) - baseline.$2
        : null;
    output.writeln(
      '| ${row['id']} | ${row['finalTurnModelCalls']} / ${row['finalTurnElapsedMs']} | ${baseline?.$1} / ${baseline?.$2} | $callDelta / $timeDelta | ${row['cardSeconds']} / ${row['executionSeconds']} | ${row['functionalGatePassed']} / ${row['budgetGatePassed']} / ${row['gatePassed']} |',
    );
  }
  output.writeln(
    '\nBaseline source: docs/reports/fit-executed-duration-20261101/results.json, SF final third turns. Maximum 9 calls and longest 29001 ms belong to different baseline cases. Unknown token/cache values stay null, never zero.\n',
  );
  output.writeln('## Retained failures\n');
  for (final row in _records(summary['cases'])) {
    for (final failure in _strings(row['failures'])) {
      output.writeln('- ${row['id']}: $failure');
    }
  }
  return output.toString();
}

ScopeEvaluationJson _withDurationDeviation(ScopeEvaluationJson timing) {
  final target = timing['targetSeconds'];
  return {
    ...timing,
    for (final prefix in ['card', 'execution'])
      '${prefix}DeviationPercent':
          target is num && target > 0 && timing['${prefix}Seconds'] is num
          ? ((timing['${prefix}Seconds']! as num) - target) / target * 100
          : null,
  };
}

const _baselineFinal = <String, (int, int)>{
  'five-1': (9, 23122),
  'five-2': (5, 15876),
  'five-3': (4, 15103),
  'five-4': (7, 21019),
  'five-5': (8, 29001),
  'ten-1': (5, 15601),
  'twenty-1': (8, 28592),
};

String scopeEvaluationSourceFingerprint(String sdkRoot) {
  final files = <File>[];
  for (final relative in [
    'lib',
    'packages/ugk_trainer/lib',
    'packages/ugk_trainer_runtime/lib',
  ]) {
    files.addAll(
      Directory('$sdkRoot/$relative')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
    );
  }
  for (final relative in [
    'tool/eval_coach_scope_guard.dart',
    'tool/coach_scope_guard_evaluation.dart',
    'tool/executed_duration_host_timing.dart',
  ]) {
    final file = File('$sdkRoot/$relative');
    if (file.existsSync()) files.add(file);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return sha256
      .convert(
        utf8.encode(
          files
              .map(
                (f) =>
                    '${f.path.substring(sdkRoot.length)}:${sha256.convert(f.readAsBytesSync())}',
              )
              .join('\n'),
        ),
      )
      .toString();
}

TrainingPlan _samplePlan(Catalog catalog) {
  final drill = catalog.drills.first;
  final dose = drill.defaultDose;
  return TrainingPlan(
    id: 'scope-dry',
    source: 'evaluation',
    title: 'Scope dry timeline',
    goal: 'relax',
    scene: 'home',
    level: 1,
    targetMinutes: 5,
    blocks: [
      PlanBlock(
        id: 'main',
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
}

bool _hostUnchanged(ScopeEvaluationJson provenance) =>
    _map(provenance['filesSha256']).entries.every(
      (entry) =>
          File(entry.key).existsSync() &&
          sha256.convert(File(entry.key).readAsBytesSync()).toString() ==
              entry.value,
    );
String _head(String root) {
  final result = Process.runSync('git', ['-C', root, 'rev-parse', 'HEAD']);
  if (result.exitCode != 0) {
    throw StateError('Cannot identify evaluation source');
  }
  return (result.stdout as String).trim();
}

List<String> _toolNames(ScopeEvaluationJson call) => [
  for (final choice in _records(_map(call['response'])['choices']))
    for (final tool in _records(_map(choice['message'])['tool_calls']))
      if (_map(tool['function'])['name'] case final String name) name,
];
Iterable<String> _jsonStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map) {
    for (final entry in value.entries) {
      yield entry.key.toString();
      yield* _jsonStrings(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      yield* _jsonStrings(item);
    }
  }
}

ScopeEvaluationJson _map(Object? value) =>
    value is Map ? value.map((k, v) => MapEntry(k.toString(), v)) : {};
List<ScopeEvaluationJson> _records(Object? value) =>
    value is List ? value.map(_map).toList() : [];
List<String> _strings(Object? value) => value is List<String>
    ? value
    : value is List
    ? value.whereType<String>().toList()
    : [];
Future<void> _writeJson(File file, Object? value) => file.writeAsString(
  '${const JsonEncoder.withIndent('  ').convert(value)}\n',
);
