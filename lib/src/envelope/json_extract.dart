/// 从模型正文里取出 JSON 对象：去 BOM、`<think>` 段、markdown 围栏、前后说明文字、
/// 对象/数组末尾多余的逗号。只做这些无歧义的修复，不猜内容。
library;

import 'dart:convert';

class JsonExtractResult {
  const JsonExtractResult(this.value, {this.repairs = const [], this.error});
  final Map<String, Object?>? value;

  /// 做过的修复（记录用）：fence / think / prose / trailing_comma / bom。
  final List<String> repairs;
  final String? error;
  bool get ok => value != null;
}

JsonExtractResult extractJsonObject(String raw) {
  final repairs = <String>[];
  var s = raw;
  if (s.startsWith('\uFEFF')) {
    s = s.substring(1);
    repairs.add('bom');
  }
  final think = RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false);
  if (think.hasMatch(s)) {
    s = s.replaceAll(think, '');
    repairs.add('think');
  }
  final fence = RegExp(r'```(?:json|JSON)?\s*\n?([\s\S]*?)```').firstMatch(s);
  if (fence != null) {
    s = fence.group(1)!;
    repairs.add('fence');
  }
  s = s.trim();
  final start = s.indexOf('{');
  if (start < 0) return JsonExtractResult(null, repairs: repairs, error: '正文里没有 JSON 对象');
  final end = _matchingBrace(s, start);
  if (end < 0) return JsonExtractResult(null, repairs: repairs, error: 'JSON 对象没有闭合（可能被截断）');
  if (start > 0 || end < s.length - 1) repairs.add('prose');
  var body = s.substring(start, end + 1);
  Object? v;
  try {
    v = jsonDecode(body);
  } on FormatException {
    final fixed = _dropTrailingCommas(body);
    if (fixed != body) {
      try {
        v = jsonDecode(fixed);
        body = fixed;
        repairs.add('trailing_comma');
      } on FormatException catch (e) {
        return JsonExtractResult(null, repairs: repairs, error: 'JSON 语法错误：${e.message}');
      }
    } else {
      return JsonExtractResult(null, repairs: repairs, error: 'JSON 语法错误');
    }
  }
  if (v is! Map) return JsonExtractResult(null, repairs: repairs, error: '顶层不是对象');
  return JsonExtractResult(v.map((k, val) => MapEntry('$k', val)), repairs: repairs);
}

/// 字符串感知的括号匹配。
int _matchingBrace(String s, int start) {
  var depth = 0;
  var inStr = false;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (inStr) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

String _dropTrailingCommas(String s) {
  final b = StringBuffer();
  var inStr = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (inStr) {
      b.write(c);
      if (c == r'\' && i + 1 < s.length) {
        b.write(s[++i]);
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') inStr = true;
    if (c == ',') {
      var j = i + 1;
      while (j < s.length && ' \t\r\n'.contains(s[j])) {
        j++;
      }
      if (j < s.length && (s[j] == '}' || s[j] == ']')) continue;
    }
    b.write(c);
  }
  return b.toString();
}
