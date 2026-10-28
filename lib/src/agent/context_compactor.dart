/// Builds model context without modifying saved history or structured state.
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../profile/coach_profile.dart';
import 'action_search.dart';
import 'action_tags.dart';
import 'agent_prompt.dart';
import 'catalog_data_gaps.dart';
import 'session_state.dart';
import 'skill_disclosure.dart';

class ContextCompactor {
  const ContextCompactor();

  static const archived = '[已归档，见当前状态]';

  /// Positions are indexes into [history], not tool-call IDs. Only pass a
  /// failed result whose replacement has been established structurally by the
  /// caller; identical tool names alone do not prove replacement.
  List<LlmMessage> compose({
    required LlmMessage system,
    required CoachSessionState state,
    required Catalog catalog,
    required List<LlmMessage> history,
    List<LlmMessage> turnMessages = const [],
    String language = 'zh',
    CoachProfile? profile,
    bool previousTaskFinished = false,
    Set<int> supersededFailureMessageIndexes = const {},
  }) {
    final summary = _summary(state, catalog, language, profile);
    final candidateIds = <String>{
      for (final row
          in summary['candidates'] as List<List<String?>>? ??
              const <List<String?>>[])
        row.first!,
    };
    final messages = <LlmMessage>[
      system,
      LlmMessage.system('当前状态：${jsonEncode(summary)}'),
    ];
    final gaps = CatalogDataGaps(
      ActionTags(
        profile ??
            const CoachProfile(id: 'diagnostics', appName: 'diagnostics'),
        catalog,
      ),
    );
    final combined = [
      for (final message in [...history, ...turnMessages])
        _filterCatalogWarnings(message, gaps, state),
    ];
    final paired = _pairs(combined);
    // Once a successful task makes an earlier skill read irrelevant, do
    // not revive that raw result if a later task needs the skill again.
    final skillStarts = <({int index, Set<String> required})>[];
    for (final entry in paired.entries) {
      if (entry.value.name != AgentTools.startTask ||
          !_ok(combined[entry.key].content)) {
        continue;
      }
      final type = _arguments(entry.value)['type'];
      if (type != 'recommend' && type != 'plan') continue;
      skillStarts.add((
        index: entry.key,
        required: SkillDisclosures.requiredFor(type as String),
      ));
    }
    final unrelatedReads = <int>{};
    for (final entry in paired.entries) {
      final path = SkillDisclosures.readPath(entry.value);
      if (path == null || !path.endsWith('/SKILL.md')) continue;
      if (skillStarts.any(
        (start) => start.index > entry.key && !start.required.contains(path),
      )) {
        unrelatedReads.add(entry.key);
      }
    }
    // Results from the latest model batch are visible in full exactly once.
    // A later assistant response proves a model call has consumed them, even
    // across user turns and before the actions node is completed.
    final latestAssistant = combined.lastIndexWhere(
      (message) => message.role == LlmRole.assistant,
    );
    final askedMessages = <int>{};
    int? assistantIndex;
    for (var index = 0; index < combined.length; index++) {
      final message = combined[index];
      if (message.role == LlmRole.assistant) {
        assistantIndex = index;
      } else if (message.role == LlmRole.tool) {
        if (assistantIndex != null &&
            paired[index]?.name == AgentTools.askUser &&
            _asked(message.content)) {
          askedMessages.add(assistantIndex);
        }
      } else {
        assistantIndex = null;
      }
    }

    final completed = <String>{
      for (final node in state.task?.nodes ?? const <CoachNodeState>[])
        if (node.status == 'done' || node.status == 'updated') node.id,
    };
    final completedAt = <String, int>{};
    for (final entry in paired.entries) {
      if (entry.value.name != AgentTools.check ||
          !_ok(combined[entry.key].content)) {
        continue;
      }
      final node = _arguments(entry.value)['node'];
      if (node is String && completed.contains(node)) {
        completedAt[node] = entry.key;
      }
    }
    for (var index = 0; index < combined.length; index++) {
      final message = combined[index];
      if (previousTaskFinished && index < history.length) {
        if (message.role == LlmRole.user) {
          messages.add(message);
        } else if (message.role == LlmRole.assistant &&
            message.content.isNotEmpty &&
            (message.toolCalls.isEmpty || askedMessages.contains(index))) {
          messages.add(
            LlmMessage.assistant(message.content, reasoning: message.reasoning),
          );
        }
        continue;
      }
      if (message.role != LlmRole.tool) {
        if (message.role != LlmRole.system) messages.add(message);
        continue;
      }
      final call = paired[index];
      if (unrelatedReads.contains(index)) {
        messages.add(
          LlmMessage.tool(
            message.toolCallId!,
            SkillDisclosures.unrelatedArchive,
          ),
        );
        continue;
      }
      final node = switch (call?.name) {
        AgentTools.searchActions || AgentTools.getAction => 'actions',
        AgentTools.draftPlan => 'planning',
        AgentTools.checkPlan => 'review',
        _ => null,
      };
      final archive =
          call != null &&
          call.name != AgentTools.startTask &&
          ((node != null && (completedAt[node] ?? -1) > index) ||
              (supersededFailureMessageIndexes.contains(index) &&
                  _failed(message.content)));
      final oldActionBatch =
          call != null &&
          index < latestAssistant &&
          (call.name == AgentTools.searchActions ||
              call.name == AgentTools.getAction) &&
          _ok(message.content);
      messages.add(
        (archive && node == 'actions') || oldActionBatch
            ? LlmMessage.tool(
                message.toolCallId!,
                _archiveActions(call, message.content, candidateIds),
              )
            : archive
            ? LlmMessage.tool(message.toolCallId!, archived)
            : message,
      );
    }
    return List.unmodifiable(
      _compactStateReceipts(
        _deduplicateSearchFormats(_compactSearchWarnings(messages, catalog)),
        state,
        summary,
      ),
    );
  }

