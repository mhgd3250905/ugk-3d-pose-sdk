/// Read existing thinking on/off evidence. This tool has no HTTP client and
/// never modifies either evaluation input or runs a model.
library;

import 'dart:convert';
import 'dart:io';

import 'eval_turn_budget.dart';

typedef ComparisonJson = Map<String, Object?>;

ComparisonJson _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : {};
List<Object?> _list(Object? value) => value is List ? value : [];

List<ComparisonJson> _records(Object? value) => _list(value).map(_map).toList();

Set<String> _deliveredIds(ComparisonJson turn) {
  final result = <String>{
    for (final action in _records(turn['actions']))
      if (action['id'] is String) action['id'] as String,
  };
  void visit(Object? value) {
    if (value is Map) {
      if (value['exerciseId'] is String) {
        result.add(value['exerciseId'] as String);
      }
      for (final child in value.values) {
        visit(child);
      }
    } else if (value is List) {
      for (final child in value) {
        visit(child);
      }
    }
  }

  visit(turn['plan']);
  return result;
}

ComparisonJson _durationQuality(List<ComparisonJson> turns) {
  final plans = <ComparisonJson>[];
  for (final turn in turns) {
    final plan = _map(turn['plan']);
    if (plan.isEmpty) continue;
    final cardTarget = plan['targetMinutes'];
    final ledgerValue = _map(_map(turn['params'])['minutes'])['value'];
    final ledgerMinutes = ledgerValue is num && ledgerValue > 0
        ? ledgerValue
        : null;
    final target = ledgerMinutes ?? cardTarget;
    final targetMatchesLedger = ledgerMinutes != null && cardTarget is num
        ? cardTarget == ledgerMinutes
        : null;
    final seconds = turn['estimatedPlanSeconds'];
    final error = target is num && target > 0 && seconds is num
        ? (seconds / 60 - target).abs() / target * 100
        : null;
    final withinTenPercent = error == null ? null : error <= 10;
    final status = ledgerMinutes == null
        ? 'manual_review'
        : targetMatchesLedger == false || withinTenPercent == false
        ? 'fail'
        : targetMatchesLedger == null || withinTenPercent == null
        ? 'manual_review'
        : 'pass';
    plans.add({
      'turn': turn['turn'],
      'acceptedLedgerMinutes': ledgerMinutes,
      'cardTargetMinutes': cardTarget,
      'targetMatchesLedger': targetMatchesLedger,
      'comparisonTargetMinutes': target,
      'comparisonBasis': ledgerMinutes == null
          ? 'card-only-unverified'
          : 'accepted-ledger',
      'estimatedSeconds': seconds,
      'errorPercent': error,
      'withinTenPercent': withinTenPercent,
      'status': status,
    });
  }
  return {
    'status': plans.isEmpty
        ? 'not_observed'
        : plans.any((plan) => plan['status'] == 'fail')
        ? 'fail'
        : plans.any((plan) => plan['status'] == 'manual_review')
        ? 'manual_review'
        : 'pass',
    'plans': plans,
  };
}

ComparisonJson _equipmentQuality(List<ComparisonJson> turns) {
  final checks = <ComparisonJson>[];
  for (final turn in turns) {
    if (_map(turn['plan']).isEmpty && _list(turn['actions']).isEmpty) continue;
    final parameter = _map(_map(turn['params'])['equipment']);
    final rawAllowed = parameter['value'];
    final facts = _records(turn['actionFacts']);
    final deliveredIds = _deliveredIds(turn);
    final allowed = _list(rawAllowed).whereType<String>().toSet();
    final required = <String>{
      for (final fact in facts)
        for (final id in _list(fact['equipment']).whereType<String>())
          if (id.isNotEmpty && id != 'none') 'equip.${id.replaceAll('-', '_')}',
    };
    final source = parameter['source'];
    // A nonempty preselection has no independent proof of current consent.
    // Retain that uncertainty instead of turning missing data into a pass.
    final comparable =
        rawAllowed is List &&
        rawAllowed.every((value) => value is String) &&
        (source == 'user' ||
            source == 'host' ||
            (source == 'default' || source == 'preselect') &&
                allowed.isEmpty) &&
        facts.isNotEmpty &&
        deliveredIds.isNotEmpty &&
        facts.map((fact) => fact['id']).toSet().containsAll(deliveredIds) &&
        facts.every(
          (fact) =>
              fact['equipment'] is List &&
              (fact['equipment'] as List).every((item) => item is String),
        ) &&
        allowed.every((code) => code.startsWith('equip.')) &&
        !allowed.any((code) => code.startsWith('equip.host.'));
    final compliant = comparable ? allowed.containsAll(required) : null;
    checks.add({
      'turn': turn['turn'],
      'ledgerSource': source,
      'allowedCodes': rawAllowed,
      'requiredCodes': required.toList()..sort(),
      'withinConfirmedLedger': compliant,
      'status': compliant == null
          ? 'manual_review'
          : compliant
          ? 'pass'
          : 'fail',
      'basis':
          'Catalogue action equipment compared with the accepted ledger; correctness of source quotation still needs transcript review.',
    });
  }
  return {
    'status': checks.isEmpty
        ? 'not_observed'
        : checks.any((check) => check['status'] == 'fail')
        ? 'fail'
        : checks.any((check) => check['status'] == 'manual_review')
        ? 'manual_review'
        : 'pass',
    'checks': checks,
  };
}

