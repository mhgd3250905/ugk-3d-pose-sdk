/// Per-response tool ordering and failure propagation.
library;

import 'dart:convert';

class ToolBatch {
  final Map<String, String> results = {};
  int? firstFailure;

  bool get failed => firstFailure != null;

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

  void mark(int oneBasedIndex, String id, {bool? failure}) {
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
    if (isFailure) firstFailure = oneBasedIndex;
  }
}
