/// Post-run checks based on activity actually observed during a user turn.
library;

import 'package:ugk_coach/src/agent/context_budget.dart';

typedef EvaluationRecord = Map<String, Object?>;

String? _activeType(Object? raw) {
  if (raw is! Map) return null;
  final type = raw['type'];
  if (type != 'recommend' && type != 'plan') return null;
  final nodes = raw['nodes'];
  if (nodes is! List || nodes.isEmpty) return null;
  final maps = nodes.whereType<Map<Object?, Object?>>().toList();
  // A completed task may remain attached to thinking/read events in a later
  // QA turn. Its existence does not mean this turn is doing that task.
  if (maps.any((node) => node['id'] == 'output' && node['status'] == 'done')) {
    return null;
  }
  return maps.any(
        (node) =>
            const {'pending', 'current', 'updated'}.contains(node['status']),
      )
      ? type as String
      : null;
}

String evaluationTurnTaskType({
  required int turn,
  required Iterable<EvaluationRecord> events,
  required Iterable<EvaluationRecord> calls,
}) {
  final candidates = <({double at, int order, String type})>[];
  var order = 0;
  void add(EvaluationRecord record, String taskField) {
    final index = order++;
    if (record['turn'] != turn) return;
    final time = record['caseElapsedMs'];
    if (time is! num || !time.isFinite) return;
    final type = _activeType(record[taskField]);
    if (type != null) {
      candidates.add((at: time.toDouble(), order: index, type: type));
    }
  }

  for (final event in events) {
    add(event, 'task');
  }
  for (final call in calls) {
    add(call, 'taskAtRequest');
  }
  candidates.sort((a, b) {
    final byTime = a.at.compareTo(b.at);
    return byTime != 0 ? byTime : a.order.compareTo(b.order);
  });
  return candidates.lastOrNull?.type ?? 'qa';
}

List<String> evaluationTurnBudgetFailures({
  required int turn,
  required int elapsedMs,
  required List<EvaluationRecord> calls,
  required Iterable<EvaluationRecord> events,
  ContextBudgetConfig contextBudgetConfig = const ContextBudgetConfig(),
}) {
  final type = evaluationTurnTaskType(turn: turn, events: events, calls: calls);
  final failures = <String>[];
  if (type == 'plan' || type == 'recommend') {
    final maxCalls = type == 'plan' ? 8 : 5;
    final maxMs = type == 'plan' ? 60000 : 25000;
    if (calls.length > maxCalls) {
      failures.add('turn $turn exceeds $maxCalls calls');
    }
    if (elapsedMs > maxMs) {
      failures.add('turn $turn exceeds $maxMs ms');
    }
  }
  if (calls.any(
    (call) =>
        call['requestBytes'] is num &&
        (call['requestBytes'] as num) > contextBudgetConfig.hardBytes,
  )) {
    failures.add(
      'turn $turn actual request exceeds hard limit ${contextBudgetConfig.hardBytes}B',
    );
  }
  return failures;
}