List<ComparisonJson> _acceptedParameterReceipts(List<ComparisonJson> calls) {
  final result = <ComparisonJson>[];
  final seen = <String>{};
  for (final call in calls) {
    final names = <Object?, Object?>{};
    for (final message in _records(_map(call['request'])['messages'])) {
      for (final tool in _records(message['tool_calls'])) {
        names[tool['id']] = _map(tool['function'])['name'];
      }
      if (message['role'] != 'tool' ||
          names[message['tool_call_id']] != 'set_params') {
        continue;
      }
      try {
        final body = _map(jsonDecode(message['content'] as String));
        if (body['ok'] != true) continue;
        final key = jsonEncode([message['tool_call_id'], body['params']]);
        if (seen.add(key)) {
          result.add({
            'toolCallId': message['tool_call_id'],
            'params': body['params'],
          });
        }
      } on FormatException {
        // Archived results are not fresh successful receipts.
      }
    }
  }
  return result;
}

ComparisonJson _case(ComparisonJson value) {
  final turns = _records(value['turns']);
  final events = _records(value['events']);
  final calls = _records(value['calls']);
  final statistics = _map(value['callStatistics']);
  final maxBytes = [
    for (final call in calls)
      if (call['requestBytes'] is num) call['requestBytes'] as num,
  ];
  final dialogue = [
    for (final turn in turns)
      {
        'turn': turn['turn'],
        'origin': turn['origin'],
        'thinkingMode': turn['thinkingMode'] ?? value['thinkingMode'],
        'task': turn['turn'] is int
            ? evaluationTurnTaskType(
                turn: turn['turn'] as int,
                events: events,
                calls: _records(turn['calls']),
              )
            : 'unknown',
        'user': turn['user'],
        'assistant': turn['assistant'],
        'question': turn['question'],
        'plan': turn['plan'],
        'actions': turn['actions'],
        'finalParamsSnapshot': turn['params'],
        'finalTaskSnapshot': turn['task'],
      },
  ];
  final stamps = [
    for (final event in events)
      if (_map(event['node'])['stamp'] is String)
        {
          'turn': event['turn'],
          'caseElapsedMs': event['caseElapsedMs'],
          'node': event['node'],
        },
  ];
  return {
    'id': value['id'],
    'caseValidity': value['caseValidity'] ?? 'unknown',
    'automatedFailures': value['automatedFailures'],
    'modelMismatches': value['modelMismatches'],
    'metrics': {
      'modelCalls': value['modelCalls'],
      'elapsedMs': value['elapsedMs'],
      'maxRequestBytes':
          statistics['maxRequestBytes'] ??
          (maxBytes.isEmpty ? null : maxBytes.reduce((a, b) => a > b ? a : b)),
      'tokensKnownTotal': _map(statistics['totalTokens'])['knownTotal'],
      'tokenUnknownCalls': _map(statistics['totalTokens'])['unknownCalls'],
      'p50Ms': statistics['p50Ms'],
      'p90Ms': statistics['p90Ms'],
      'reasoningReplayUtf8Bytes': statistics['reasoningReplayUtf8Bytes'],
    },
    'quality': {
      'planDurationError': _durationQuality(turns),
      'equipmentCompliance': _equipmentQuality(turns),
      'repeatedQuestions': {
        'status': 'manual_review',
        'reason':
            'Requires meaning and earlier-context comparison; no keyword inference is used.',
      },
      'parameterStampConsistency': {
        'status': 'manual_review',
        'reason':
            'Compare the actual parameter stamps, accepted tool receipts and delivered plan data. A cancelled final snapshot may be rolled back.',
      },
    },
    'originalInputs': value['originalInputs'],
    'dialogue': dialogue,
    'nodeStamps': stamps,
    'acceptedParameterReceipts': _acceptedParameterReceipts(calls),
  };
}

