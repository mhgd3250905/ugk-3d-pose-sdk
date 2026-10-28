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
  AskUserGateResult._(
    this.question,
    List<PlanIssue> errors, {
    List<String> notes = const [],
  }) : errors = List.unmodifiable(errors),
       notes = List.unmodifiable(notes);
  final AskUserQuestion? question;
  final List<PlanIssue> errors;
  final List<String> notes;
  bool get ok => question != null && errors.isEmpty;
}

abstract final class AskUserGate {
  /// Normalize presentation without changing the question or option meanings.
  /// An unreadable payload or a missing question still cannot be invented.
  static AskUserGateResult check(String arguments, {String language = 'zh'}) {
    final english = language.toLowerCase().startsWith('en');
    final notes = <String>[];
    int length(String value) => english
        ? value.trim().split(RegExp(r'\s+')).length
        : value.runes.length;
    String label(String value, int maximum) => english
        ? value.trim().split(RegExp(r'\s+')).take(maximum).join(' ')
        : String.fromCharCodes(value.trim().runes.take(maximum));
    AskUserGateResult invalid(String path, String actual, {String? code}) =>
        AskUserGateResult._(null, [
          PlanIssue(
            code ?? IssueCodes.schema,
            'ask_user 的 $path 不合规',
            path: path,
            expected: '合法 JSON 对象及非空 question',
            actual: actual,
            fix: '提供用户能够回答的非空问题。',
          ),
        ]);
    Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException {
      return invalid('arguments', '非法 JSON', code: IssueCodes.invalidJson);
    }
    if (decoded is! Map<String, dynamic>) return invalid('arguments', '不是对象');
    final raw = decoded;
    final value = raw['question'];
    if (value is! String || value.trim().isEmpty) {
      return invalid('question', '缺少非空问题');
    }
    var question = value.trim();
    var mode = raw['mode'];
    if (!{'text', 'choice', 'form'}.contains(mode)) {
      mode = raw['fields'] is List
          ? 'form'
          : raw['options'] != null
          ? 'choice'
          : 'text';
      notes.add('已根据提供的数据结构补齐问题模式。');
    }
    if (raw.keys.any(
      (key) => !{
        'question',
        'mode',
        'options',
        'multiple',
        'fields',
        'skipLabel',
      }.contains(key),
    )) {
      notes.add('已忽略不影响问题含义的附加字段。');
    }
    Object? listValue(Object? input) {
      if (input is String) {
        try {
          return jsonDecode(input);
        } on FormatException {
          return input;
        }
      }
      return input;
    }

    List<String> options(Object? input) {
      final parsed = listValue(input);
      final values = parsed is List
          ? parsed
          : parsed == null
          ? const []
          : [parsed];
      final result = <String>[];
      for (final item in values) {
        if (item is! String && item is! num) continue;
        final text = item.toString().trim();
        if (text.isNotEmpty && !result.contains(text)) result.add(text);
      }
      return result;
    }

    bool boolean(Object? input) => input == true || input == 'true';
    final choices = <String>[];
    final fields = <AskUserField>[];
    final textParts = <String>[];
    var textFallback = false;
    if (mode == 'choice') {
      choices.addAll(options(raw['options']));
      final original = listValue(raw['options']);
      if (original is! List ||
          original.length != choices.length ||
          raw['multiple'] is! bool && raw.containsKey('multiple')) {
        notes.add('已规范化选项数组、重复项或多选标记。');
      }
      if (choices.length < 2 ||
          choices.length > 6 ||
          choices.any((v) => length(v) > 12)) {
        textFallback = true;
        if (choices.isNotEmpty) {
          textParts.add(choices.join(english ? '; ' : '；'));
        }
      }
    } else if (mode == 'form') {
      final parsed = listValue(raw['fields']);
      final source = parsed is List ? parsed : const [];
      final keys = <String>{};
      for (final input in source) {
        if (input is! Map) {
          textFallback = true;
          continue;
        }
        final key = input['key'];
        final rawLabel = input['label'];
        final fullLabel = rawLabel is String && rawLabel.trim().isNotEmpty
            ? rawLabel.trim()
            : key is String
            ? key
            : '';
        final values = options(input['options']);
        if (fullLabel.isNotEmpty) {
          textParts.add('$fullLabel: ${values.join(english ? "; " : "；")}');
        }
        if (key is! String ||
            !{'scene', 'equipment', 'minutes'}.contains(key) ||
            !keys.add(key) ||
            values.length < 2 ||
            values.length > 64 ||
            values.any((v) => length(v) > 24)) {
          textFallback = true;
          continue;
        }
        final shortLabel = label(fullLabel, english ? 6 : 20);
        if (shortLabel != fullLabel) notes.add('已缩短显示标签，完整条件保留在问题中。');
        fields.add(
          AskUserField(
            key: key,
            label: shortLabel,
            options: values,
            multiple: key == 'equipment' && boolean(input['multiple']),
          ),
        );
        if (input.keys.any(
              (key) => !{'key', 'label', 'options', 'multiple'}.contains(key),
            ) ||
            input['multiple'] is! bool ||
            input['options'] is! List ||
            input['options'] is List &&
                (input['options'] as List).length != values.length) {
          notes.add('已规范化表单字段、选项及选择模式。');
        }
      }
      if (source.isEmpty ||
          source.length > 3 ||
          fields.length != source.length) {
        textFallback = true;
      }
      final skip = english ? 'Show suggestions' : '直接出方案';
      if (raw['skipLabel'] != null && raw['skipLabel'] != skip) {
        notes.add('已使用标准跳过按钮文案。');
      }
      if (raw.containsKey('options') || raw.containsKey('multiple')) {
        notes.add('已忽略表单模式不使用的顶层选项字段。');
      }
      if (notes.any((note) => note.startsWith('已缩短'))) {
        question += '\n${textParts.join('\n')}';
      }
    } else if (raw.containsKey('options') ||
        raw.containsKey('multiple') ||
        raw.containsKey('fields') ||
        raw.containsKey('skipLabel')) {
      notes.add('已忽略文字问题不使用的呈现字段。');
    }
    if (textFallback) {
      mode = 'text';
      if (textParts.isNotEmpty) question += '\n${textParts.join('\n')}';
      choices.clear();
      fields.clear();
      notes.add('选项超出控件形状时改为文字问答，完整选项含义已保留。');
    }
    return AskUserGateResult._(
      AskUserQuestion._(
        question,
        AskUserMode.values.byName(mode as String),
        choices,
        mode == 'choice' && boolean(raw['multiple']),
        fields,
        language: language,
      ),
      const [],
      notes: notes.toSet().toList(),
    );
  }
}
