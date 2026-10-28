/// Agent 澄清问题：只有通过 [AskUserGate] 的参数才交给 App。
library;

import 'dart:convert';

import '../plan/plan_issue.dart';

enum AskUserMode { text, choice, form }

/// A group of choices in a single clarification round.
class AskUserField {
  AskUserField({
    required this.key,
    required this.label,
    required List<String> options,
    this.multiple = false,
    List<String> preselected = const [],
    List<String> previousSelections = const [],
    Map<String, List<String>> optionsByScene = const {},
  }) : options = List.unmodifiable(options),
       preselected = List.unmodifiable(preselected),
       previousSelections = List.unmodifiable(previousSelections),
       optionsByScene = Map.unmodifiable({
         for (final entry in optionsByScene.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       });
  final String key;
  final String label;
  final List<String> options;
  final bool multiple;

  /// Initial selections for a confirmation card. Values must be in [options].
  final List<String> preselected;

  /// The selections that are suggestions from an earlier task, not confirmed
  /// facts for this task. An empty list means no previous suggestion.
  final List<String> previousSelections;

  /// Allowed options by localized scene label, used for equipment only.
  final Map<String, List<String>> optionsByScene;
  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'options': options,
    'multiple': multiple,
    if (preselected.isNotEmpty) 'preselected': preselected,
    if (previousSelections.isNotEmpty) 'previousSelections': previousSelections,
    if (optionsByScene.isNotEmpty) 'optionsByScene': optionsByScene,
  };
}

