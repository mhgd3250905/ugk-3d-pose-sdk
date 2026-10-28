/// An append-only model journal; the UI history is deliberately separate.
library;

import 'dart:collection';
import 'dart:convert';

import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../profile/coach_profile.dart';
import 'action_search.dart';
import 'context_budget.dart';
import 'context_turn_ledger.dart';
import 'session_state.dart';

class AppendOnlyPreparedContext {
  const AppendOnlyPreparedContext(this.request, this.diagnostics);
  final LlmRequest request;
  final ContextRequestDiagnostics diagnostics;
}

class AppendOnlyContext {
  AppendOnlyContext({
    required this.budget,
    required this.encodedBytes,
    this.measurement = 'exact',
    int initialEpoch = 0,
  }) : _epoch = initialEpoch;

  static const statePrefix = '当前状态（系统生成）：';
  final ContextBudgetConfig budget;
  final int Function(LlmRequest) encodedBytes;
  final String measurement;
  int _epoch;
  String _system = '';
  List<LlmTool> _tools = const [];
  List<LlmMessage> _seed = const [];
  LlmMessage? _summary;
  final List<LlmMessage> _completed = [];
  int _completedTurns = 0;
  bool _seedCoveredByLedger = false;
  final Set<LlmMessage> _consumed = HashSet.identity();
  final Map<LlmMessage, LlmMessage> _replaced = HashMap.identity();

  int get epoch => _epoch;
  String get system => _system;
  List<LlmMessage> get journal => List.unmodifiable([
    ?_summary,
    ..._seed.map(_view),
    ..._completed.map(_view),
  ]);

  void activate({
    required String system,
    required List<LlmTool> tools,
    List<LlmMessage> seedMessages = const [],
    LlmMessage? summarySeed,
    bool seedCoveredByLedger = false,
  }) {
    _epoch++;
    _system = system;
    _tools = List.unmodifiable(tools);
    _seed = List.unmodifiable(seedMessages);
    _summary = summarySeed;
    _seedCoveredByLedger = seedCoveredByLedger;
    _completed.clear();
    _completedTurns = 0;
    _consumed.clear();
    _replaced.clear();
  }

  /// Call only after a successful client.complete. Merely preparing a request
  /// or attempting HTTP never proves that a model has consumed its receipts.
  void markConsumed(LlmRequest request) {
    _consumed.addAll(request.messages.where((m) => m.role == LlmRole.tool));
  }

  void finishTurn({required List<LlmMessage> messages}) {
    _completed.addAll(messages.map(_view));
    _completedTurns++;
  }

  LlmMessage _view(LlmMessage message) {
    var result = message;
    while (_replaced.containsKey(result)) {
      result = _replaced[result]!;
    }
    return result;
  }

  AppendOnlyPreparedContext compose({
    required List<LlmMessage> currentMessages,
    required LlmMessage stateMessage,
    required ContextTurnLedger ledger,
    required bool thinking,
    bool forceHardFold = false,
  }) {
    LlmRequest request() => LlmRequest(
      messages: List.unmodifiable([
        LlmMessage.system(_system),
        ...journal,
        ...currentMessages.map(_view),
        stateMessage,
      ]),
      tools: _tools,
      toolChoice: 'auto',
    );
    var result = request();
    final before = encodedBytes(result);
    final soft = budget.softLimit(thinking: thinking);
    var turnsFolded = 0;
    var receiptsFolded = 0;
    if ((before > soft || forceHardFold) &&
        (_completedTurns > 0 || (_seedCoveredByLedger && _seed.isNotEmpty)) &&
        ledger.turns.isNotEmpty) {
      // Only ended user turns are replaced. The current user's text, tools,
      // raw assistant messages and reasoning remain outside this operation.
      turnsFolded = _seedCoveredByLedger && _seed.isNotEmpty
          ? ledger.turns.length
          : _completedTurns;
      if (_seedCoveredByLedger) _seed = const [];
      _summary = ledger.summaryMessage();
      _completed.clear();
      _completedTurns = 0;
      _epoch++;
      result = request();
    }
    if (encodedBytes(result) > budget.hardBytes || forceHardFold) {
      final paired = _pairs(result.messages);
      for (final message in result.messages) {
        if (message.role != LlmRole.tool || !_consumed.contains(message)) {
          continue;
        }
        final call = paired[message];
        if (call == null) continue;
        final replacement = LlmMessage.tool(
          message.toolCallId!,
          _archive(call, message.content),
        );
        if (utf8.encode(replacement.content).length >=
            utf8.encode(message.content).length) {
          continue;
        }
        // A plain tool message intentionally carries no full-skill metadata.
        // The archived body can no longer authorize a "read already" marker.
        _replaced[message] = replacement;
        receiptsFolded++;
        result = request();
        if (!forceHardFold && encodedBytes(result) <= budget.hardBytes) break;
      }
      if (receiptsFolded > 0) _epoch++;
    }
    final after = encodedBytes(result);
    return AppendOnlyPreparedContext(
      result,
      ContextRequestDiagnostics(
        epoch: _epoch,
        beforeBytes: before,
        afterBytes: after,
        softLimitBytes: soft,
        hardLimitBytes: budget.hardBytes,
        tailStateBytes: utf8.encode(jsonEncode(stateMessage.toJson())).length,
        completedTurnsFolded: turnsFolded,
        receiptBodiesFolded: receiptsFolded,
        measurement: measurement,
        fitsHardLimit: after <= budget.hardBytes,
      ),
    );
  }

