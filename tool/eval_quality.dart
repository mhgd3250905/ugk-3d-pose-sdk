/// Shared read-only interpretation of captured evaluation evidence.
library;

import 'dart:convert';

import 'package:ugk_coach/ugk_coach.dart';

typedef EvaluationJson = Map<String, Object?>;
EvaluationJson _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : {};
List<Object?> _list(Object? value) => value is List ? value : [];
List<EvaluationJson> _records(Object? value) => _list(value).map(_map).toList();

/// Reports captured advisory emissions separately from warnings on the card.
/// Replayed receipts and nested copies of the same check are counted once.
EvaluationJson evaluationWarningSummary(List<EvaluationJson> turns) {
  final emitted = <String, EvaluationJson>{};
  final delivered = <String, EvaluationJson>{};
  final recordedCodes = <String>{};
  void scan(Object? messages, Object? turn) {
    for (final message in _records(messages)) {
      if (message['role'] != 'tool' || message['content'] is! String) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(message['content'] as String);
      } on FormatException {
        continue;
      }
      final receipt = _map(decoded);
      for (final source in [receipt, _map(receipt['check'])]) {
        for (final warning in _records(source['warningDetails'])) {
          if (warning['code'] is! String) continue;
          final key = '${message['tool_call_id']}:${warning['code']}';
          emitted.putIfAbsent(
            key,
            () => {
              'turnObserved': turn,
              'toolCallId': message['tool_call_id'],
              ...warning,
            },
          );
        }
      }
    }
  }

  for (final turn in turns) {
    recordedCodes.addAll(
      _list(turn['emittedWarningCodes']).whereType<String>(),
    );
    for (final call in _records(turn['calls'])) {
      scan(_map(call['request'])['messages'], turn['turn']);
    }
    scan(turn['agentHistoryAfterTurn'], turn['turn']);
    for (final warning in _records(turn['warnings'])) {
      final key = '${warning['code']}:${warning['message']}';
      delivered.putIfAbsent(key, () => {'turn': turn['turn'], ...warning});
    }
  }
  return {
    'advisoryEmissions': emitted.values.toList(),
    'advisoryEmissionCount': emitted.length,
    'recordedAdvisoryCodes': recordedCodes.toList(),
    'advisoryCodes': emitted.values.map((w) => w['code']).toSet().toList(),
    'deliveredWarnings': delivered.values.toList(),
    'deliveredWarningCount': delivered.length,
    'limitation':
        'Advisories are exact captured emissions, deduplicated by tool_call_id and code; final card copies are separate. Missing terminal receipts are not guessed.',
  };
}

/// Reads captured catalogue codes; never infers targets from user prose.
EvaluationJson evaluationBodyTargetQuality(List<EvaluationJson> turns) {
  final checks = <EvaluationJson>[];
  for (final turn in turns) {
    final plan = _map(turn['plan']);
    final actions = _records(turn['actions']);
    if (plan.isEmpty && actions.isEmpty) continue;
    final goals = _list(
      _map(_map(turn['params'])['goal'])['value'],
    ).whereType<String>().where((v) => v.startsWith('body.')).toList();
    if (goals.isEmpty) {
      checks.add({
        'turn': turn['turn'],
        'status': 'not_applicable',
        'reason': 'No body.* goal in the recorded ledger.',
      });
      continue;
    }
    final ids = <String>[
      if (plan.isEmpty)
        for (final action in actions) action['id'] as String,
      if (plan.isNotEmpty)
        for (final block in _records(plan['blocks']))
          if (block['type'] == 'main' || block['type'] == 'circuit')
            for (final item in _records(block['items']))
              if (_records(item['segments']).isEmpty)
                item['exerciseId'] as String
              else
                for (final segment in _records(item['segments']))
                  segment['exerciseId'] as String,
    ];
    final facts = {
      for (final fact in _records(turn['actionFacts'])) fact['id']: fact,
    };
    final expanded = _list(
      turn['expandedBodyGoalCodes'],
    ).whereType<String>().toSet();
    final known =
        expanded.containsAll(goals) &&
        ids.every((id) => facts[id]?['tags'] is List);
    final matched = [
      for (final id in ids)
        if (_list(
          facts[id]?['tags'],
        ).whereType<String>().any(expanded.contains))
          id,
    ];
    final threshold = plan.isEmpty
        ? 1.0
        : (turn['bodyFocusMinRatio'] as num? ?? .5);
    final ratio = ids.isEmpty ? 0.0 : matched.length / ids.length;
    checks.add({
      'turn': turn['turn'],
      'kind': plan.isEmpty ? 'recommend' : 'main',
      'goals': goals,
      'expandedGoals': expanded.toList(),
      'matchedIds': known ? matched : null,
      'matched': known ? matched.length : null,
      'total': ids.length,
      'requiredRatio': threshold,
      'status': !known
          ? 'manual_review'
          : ratio >= threshold && ids.isNotEmpty
          ? 'pass'
          : 'fail',
    });
  }
  return {
    'checks': checks,
    'status': checks.isEmpty
        ? 'not_observed'
        : checks.any((c) => c['status'] == 'fail')
        ? 'fail'
        : checks.any((c) => c['status'] == 'manual_review')
        ? 'manual_review'
        : checks.every((c) => c['status'] == 'not_applicable')
        ? 'not_applicable'
        : 'pass',
  };
}