class AskUserQuestion {
  AskUserQuestion._(
    this.question,
    this.mode,
    List<String> options,
    this.multiple,
    List<AskUserField> fields, {
    this.isConfirmation = false,
    this.focus,
    String language = 'zh',
    Map<String, List<String>> defaultSelections = const {},
  }) : options = List.unmodifiable(options),
       fields = List.unmodifiable(fields),
       _language = language,
       defaultSelections = Map.unmodifiable({
         for (final entry in defaultSelections.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       });

  final String question;
  final AskUserMode mode;

  /// text 时为空；choice 为 2–6 项。中文每项最多 12 个码点，英文最多 12 词。
  final List<String> options;
  final bool multiple;
  final List<AskUserField> fields;
  final bool isConfirmation;
  final String? focus;
  final String _language;
  final Map<String, List<String>> defaultSelections;
  String get skipLabel => _language.toLowerCase().startsWith('en')
      ? (isConfirmation ? 'Use defaults' : 'Show suggestions')
      : (isConfirmation ? '按默认来' : '直接出方案');

  /// Builds the SDK's locally generated training-condition confirmation.
  /// App and model inputs must still go through the ordinary answer gate.
  factory AskUserQuestion.confirmation({
    required String question,
    required List<AskUserField> fields,
    String? focus,
    String language = 'zh',
    required Map<String, List<String>> defaultSelections,
  }) {
    final keys = fields.map((field) => field.key).toSet();
    if (question.trim().isEmpty ||
        fields.length != 3 ||
        keys.length != 3 ||
        !keys.containsAll(const {'scene', 'equipment', 'minutes'}) ||
        fields.any(
          (field) =>
              field.preselected.any((v) => !field.options.contains(v)) ||
              field.previousSelections.any(
                (v) => !field.preselected.contains(v),
              ),
        )) {
      throw ArgumentError('Invalid training confirmation');
    }
    return AskUserQuestion._(
      question.trim(),
      AskUserMode.form,
      const [],
      false,
      fields,
      isConfirmation: true,
      focus: focus,
      language: language,
      defaultSelections: defaultSelections,
    );
  }

  Map<String, Object?> toJson() => {
    'question': question,
    'mode': mode.name,
    if (mode == AskUserMode.choice) ...{
      'options': options,
      'multiple': multiple,
    },
    if (mode == AskUserMode.form) ...{
      'fields': [for (final field in fields) field.toJson()],
      'skipLabel': skipLabel,
    },
    if (isConfirmation) 'isConfirmation': true,
    if (focus != null) 'focus': focus,
    if (defaultSelections.isNotEmpty) 'defaultSelections': defaultSelections,
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
  static AskUserGateResult check(String arguments, {String language = 'zh'}) {
    final english = language.toLowerCase().startsWith('en');
    int length(String value) => english
        ? value.trim().split(RegExp(r'\s+')).length
        : value.runes.length;
    final errors = <PlanIssue>[];
    void issue(String path, String expected, String actual, {String? code}) {
      errors.add(
        PlanIssue(
          code ?? IssueCodes.schema,
          'ask_user 的 $path 不合规',
          path: path,
          expected: expected,
          actual: actual,
          fix: '将 ask_user.$path 设置为 $expected，重新调用 ask_user。',
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
      if (!const {
        'question',
        'mode',
        'options',
        'multiple',
        'fields',
        'skipLabel',
      }.contains(key)) {
        issue(
          key,
          'question / mode / options / multiple / fields / skipLabel',
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
    if (mode != 'text' && mode != 'choice' && mode != 'form') {
      issue('mode', 'text、choice 或 form', '$mode');
    }
    final options = <String>[];
    final fields = <AskUserField>[];
    if (mode != 'form') {
      for (final key in ['fields', 'skipLabel']) {
        if (raw.containsKey(key)) issue(key, '仅 form 模式提供', '字段存在');
      }
    }
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
          if (value is! String || value.trim().isEmpty || length(value) > 12) {
            issue(
              'options[$i]',
              english
                  ? 'Nonempty option, at most 12 words'
                  : '非空字符串，每个最多 12 个 Unicode 码点',
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
    } else if (mode == 'form') {
      for (final key in ['options', 'multiple']) {
        if (raw.containsKey(key)) issue(key, 'form 使用 fields', '字段存在');
      }
      final skipLabel = english ? 'Show suggestions' : '直接出方案';
      if (raw.containsKey('skipLabel') && raw['skipLabel'] != skipLabel) {
        issue('skipLabel', skipLabel, '${raw['skipLabel']}');
      }
      final values = raw['fields'];
      if (values is! List || values.isEmpty || values.length > 3) {
        issue('fields', '1–3 组缺失条件', '${values.runtimeType}');
      } else {
        final keys = <String>{};
        for (var i = 0; i < values.length; i++) {
          final value = values[i];
          if (value is! Map<String, dynamic>) {
            issue('fields[$i]', '条件对象', '${value.runtimeType}');
            continue;
          }
          if (value.keys.any(
            (key) =>
                !const {'key', 'label', 'options', 'multiple'}.contains(key),
          )) {
            issue('fields[$i]', 'key / label / options / multiple', '多余字段');
          }
          final key = value['key'];
          final label = value['label'];
          final choices = value['options'];
          if (key is! String ||
              !const {'scene', 'equipment', 'minutes'}.contains(key) ||
              !keys.add(key)) {
            issue('fields[$i].key', '不重复的 scene / equipment / minutes', '$key');
          }
          if (label is! String ||
              label.trim().isEmpty ||
              length(label) > (english ? 6 : 20)) {
            issue(
              'fields[$i].label',
              english ? '1–6 word label' : '1–20 字标签',
              '$label',
            );
          }
          if (choices is! List ||
              choices.length < 2 ||
              choices.length > 64 ||
              choices.any(
                (x) => x is! String || x.trim().isEmpty || length(x) > 24,
              ) ||
              choices.toSet().length != choices.length) {
            issue('fields[$i].options', '2–64 个不重复的短选项', '$choices');
            continue;
          }
          if (value.containsKey('multiple') && value['multiple'] is! bool) {
            issue('fields[$i].multiple', 'boolean', '${value['multiple']}');
          }
          if (key != 'equipment' && value['multiple'] == true) {
            issue('fields[$i].multiple', '场景和时长单选', 'true');
          }
          if (key is String && label is String) {
            fields.add(
              AskUserField(
                key: key,
                label: label.trim(),
                options: choices.cast<String>(),
                multiple: value['multiple'] == true,
              ),
            );
          }
        }
      }
    }
    return AskUserGateResult._(
      errors.isEmpty
          ? AskUserQuestion._(
              (question as String).trim(),
              AskUserMode.values.byName(mode as String),
              options,
              raw['multiple'] == true,
              fields,
              language: language,
            )
          : null,
      errors,
    );
  }
}
