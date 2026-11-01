/// Per-response tool ordering and failure propagation.
library;

import 'dart:convert';

import '../llm/llm_types.dart';

class ToolBatch {
  /// Stable ordering for one unambiguous typed dependency chain. Reads,
  /// checks, memory tools and malformed calls remain barriers; multiple task,
  /// parameter or draft writes are not reordered across one another.
  static List<LlmToolCall> orderedCalls(List<LlmToolCall> calls) {
    const ranks = {
      'start_task': 0,
      'set_params': 1,
      'search_actions': 2,
      'get_action': 2,
      'draft_plan': 3,
    };
    bool typed(LlmToolCall call) {
      if (!ranks.containsKey(call.name)) return false;
      Object? args;
      try {
        args = jsonDecode(call.arguments);
        if (args is String) args = jsonDecode(args);
      } on FormatException {
        return false;
      }
      if (args is! Map || args.keys.any((key) => key is! String)) return false;
      return switch (call.name) {
        'start_task' => {'plan', 'recommend'}.contains(args['type']),
        'set_params' =>
          (args['fields'] is Map ||
                  args['fields'] == null && args['scope_request'] is Map) &&
              (args['scope_request'] == null || args['scope_request'] is Map),
        'draft_plan' =>
          args['blocks'] is List && (args['blocks'] as List).isNotEmpty,
        'search_actions' =>
          args['tags'] == null ||
              args['tags'] is List ||
              args['tags'] is String,
        'get_action' =>
          args['ids'] == null || args['ids'] is List || args['ids'] is String,
        _ => false,
      };
    }

    final result = <LlmToolCall>[];
    var position = 0;
    while (position < calls.length) {
      if (!typed(calls[position])) {
        result.add(calls[position++]);
        continue;
      }
      final begin = position;
      while (position < calls.length && typed(calls[position])) {
        position++;
      }
      final segment = calls.sublist(begin, position);
      final ambiguous = const {
        'start_task',
        'set_params',
        'draft_plan',
      }.any((name) => segment.where((call) => call.name == name).length > 1);
      if (ambiguous) {
        result.addAll(segment);
        continue;
      }
      final ordered = segment.indexed.toList()
        ..sort((a, b) {
          final rank = ranks[a.$2.name]!.compareTo(ranks[b.$2.name]!);
          return rank == 0 ? a.$1.compareTo(b.$1) : rank;
        });
      result.addAll(ordered.map((entry) => entry.$2));
    }
    return List.unmodifiable(result);
  }

  final Map<String, String> results = {};
  int? firstFailure;
  bool _searchFailure = false;

  bool get failed => firstFailure != null;

  /// Independent searches may still return useful results after another
  /// search failed. Mutations and failures of other tools keep their barrier.
  bool shouldSkip(String name) =>
      failed && !(_searchFailure && name == 'search_actions');

  void skipped(String id) {
    results[id] = jsonEncode({
      'ok': false,
      'code': 'skipped_after_error',
      'field': 'tool_calls',
      'expected': '前面的工具调用成功',
      'actual': '第 $firstFailure 个调用失败',
      'fix': '先修复失败的工具调用后再重试。',
    });
  }

  void skippedAfterCompletion(String id, int index) {
    results[id] = jsonEncode({
      'ok': false,
      'code': 'skipped_after_completion',
      'field': 'tool_calls',
      'expected': '交付前的工具调用',
      'actual': '第 $index 个调用已完成交付',
      'fix': '如需继续操作，请在下一轮发起。',
    });
  }

  void mark(int oneBasedIndex, String id, {bool? failure, String? name}) {
    if (firstFailure != null) return;
    final result = results[id];
    var isFailure = failure ?? false;
    if (failure == null && result != null) {
      try {
        final decoded = jsonDecode(result);
        isFailure = decoded is Map && decoded['ok'] == false;
      } on FormatException {
        // Successful read and list results are plain text.
      }
    }
    if (isFailure) {
      firstFailure = oneBasedIndex;
      _searchFailure = name == 'search_actions';
    }
  }
}