  Map<LlmMessage, LlmToolCall> _pairs(List<LlmMessage> messages) {
    final pending = <LlmToolCall>[];
    final paired = HashMap<LlmMessage, LlmToolCall>.identity();
    for (final message in messages) {
      if (message.role == LlmRole.assistant) {
        pending
          ..clear()
          ..addAll(message.toolCalls);
      } else if (message.role == LlmRole.tool) {
        final index = pending.indexWhere(
          (call) => call.id == message.toolCallId,
        );
        if (index >= 0) paired[message] = pending.removeAt(index);
      }
    }
    return paired;
  }

  String _archive(LlmToolCall call, String content) {
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      decoded = null;
    }
    final items = decoded is Map ? decoded['items'] : null;
    return jsonEncode({
      'archived': true,
      'tool': call.name,
      if (decoded is Map && decoded['ok'] is bool) 'ok': decoded['ok'],
      if (decoded is Map && decoded['code'] is String) 'code': decoded['code'],
      if (decoded is Map && decoded['fix'] is String) 'fix': decoded['fix'],
      if (items is List)
        'items': [
          for (final item in items)
            if (item is Map && item['id'] is String)
              {
                'id': item['id'],
                if (item['name'] is String) 'name': item['name'],
                if (item['doseMode'] is String) 'doseMode': item['doseMode'],
              },
        ],
      'note': '已消费工具结果已折叠；当前事实见末尾系统生成状态。',
    });
  }

  /// Generated facts never enter the real-user source ledger or the journal.
  static LlmMessage stateMessage({
    required CoachSessionState state,
    required Catalog catalog,
    required CoachProfile profile,
    required String language,
  }) {
    final id = state.activePlanId;
    final plan = state.plans[id]?.lastOrNull;
    final task = state.task;
    final Map<String, Object?> summary;
    if (task == null && plan == null) {
      summary = {
        'params': {
          for (final e in state.params.entries) e.key: e.value.toJson(),
        },
      };
    } else if (task?.nodes.lastOrNull?.status == 'done') {
      final ids = <String>{};
      void collect(Object? value) {
        if (value is Map) {
          if (value['exerciseId'] case final String id) ids.add(id);
          for (final child in value.values) {
            collect(child);
          }
        } else if (value is List) {
          for (final child in value) {
            collect(child);
          }
        }
      }

      collect(plan?.plan);
      if (plan == null) ids.addAll(state.picks);
      summary = {
        'parameters': task?.nodes
            .where((n) => n.id == 'parameters')
            .firstOrNull
            ?.stamp,
        'plan': plan == null
            ? null
            : {
                'plan_id': id,
                'version': plan.version,
                'title': plan.plan['title'],
                'estimateSec': plan.estimateSec,
              },
        'actions': [for (final id in ids) catalog[id]?.name.of(language) ?? id],
      };
    } else {
      summary = {
        'format':
            'task=[type,reused,nodes];nodes=[id,status,stamp,doneAtTurn];picks=[id,name];candidates=[id,name,body,doseMode]',
        'task': task == null
            ? null
            : [
                task.type,
                task.reused,
                [
                  for (final n in task.nodes)
                    [n.id, n.status, n.stamp, n.doneAtTurn],
                ],
              ],
        'params': {
          for (final e in state.params.entries) e.key: e.value.toJson(),
        },
        'picks': [
          for (final id in state.picks) [id, catalog[id]?.name.of(language)],
        ],
        'candidates': ActionSearch(
          profile,
          catalog,
          minPicks: profile.minActions,
        ).candidateRows(state, language: language),
        if (id != null)
          'plan': {
            'plan_id': id,
            if (plan != null) ...{
              'version': plan.version,
              'title': plan.plan['title'],
              'targetMinutes': plan.plan['targetMinutes'],
              'estimateSec': plan.estimateSec,
              'checkOk': plan.check?['ok'],
            },
          },
      };
    }
    return LlmMessage.user('$statePrefix${jsonEncode(summary)}');
  }
}
