/// Content-free measurements made from real serialized HTTP request bodies.
library;

import 'dart:convert';

import 'package:ugk_coach/src/agent/context_budget.dart';

typedef ContextStatJson = Map<String, Object?>;
const evaluationTailStatePrefix = '当前状态（系统生成）：';

ContextStatJson _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : {};
List<Object?> _list(Object? value) => value is List ? value : [];
int _lcp(List<int> a, List<int> b) {
  var at = 0;
  while (at < a.length && at < b.length && a[at] == b[at]) {
    at++;
  }
  return at;
}

/// Previous private reasoning remains in memory solely for exact comparisons.
/// Returned diagnostics contain counts/booleans, never message/reasoning text.
class EvaluationContextTracker {
  List<int>? _previousBody;
  List<String>? _previousHistory;
  String? _previousSystems, _previousTools;
  int? _previousEpoch;

  ContextStatJson observe(
    List<int> bodyBytes, {
    ContextStatJson? sdkDiagnostics,
  }) {
    final body = _map(jsonDecode(utf8.decode(bodyBytes)));
    final messages = _list(body['messages']).map(_map).toList();
    final tail = messages.lastOrNull;
    final content = tail?['content'];
    final hasTail =
        tail?['role'] == 'user' &&
        content is String &&
        content.startsWith(evaluationTailStatePrefix);
    var systemEnd = 0;
    while (systemEnd < messages.length &&
        messages[systemEnd]['role'] == 'system') {
      systemEnd++;
    }
    final systems = jsonEncode(messages.take(systemEnd).toList());
    final tools = jsonEncode({
      'present': body.containsKey('tools'),
      'value': body['tools'],
    });
    final history = messages
        .sublist(systemEnd, messages.length - (hasTail ? 1 : 0))
        .map(jsonEncode)
        .toList();
    final previous = _previousHistory;
    var messageLcp = 0;
    if (previous != null) {
      while (messageLcp < previous.length &&
          messageLcp < history.length &&
          previous[messageLcp] == history[messageLcp]) {
        messageLcp++;
      }
    }
    final epoch = sdkDiagnostics?['epoch'] as int?;
    final completed = sdkDiagnostics?['completedTurnsFolded'] as int?;
    final receipts = sdkDiagnostics?['receiptBodiesFolded'] as int?;
    final foldType = completed == null || receipts == null
        ? 'unknown'
        : completed > 0 && receipts > 0
        ? 'completed_turns_and_receipt_bodies'
        : completed > 0
        ? 'completed_turns'
        : receipts > 0
        ? 'receipt_bodies'
        : 'none';
    final after = sdkDiagnostics?['afterBytes'];
    final sameEpoch = _previousEpoch == null || epoch == null
        ? null
        : epoch == _previousEpoch;
    final systemsEqual = _previousSystems == null
        ? null
        : systems == _previousSystems;
    final toolsEqual = _previousTools == null ? null : tools == _previousTools;
    final historyPreserved = previous == null
        ? null
        : messageLcp == previous.length;
    final violations = <String>[
      if (systemsEqual == false) 'system_messages',
      if (toolsEqual == false) 'tools',
      if (historyPreserved == false) 'history_messages',
    ];
    final prefixValidation = _previousBody == null
        ? <String, Object?>{'status': 'unknown', 'reason': 'first_request'}
        : sameEpoch == null || foldType == 'unknown'
        ? <String, Object?>{
            'status': 'unknown',
            'reason': 'SDK epoch or fold observation unavailable',
          }
        : sameEpoch == false
        ? <String, Object?>{
            'status': 'not_applicable',
            'reason': 'epoch_changed_including_privacy_invalidation',
          }
        : foldType != 'none'
        ? <String, Object?>{
            'status': 'not_applicable',
            'reason': 'explicit_context_fold',
          }
        : <String, Object?>{
            'status': violations.isEmpty ? 'pass' : 'fail',
            'violations': violations,
          };
    final result = <String, Object?>{
      'measurement': 'actual_http_request_body_utf8',
      'wireRequestBytes': bodyBytes.length,
      'previousWireRequestBytes': _previousBody?.length,
      'fullJsonLcpBytes': _previousBody == null
          ? null
          : _lcp(_previousBody!, bodyBytes),
      'systemsEqual': systemsEqual,
      'toolsEqual': toolsEqual,
      'historyMessageCount': history.length,
      'previousHistoryMessageCount': previous?.length,
      'historyMessagesLcpCount': previous == null ? null : messageLcp,
      'historyPrefixFullyPreserved': historyPreserved,
      'prefixValidation': prefixValidation,
      'historyComparison':
          'complete message JSON including reasoning fields; leading system messages and exact trailing generated state excluded',
      'tailState': {
        'observed': hasTail,
        'contentBytes': hasTail ? utf8.encode(content).length : null,
        'serializedMessageBytes': hasTail
            ? utf8.encode(jsonEncode(tail)).length
            : null,
      },
      'epochChanged': _previousEpoch == null || epoch == null
          ? null
          : epoch != _previousEpoch,
      'foldType': foldType,
      'sdkDiagnostics': sdkDiagnostics == null
          ? null
          : {
              for (final key in [
                'sdkDiagnosticIndex',
                'epoch',
                'beforeBytes',
                'afterBytes',
                'softLimitBytes',
                'hardLimitBytes',
                'tailStateBytes',
                'completedTurnsFolded',
                'receiptBodiesFolded',
                'folded',
                'measurement',
                'fitsHardLimit',
              ])
                if (sdkDiagnostics.containsKey(key)) key: sdkDiagnostics[key],
            },
      'wireMinusSdkAfterBytes': after is num ? bodyBytes.length - after : null,
    };
    _previousBody = List<int>.of(bodyBytes);
    _previousHistory = history;
    _previousSystems = systems;
    _previousTools = tools;
    _previousEpoch = epoch;
    return result;
  }
}