ComparisonJson buildThinkingComparison(ComparisonJson on, ComparisonJson off) {
  if (on['thinkingMode'] != 'on' || off['thinkingMode'] != 'off') {
    throw const FormatException(
      'Inputs must explicitly identify thinking on and off',
    );
  }
  Map<String, ComparisonJson> cases(ComparisonJson summary) {
    final records = _records(summary['cases']);
    final byId = {
      for (final record in records) record['id'].toString(): record,
    };
    if (records.length != 6 ||
        !byId.keys.toSet().containsAll(['R1', 'R2', 'R3', 'R4', 'R5', 'R6'])) {
      throw const FormatException(
        'Expected one existing result for each of R1-R6',
      );
    }
    return byId;
  }

  final onCases = cases(on);
  final offCases = cases(off);
  return {
    'mode': 'read-only-thinking-comparison',
    'modelCallsMade': 0,
    'limitations': [
      'Inputs are existing observations; no evaluation is rerun or repaired.',
      'Invalid model-route cases remain invalid; resource measurements are observations, not quality acceptance.',
      'Missing cards or quality data are not passes. Semantic checks remain explicitly pending manual review.',
    ],
    'inputCompatibility': {
      for (final field in [
        'requestedModel',
        'fixtureSha256',
        'catalogSha256',
        'semanticCatalogSha256',
        'profileSha256',
        'sourceSha256',
      ])
        field: {
          'on': on[field],
          'off': off[field],
          'match': on[field] == null || off[field] == null
              ? null
              : on[field] == off[field],
        },
    },
    'cases': [
      for (final id in ['R1', 'R2', 'R3', 'R4', 'R5', 'R6'])
        {'id': id, 'on': _case(onCases[id]!), 'off': _case(offCases[id]!)},
    ],
  };
}

String thinkingComparisonMarkdown(ComparisonJson comparison) {
  const pretty = JsonEncoder.withIndent('  ');
  final output = StringBuffer()
    ..writeln('# Thinking on/off：已有六例结果对照')
    ..writeln()
    ..writeln(
      '只读取已有结果，未调用模型。manual_review 表示待人工审阅，not_observed 表示尚未交付可核对的结果；作废案例不计为质量验收通过。',
    )
    ..writeln()
    ..writeln(
      '| 案例 | Thinking | Task | 有效性 | 调用 | 耗时 ms | 最大请求 B | 已知 token | 时长误差 | 器械 | 重复追问 | 参数 stamp |',
    )
    ..writeln('|---|---|---|---|---:|---:|---:|---:|---|---|---|---|');
  for (final entry in _records(comparison['cases'])) {
    for (final mode in ['on', 'off']) {
      final item = _map(entry[mode]);
      final metrics = _map(item['metrics']);
      final quality = _map(item['quality']);
      final duration = _map(quality['planDurationError']);
      final durationErrors = _records(duration['plans'])
          .map(
            (plan) => plan['errorPercent'] is num
                ? '${(plan['errorPercent'] as num).toStringAsFixed(1)}%'
                : 'unknown',
          )
          .join(', ');
      final taskTypes = _records(
        item['dialogue'],
      ).map((turn) => turn['task']).toSet().join(' → ');
      output.writeln(
        '| ${entry['id']} | $mode | ${taskTypes.isEmpty ? 'unknown' : taskTypes} | ${item['caseValidity']} | ${metrics['modelCalls'] ?? 'unknown'} | ${metrics['elapsedMs'] ?? 'unknown'} | ${metrics['maxRequestBytes'] ?? 'unknown'} | ${metrics['tokensKnownTotal'] ?? 'unknown'} | $durationErrors (${duration['status']}) | ${_map(quality['equipmentCompliance'])['status']} | manual_review | manual_review |',
      );
    }
  }
  output
    ..writeln()
    ..writeln('## 输入版本与条件可比性')
    ..writeln()
    ..writeln('```json')
    ..writeln(pretty.convert(comparison['inputCompatibility']))
    ..writeln('```');
  for (final entry in _records(comparison['cases'])) {
    output
      ..writeln()
      ..writeln('## ${entry['id']} 原文与节点对照');
    for (final mode in ['on', 'off']) {
      output
        ..writeln()
        ..writeln('### Thinking $mode')
        ..writeln()
        ..writeln('```json')
        ..writeln(pretty.convert(entry[mode]))
        ..writeln('```');
    }
  }
  return output.toString();
}

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/compare_coach_agent_v2.dart --on SUMMARY_OR_DIR --off SUMMARY_OR_DIR [--out NEW_DIR]\nReads existing six-case results only; never calls a model or changes the inputs.',
    );
    return;
  }
  String? argument(String flag) {
    final index = args.indexOf(flag);
    return index < 0 || index + 1 >= args.length ? null : args[index + 1];
  }

  Future<ComparisonJson> read(String? path) async {
    if (path == null) throw ArgumentError('Both --on and --off are required');
    final file = Directory(path).existsSync()
        ? File('$path/summary.json')
        : File(path);
    return _map(jsonDecode(await file.readAsString()));
  }

  final comparison = buildThinkingComparison(
    await read(argument('--on')),
    await read(argument('--off')),
  );
  final markdown = thinkingComparisonMarkdown(comparison);
  final destination = argument('--out');
  if (destination == null) {
    stdout.write(markdown);
    return;
  }
  final output = Directory(destination);
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError('Refusing to overwrite comparison output');
  }
  await output.create(recursive: true);
  await File(
    '${output.path}/comparison.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(comparison));
  await File('${output.path}/comparison.md').writeAsString(markdown);
  stdout.writeln('Read-only comparison generated; modelCallsMade=0.');
}