Set<String> evaluationDeliveredIds(EvaluationJson turn) {
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

EvaluationJson evaluationEquipmentQuality(
  List<EvaluationJson> turns, {
  List<String>? expectedEquipment,
}) {
  final checks = <EvaluationJson>[];
  for (final turn in turns) {
    if (_map(turn['plan']).isEmpty && _list(turn['actions']).isEmpty) continue;
    final parameter = _map(_map(turn['params'])['equipment']);
    final rawAllowed = expectedEquipment == null
        ? parameter['value']
        : [
            for (final code in expectedEquipment)
              if (code.isNotEmpty && code != 'none')
                code.startsWith('equip.')
                    ? code
                    : 'equip.${code.replaceAll('-', '_')}',
          ];
    final source = expectedEquipment == null ? parameter['source'] : 'user';
    final ambient = _list(
      turn['ambientEquipmentCodes'],
    ).whereType<String>().toSet();
    final excluded = _list(
      _map(_map(turn['params'])['equipment_exclude'])['value'],
    ).whereType<String>().toSet();
    final allowed = {
      ..._list(rawAllowed).whereType<String>(),
      ...ambient,
    }.difference(excluded.intersection(ambient));
    final facts = _records(turn['actionFacts']);
    final deliveredIds = evaluationDeliveredIds(turn);
    final required = <String>{
      for (final fact in facts)
        for (final id in _list(fact['equipment']).whereType<String>())
          if (id.isNotEmpty && id != 'none') 'equip.${id.replaceAll('-', '_')}',
    };
    final comparable =
        rawAllowed is List &&
        rawAllowed.every((value) => value is String) &&
        (source == 'user' ||
            source == 'host' ||
            (source == 'default' || source == 'preselect') &&
                rawAllowed.isEmpty) &&
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
      'ambientCodes': ambient.toList()..sort(),
      'excludedCodes': excluded.toList()..sort(),
      'effectiveAllowedCodes': allowed.toList()..sort(),
      'requiredCodes': required.toList()..sort(),
      'withinConfirmedLedger': compliant,
      'status': compliant == null
          ? 'manual_review'
          : compliant
          ? 'pass'
          : 'fail',
      'basis': expectedEquipment == null
          ? 'Catalogue requirements checked against ledger plus ambient minus exclusions; source semantics require transcript review.'
          : 'Catalogue requirements checked against fixture equipment plus ambient minus exclusions.',
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

List<EvaluationJson> evaluationMissingEnglishNames(
  CoachProfile profile,
  Catalog catalog,
) => [
  for (final drill in profile.scope(catalog))
    if (drill.name.values['en']?.trim().isNotEmpty != true)
      {'id': drill.id, 'name': drill.name.values['zh'] ?? drill.name.of('zh')},
];

List<EvaluationJson> evaluationRequestedEnglishNameChecks(
  CoachProfile profile,
  Catalog catalog, {
  List<String> ids = const [
    'h-bilateral-upper-back-hug',
    'h-overhead-triceps-stretch',
  ],
}) => [
  for (final id in ids)
    {
      'id': id,
      'status': catalog[id] == null
          ? 'missing_from_catalog'
          : catalog[id]!.name.values['en']?.trim().isNotEmpty == true
          ? 'present_translated'
          : 'present_missing_en',
      'inProfileScope':
          catalog[id] != null && profile.select.matches(catalog[id]!),
      'nameZh': catalog[id]?.name.values['zh'],
      'nameEn': catalog[id]?.name.values['en'],
    },
];

/// Only actual ok:false receipts count. A missing receipt is never guessed.
EvaluationJson evaluationToolRejections(List<EvaluationJson> turns) {
  final tools = <String, EvaluationJson>{};
  final observed = <String>{};
  final rejected = <String, EvaluationJson>{};
  final skipped = <String>{};
  void register(Object? raw, Object? turn) {
    final call = _map(raw);
    if (call['id'] is! String) return;
    tools[call['id'] as String] = {'turn': turn, ...call};
  }

  for (final turn in turns) {
    for (final call in _records(turn['calls'])) {
      for (final choice in _records(_map(call['response'])['choices'])) {
        for (final tool in _list(_map(choice['message'])['tool_calls'])) {
          register(tool, turn['turn']);
        }
      }
    }
  }
  void scan(Object? rawMessages, Object? turn) {
    for (final message in _records(rawMessages)) {
      for (final call in _list(message['tool_calls'])) {
        register(call, turn);
      }
      if (message['role'] != 'tool' ||
          message['tool_call_id'] is! String ||
          message['content'] is! String) {
        continue;
      }
      final id = message['tool_call_id'] as String;
      try {
        final result = _map(jsonDecode(message['content'] as String));
        if (result['ok'] is! bool) continue;
        observed.add(id);
        if (result['ok'] != false) continue;
        if ({
          'skipped_after_error',
          'skipped_after_completion',
        }.contains(result['code'])) {
          skipped.add(id);
          continue;
        }
        final function = _map(tools[id]?['function']);
        rejected.putIfAbsent(
          id,
          () => {
            'turnObserved': turn,
            'toolCallId': id,
            'name': function['name'],
            'arguments': function['arguments'],
            'result': result,
          },
        );
      } on FormatException {
        // Archived lines do not expose a fresh result receipt.
      }
    }
  }

  for (final turn in turns) {
    for (final call in _records(turn['calls'])) {
      scan(_map(call['request'])['messages'], turn['turn']);
    }
    scan(turn['agentHistoryAfterTurn'], turn['turn']);
  }
  final usageComplete = turns.every((turn) => turn['toolUsageRecords'] is List);
  final failures = <String, EvaluationJson>{};
  for (final turn in turns) {
    for (final record in _records(turn['toolUsageRecords'])) {
      final codes = _list(record['issueCodes'])
          .whereType<String>()
          .where(
            (code) => !{
              'canary_leak',
              'skipped_after_error',
              'skipped_after_completion',
            }.contains(code),
          )
          .toList();
      if (record['hadToolCalls'] != true ||
          !{'toolStep', 'rejected'}.contains(record['outcome']) ||
          codes.isEmpty) {
        continue;
      }
      final id = record['id'];
      if (id is! String || id.isEmpty) continue;
      failures.putIfAbsent(
        id,
        () => {'turn': turn['turn'], 'usageRecordId': id, 'issueCodes': codes},
      );
    }
  }
  return {
    'count': usageComplete ? failures.length : null,
    'observedCount': rejected.length,
    'coverage': usageComplete
        ? 'usage-records-first-failure-per-batch'
        : 'observed-lower-bound',
    'usageRecordFailures': failures.values.toList(),
    'skippedBatchCallsObserved': skipped.length,
    'entries': rejected.values.toList(),
    'unobservedToolCalls': [
      for (final entry in tools.entries)
        if (!observed.contains(entry.key))
          {
            'toolCallId': entry.key,
            'turn': entry.value['turn'],
            'name': _map(entry.value['function'])['name'],
          },
    ],
    'limitation': usageComplete
        ? 'Total counts failed tool batches from usage records; each failed batch executes one failing tool and skips later calls. Receipt details can remain unavailable for a final rolled-back result.'
        : 'Counts only captured ok:false tool receipts, excluding skipped_after_error. Final tool results absent from a later request or retained history remain unknown.',
  };
}
