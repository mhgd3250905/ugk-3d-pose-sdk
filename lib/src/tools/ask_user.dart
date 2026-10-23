/// Agent 澄清问题：只有通过 [AskUserGate] 的参数才交给 App。
library;

import 'dart:convert';

import '../plan/plan_issue.dart';

enum AskUserMode { text, choice }

class AskUserQuestion {
  AskUserQuestion._(
    this.question,
    this.mode,
    List<String> options,
    this.multiple,
  ) : options = List.unmodifiable(options);

  final String question;
  final AskUserMode mode;

  /// text 时为空；choice 时为 2–6 个、每个不超过 12 个 Unicode 码点的选项。
  final List<String> options;
  final bool multiple;

  Map<String, Object?> toJson() => {
    'question': question,
    'mode': mode.name,
    if (mode == AskUserMode.choice) ...{
      'options': options,
      'multiple': multiple,
    },
  };
}

class AskUserGateResult {
  AskUserGateResult._(this.question, List<PlanIssue> errors)
    : errors = List.unmodifiable(errors);
  final AskUserQuestion? question;
  final List<PlanIssue> errors;
  bool get ok => question != null && errors.isEmpty;
}

abstract final class AskUserGate {
  /// 只校验，不修补 JSON、字段类型、选项或模式；错误沿用 Agent 的工具重交机制。
  static AskUserGateResult check(String arguments) {
    final errors = <PlanIssue>[];
    void issue(String path, String expected, String actual, {String? code}) {
      errors.add(
        PlanIssue(
          code ?? IssueCodes.schema,
          'ask_user 的 $path 不合规',
          path: path,
          expected: expected,
          actual: actual,
          fix: '只问一件事，按 expected 重交完整 ask_user 参数；text 不带 options/multiple。',
        ),
      );
    }

    Object? raw;
    try {
      raw = jsonDecode(arguments);
    } on FormatException {
      issue('arguments', '合法 JSON 对象', '非法 JSON', code: IssueCodes.invalidJson);
      return AskUserGateResult._(null, errors);
    }
    if (raw is! Map<String, dynamic>) {
      issue('arguments', 'JSON 对象', '${raw.runtimeType}');
      return AskUserGateResult._(null, errors);
    }
    for (final key in raw.keys) {
      if (!const {'question', 'mode', 'options', 'multiple'}.contains(key)) {
        issue(
          key,
          'question / mode / options / multiple',
          '多余字段',
          code: IssueCodes.unexpectedField,
        );
      }
    }
    final question = raw['question'];
    if (question is! String || question.trim().isEmpty) {
      issue('question', '非空、简短口语问题', '${question.runtimeType}');
    }
    final mode = raw['mode'];
    if (mode != 'text' && mode != 'choice') {
      issue('mode', 'text 或 choice', '$mode');
    }
    final options = <String>[];
    if (mode == 'text') {
      for (final key in ['options', 'multiple']) {
        if (raw.containsKey(key)) {
          issue(key, 'text 模式不带此字段', '字段存在', code: IssueCodes.unexpectedField);
        }
      }
    } else if (mode == 'choice') {
      final values = raw['options'];
      if (values is! List) {
        issue('options', '2–6 个短选项的数组', '${values.runtimeType}');
      } else {
        if (values.length < 2 || values.length > 6) {
          issue('options', '2–6 个选项', '${values.length} 个');
        }
        for (var i = 0; i < values.length; i++) {
          final value = values[i];
          if (value is! String ||
              value.trim().isEmpty ||
              value.runes.length > 12) {
            issue(
              'options[$i]',
              '非空字符串，每个最多 12 个 Unicode 码点',
              '${value.runtimeType}',
            );
          } else {
            if (options.contains(value.trim())) {
              issue('options[$i]', '不重复的选项', '重复选项');
            }
            options.add(value.trim());
          }
        }
      }
      if (raw.containsKey('multiple') && raw['multiple'] is! bool) {
        issue(
          'multiple',
          'boolean，省略时为 false',
          '${raw['multiple'].runtimeType}',
        );
      }
    }
    return AskUserGateResult._(
      errors.isEmpty
          ? AskUserQuestion._(
              (question as String).trim(),
              mode == 'choice' ? AskUserMode.choice : AskUserMode.text,
              options,
              raw['multiple'] == true,
            )
          : null,
      errors,
    );
  }
}