int? _tokens(Object? value) =>
    value is num &&
        value.isFinite &&
        value >= 0 &&
        value.roundToDouble() == value
    ? value.toInt()
    : null;

ContextStatJson evaluationCacheObservation(Object? rawUsage) {
  final usage = _map(rawUsage);
  final primary = _tokens(usage['prompt_cache_hit_tokens']);
  final fallback = _tokens(
    _map(usage['prompt_tokens_details'])['cached_tokens'],
  );
  final hits = primary ?? fallback;
  final prompt = _tokens(usage['prompt_tokens']);
  return {
    'status': hits == null ? 'unknown' : 'known',
    'hitTokens': hits,
    'source': primary != null
        ? 'usage.prompt_cache_hit_tokens'
        : fallback != null
        ? 'usage.prompt_tokens_details.cached_tokens'
        : 'unknown',
    'promptTokens': prompt,
    'hitFraction': hits != null && prompt != null && prompt > 0
        ? hits / prompt
        : null,
  };
}

ContextStatJson evaluationRequestBudget(
  int bytes, {
  required bool thinking,
  ContextBudgetConfig config = const ContextBudgetConfig(),
}) => {
  'measurement': 'actual_http_request_body_utf8',
  'requestBytes': bytes,
  'softLimitBytes': config.softLimit(thinking: thinking),
  'hardLimitBytes': config.hardBytes,
  'softExceeded': bytes > config.softLimit(thinking: thinking),
  'hardExceeded': bytes > config.hardBytes,
  'status': bytes > config.hardBytes
      ? 'hard_limit_exceeded'
      : bytes > config.softLimit(thinking: thinking)
      ? 'above_soft_current_turn_allowed'
      : 'within_soft',
};

ContextStatJson evaluationContextStatistics(List<ContextStatJson> calls) {
  final caches = [
    for (final call in calls)
      call['cacheObservation'] is Map
          ? _map(call['cacheObservation'])
          : evaluationCacheObservation(call['usage']),
  ];
  final known = [
    for (final cache in caches)
      if (cache['status'] == 'known' && _tokens(cache['hitTokens']) != null)
        _tokens(cache['hitTokens'])!,
  ];
  final contexts = [for (final call in calls) _map(call['contextStats'])];
  int? maximum(Iterable<Object?> raw) {
    final values = raw.whereType<num>().toList();
    return values.isEmpty
        ? null
        : values.reduce((a, b) => a > b ? a : b).toInt();
  }

  return {
    'cache': {
      'knownCalls': known.length,
      'unknownCalls': calls.length - known.length,
      'knownHitTokensTotal': known.isEmpty
          ? null
          : known.reduce((a, b) => a + b),
      'coverage': known.isEmpty
          ? 'unknown'
          : known.length == calls.length
          ? 'complete'
          : 'partial',
      'limitation':
          'Unknown cache data is not zero; totals cover only calls with reported cache tokens.',
    },
    'fullJsonLcpMaxBytes': maximum(
      contexts.map((context) => context['fullJsonLcpBytes']),
    ),
    'prefixCompleteObservations': contexts
        .where((c) => c['historyPrefixFullyPreserved'] == true)
        .length,
    'prefixChangedObservations': contexts
        .where((c) => c['historyPrefixFullyPreserved'] == false)
        .length,
    'prefixUnknownObservations': contexts
        .where((c) => c['historyPrefixFullyPreserved'] == null)
        .length,
    'prefixArchitectureFailures': contexts
        .where((c) => _map(c['prefixValidation'])['status'] == 'fail')
        .length,
    'foldedRequestObservations': contexts
        .where(
          (c) => const {
            'completed_turns',
            'receipt_bodies',
            'completed_turns_and_receipt_bodies',
          }.contains(c['foldType']),
        )
        .length,
    'maxTailStateContentBytes': maximum(
      contexts.map((c) => _map(c['tailState'])['contentBytes']),
    ),
    'maxTailStateSerializedBytes': maximum(
      contexts.map((c) => _map(c['tailState'])['serializedMessageBytes']),
    ),
    'softExceededRequests': calls
        .where((call) => _map(call['requestBudget'])['softExceeded'] == true)
        .length,
    'hardExceededRequests': calls
        .where((call) => _map(call['requestBudget'])['hardExceeded'] == true)
        .length,
  };
}