  /// Exact catalogue-generated warning bindings can be reclassified after a
  /// restore. This only changes the request view, never the saved history.
  LlmMessage _filterCatalogWarnings(
    LlmMessage message,
    CatalogDataGaps gaps,
    CoachSessionState state,
  ) {
    if (message.role != LlmRole.tool) return message;
    Object? decoded;
    try {
      decoded = jsonDecode(message.content);
    } on FormatException {
      return message;
    }
    var changed = false;
    Object? visit(Object? value) {
      if (value is List) return [for (final item in value) visit(item)];
      if (value is! Map) return value;
      final next = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) return value;
        if (entry.key == 'warnings' && entry.value is List) {
          final warnings = entry.value as List;
          final kept = [
            for (final warning in warnings)
              if (warning is! String ||
                  gaps.filterWarnings(state, [warning]).isNotEmpty)
                visit(warning),
          ];
          if (kept.length != warnings.length) changed = true;
          if (kept.isNotEmpty) next['warnings'] = kept;
        } else if (entry.key == 'warnings' && entry.value is Map) {
          final packed = entry.value as Map;
          if (packed['template'] == '{id} 的 {field} 尚未明确，不能视为已验证。' &&
              packed['fields'] is List &&
              packed['rows'] is List) {
            final fields = packed['fields'] as List;
            final rows = packed['rows'] as List;
            bool keepRow(Object? row) {
              if (row is String) {
                return gaps.filterWarnings(state, [row]).isNotEmpty;
              }
              if (row is! List ||
                  row.length != 2 ||
                  row[0] is! String ||
                  row[1] is! int) {
                return true;
              }
              final index = row[1] as int;
              if (index < 0 ||
                  index >= fields.length ||
                  fields[index] is! String) {
                return true;
              }
              return gaps.filterWarnings(state, [
                CatalogDataGaps.warning(
                  row[0] as String,
                  fields[index] as String,
                ),
              ]).isNotEmpty;
            }

            final kept = [
              for (final row in rows)
                if (keepRow(row)) row,
            ];
            if (kept.length != rows.length) changed = true;
            if (kept.isNotEmpty) {
              next['warnings'] = kept.every((row) => row is String)
                  ? kept
                  : {...packed.cast<String, Object?>(), 'rows': kept};
            }
          } else {
            next[entry.key as String] = visit(entry.value);
          }
        } else {
          next[entry.key as String] = visit(entry.value);
        }
      }
      return next;
    }

    final filtered = visit(decoded);
    if (!changed) return message;
    final content = jsonEncode(filtered);
    return message is SkillDisclosureMessage
        ? SkillDisclosureMessage(
            message.toolCallId!,
            content,
            fullRead: message.fullRead,
            fullSkills: message.fullSkills,
            requiredSkills: message.requiredSkills,
          )
        : LlmMessage.tool(message.toolCallId!, content);
  }

  /// Previously consumed, successful state receipts can refer to an identical
  /// snapshot already present in this request. Changed values stay complete,
  /// and a tool reference always targets an earlier still-full dictionary.
  List<LlmMessage> _compactStateReceipts(
    List<LlmMessage> messages,
    CoachSessionState state,
    Map<String, Object?> summary,
  ) {
    final current = <String, Object?>{
      if (summary['task'] != null) 'task': state.task?.toJson(),
      if (summary['params'] is Map) 'params': summary['params'],
    };
    final latestAssistant = messages.lastIndexWhere(
      (message) => message.role == LlmRole.assistant,
    );
    final paired = _pairs(messages);
    final fullTasks = <String, String>{};
    return [
      for (var index = 0; index < messages.length; index++)
        (() {
          final message = messages[index];
          final call = paired[index];
          if (call == null ||
              !const {
                AgentTools.startTask,
                AgentTools.check,
                AgentTools.setParams,
              }.contains(call.name) ||
              !_ok(message.content)) {
            return message;
          }
          final decoded = jsonDecode(message.content) as Map<String, dynamic>;
          var changed = false;
          final next = <String, Object?>{...decoded};
          for (final field in ['task', 'params']) {
            final value = decoded[field];
            if (value is! Map ||
                value.containsKey('sameAsCurrentState') ||
                value.containsKey('sameAsToolCall')) {
              continue;
            }
            final encoded = jsonEncode(value);
            Map<String, Object?>? reference;
            if (index < latestAssistant) {
              if (current[field] != null &&
                  encoded == jsonEncode(current[field])) {
                reference = {'sameAsCurrentState': field};
              } else if (field == 'task' &&
                  call.name == AgentTools.check &&
                  fullTasks.containsKey(encoded)) {
                reference = {
                  'sameAsToolCall': fullTasks[encoded],
                  'field': 'task',
                };
              }
            }
            if (reference != null &&
                utf8.encode(jsonEncode(reference)).length <
                    utf8.encode(encoded).length) {
              next[field] = reference;
              changed = true;
            } else if (field == 'task') {
              fullTasks.putIfAbsent(encoded, () => message.toolCallId!);
            }
          }
          if (!changed) return message;
          // Only task/params changed; skill bodies are still fully present.
          // Real archival above replaces the message with a plain tool result,
          // so this cannot revive metadata for a removed skill body.
          final content = jsonEncode(next);
          final compacted = message is SkillDisclosureMessage
              ? SkillDisclosureMessage(
                  message.toolCallId!,
                  content,
                  fullRead: message.fullRead,
                  fullSkills: message.fullSkills,
                  requiredSkills: message.requiredSkills,
                )
              : LlmMessage.tool(message.toolCallId!, content);
          return utf8.encode(jsonEncode(compacted.toJson())).length <
                  utf8.encode(jsonEncode(message.toJson())).length
              ? compacted
              : message;
        })(),
    ];
  }

  /// Repeated catalogue-generated warnings retain their full sentence template
  /// and every action/field binding. Unrecognized warning text stays literal.
  /// This representation is used only when it makes the wire message smaller.
  List<LlmMessage> _compactSearchWarnings(
    List<LlmMessage> messages,
    Catalog catalog,
  ) {
    final known = <String, ({String id, String field})>{};
    for (final drill in catalog.drills) {
      final semantics = drill.raw['trainingSemantics'];
      final unknown = semantics is Map ? semantics['unknownFields'] : null;
      if (unknown is! List) continue;
      for (final entry in unknown) {
        if (entry is! Map || entry['field'] is! String) continue;
        final field = entry['field'] as String;
        known['${drill.id} 的 $field 尚未明确，不能视为已验证。'] = (
          id: drill.id,
          field: field,
        );
      }
    }
    final paired = _pairs(messages);
    return [
      for (var index = 0; index < messages.length; index++)
        (() {
          final message = messages[index];
          if (paired[index]?.name != AgentTools.searchActions ||
              !_ok(message.content)) {
            return message;
          }
          final decoded = jsonDecode(message.content) as Map<String, dynamic>;
          final warnings = decoded['warnings'];
          if (warnings is! List || warnings.any((value) => value is! String)) {
            return message;
          }
          final fields = <String>[];
          final rows = <Object?>[];
          for (final text in warnings) {
            final binding = known[text];
            if (binding == null) {
              rows.add(text);
            } else {
              var position = fields.indexOf(binding.field);
              if (position < 0) {
                position = fields.length;
                fields.add(binding.field);
              }
              rows.add([binding.id, position]);
            }
          }
          if (fields.isEmpty) return message;
          final compacted = LlmMessage.tool(
            message.toolCallId!,
            jsonEncode({
              ...decoded,
              'warnings': {
                'template': '{id} 的 {field} 尚未明确，不能视为已验证。',
                'fields': fields,
                'rows': rows,
              },
            }),
          );
          return utf8.encode(jsonEncode(compacted.toJson())).length <
                  utf8.encode(jsonEncode(message.toJson())).length
              ? compacted
              : message;
        })(),
    ];
  }

  /// Identical search column dictionaries need only occur once in a request.
  /// References are built after archival, so their target is always still
  /// present with its full dictionary and original tool_call_id. Raw history
  /// and stored tool captures are never modified.
  List<LlmMessage> _deduplicateSearchFormats(List<LlmMessage> messages) {
    final paired = _pairs(messages);
    final firstFormats = <String, String>{};
    return [
      for (var index = 0; index < messages.length; index++)
        (() {
          final message = messages[index];
          if (paired[index]?.name != AgentTools.searchActions ||
              !_ok(message.content)) {
            return message;
          }
          final decoded = jsonDecode(message.content) as Map<String, dynamic>;
          final format = decoded['format'];
          if (format is! Map ||
              format.isEmpty ||
              format.containsKey('sameAsToolCall')) {
            return message;
          }
          final key = jsonEncode(format);
          final original = firstFormats[key];
          if (original == null) {
            firstFormats[key] = message.toolCallId!;
            return message;
          }
          return LlmMessage.tool(
            message.toolCallId!,
            jsonEncode({
              ...decoded,
              'format': {'sameAsToolCall': original},
            }),
          );
        })(),
    ];
  }

  String _archiveActions(
    LlmToolCall call,
    String content,
    Set<String> candidateIds,
  ) {
    Map<Object?, Object?> data;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<Object?, Object?>) {
        return '[已归档] 先前动作查询已由后续结果替代。';
      }
      data = decoded;
    } on FormatException {
      return '[已归档] 先前动作查询已由后续结果替代。';
    }
    final items = data['items'];
    if (items is! List) return '[已归档] 先前动作查询已由后续结果替代。';
    final ids = <String>[];
    final rawIds = <String>[];
    for (final item in items) {
      if (item is! Map || item['id'] is! String) continue;
      final id = item['id'] as String;
      rawIds.add(id);
      final name = item['name'];
      ids.add(
        call.name == AgentTools.searchActions && name is String
            ? '$id $name'
            : id,
      );
    }
    if (rawIds.isEmpty) return '[已归档] 本次未返回动作。';
    if (call.name == AgentTools.searchActions &&
        candidateIds.isNotEmpty &&
        candidateIds.containsAll(rawIds)) {
      return '[已归档，候选见当前状态 candidates]';
    }
    return call.name == AgentTools.searchActions
        ? '[已归档] 返回：${ids.join('、')}'
        : '[已归档] 已查看要领：${ids.join('、')}';
  }

  /// Find failed results replaced by a later success with the same structured
  /// target, without using model prose or assuming IDs are globally unique.
  Set<int> supersededFailures(
    List<LlmMessage> history, [
    List<LlmMessage> turnMessages = const [],
  ]) {
    final combined = [...history, ...turnMessages];
    final pending = <String, List<int>>{};
    final replaced = <int>{};
    for (final entry in _pairs(combined).entries) {
      final call = entry.value;
      final content = combined[entry.key].content;
      if (call.name == AgentTools.startTask && _ok(content)) {
        pending.clear();
        continue;
      }
      final key = _target(call);
      if (key == null) continue;
      if (_failed(content)) {
        (pending[key] ??= []).add(entry.key);
      } else if (_ok(content)) {
        replaced.addAll(pending.remove(key) ?? const []);
      }
    }
    return replaced;
  }

  Map<int, LlmToolCall> _pairs(List<LlmMessage> messages) {
    final pending = <LlmToolCall>[];
    final result = <int, LlmToolCall>{};
    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      if (message.role == LlmRole.assistant) {
        pending
          ..clear()
          ..addAll(message.toolCalls);
      } else if (message.role == LlmRole.tool) {
        final position = pending.indexWhere(
          (call) => call.id == message.toolCallId,
        );
        if (position >= 0) result[index] = pending.removeAt(position);
      }
    }
    return result;
  }

  Map<Object?, Object?> _arguments(LlmToolCall call) {
    try {
      final value = jsonDecode(call.arguments);
      return value is Map ? value : const {};
    } on FormatException {
      return const {};
    }
  }

  bool? _status(String content) {
    try {
      final value = jsonDecode(content);
      return value is Map && value['ok'] is bool ? value['ok'] as bool : null;
    } on FormatException {
      return null;
    }
  }

  bool _ok(String content) => _status(content) == true;
  bool _failed(String content) => _status(content) == false;

  bool _asked(String content) {
    try {
      final value = jsonDecode(content);
      return value is Map && value['ok'] == true && value['asked'] == true;
    } on FormatException {
      return false;
    }
  }

  String? _target(LlmToolCall call) {
    final args = _arguments(call);
    if (call.name == AgentTools.check) {
      final node = args['node'];
      return node is String && node.isNotEmpty ? '${call.name}:$node' : null;
    }
    if (call.name == AgentTools.draftPlan ||
        call.name == AgentTools.checkPlan) {
      final id = args['plan_id'];
      return id is String && id.isNotEmpty ? '${call.name}:$id' : null;
    }
    if (call.name == AgentTools.searchActions ||
        call.name == AgentTools.getAction) {
      if (args.isEmpty) return null;
      final keys = args.keys.whereType<String>().toList()..sort();
      if (keys.length != args.length) return null;
      return '${call.name}:${jsonEncode({for (final key in keys) key: args[key]})}';
    }
    return null;
  }

  Map<String, Object?> _summary(
    CoachSessionState state,
    Catalog catalog,
    String language,
    CoachProfile? profile,
  ) {
    final planId = state.activePlanId;
    final versions = planId == null ? null : state.plans[planId];
    final latest = versions == null || versions.isEmpty ? null : versions.last;
    final task = state.task;
    if (task == null && latest == null) {
      return {
        'params': {
          for (final entry in state.params.entries)
            entry.key: entry.value.toJson(),
        },
      };
    }
    if (task?.nodes.lastOrNull?.id == 'output' &&
        task?.nodes.lastOrNull?.status == 'done') {
      final actionIds = <String>{};
      void collect(Object? value) {
        if (value is Map) {
          if (value['exerciseId'] case final String id) actionIds.add(id);
          for (final child in value.values) {
            collect(child);
          }
        } else if (value is List) {
          for (final child in value) {
            collect(child);
          }
        }
      }

      collect(latest?.plan);
      if (latest == null) actionIds.addAll(state.picks);
      return {
        'parameters': task!.nodes
            .where((node) => node.id == 'parameters')
            .firstOrNull
            ?.stamp,
        'plan': latest == null
            ? null
            : {
                'plan_id': planId,
                'version': latest.version,
                'title': latest.plan['title'],
                'estimateSec': latest.estimateSec,
              },
        'actions': [
          for (final id in actionIds) catalog[id]?.name.of(language) ?? id,
        ],
      };
    }
    return {
      'format':
          'task=[type,reused,nodes];nodes=[id,status,stamp,doneAtTurn];picks=[id,name];candidates=[id,name,body,doseMode]',
      'task': task == null
          ? null
          : [
              task.type,
              task.reused,
              [
                for (final node in task.nodes)
                  [node.id, node.status, node.stamp, node.doneAtTurn],
              ],
            ],
      'params': {
        for (final entry in state.params.entries)
          entry.key: entry.value.toJson(),
      },
      'picks': [
        for (final id in state.picks) [id, catalog[id]?.name.of(language)],
      ],
      'candidates': ActionSearch(
        profile ?? const CoachProfile(id: 'context', appName: 'context'),
        catalog,
        minPicks: profile?.minActions ?? 3,
      ).candidateRows(state, language: language),
      if (planId != null)
        'plan': {
          'plan_id': planId,
          if (latest != null) ...{
            'version': latest.version,
            'title': latest.plan['title'],
            'targetMinutes': latest.plan['targetMinutes'],
            'estimateSec': latest.estimateSec,
            'checkOk': latest.check?['ok'],
          },
        },
    };
  }
}
