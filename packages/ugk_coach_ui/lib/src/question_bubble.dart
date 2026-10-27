import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoTheme;
import 'models.dart';
import 'theme.dart';
import 'message_widgets.dart';
import 'primitives.dart';

/// One validated ask_user question. It never invokes an agent or transport.
/// Answers stay disabled until the host has awaited its agent's send result.
class CoachQuestionBubble extends StatefulWidget {
  const CoachQuestionBubble({
    super.key,
    required this.question,
    required this.enabled,
    required this.onTextAnswer,
    required this.onChoiceAnswer,
    this.onFormAnswer,
    this.onSkip,
  });
  final CoachQuestionData question;
  final bool enabled;
  final Future<void> Function(String) onTextAnswer;
  final Future<void> Function(List<String>) onChoiceAnswer;
  final Future<void> Function(Map<String, List<String>>)? onFormAnswer;
  final Future<void> Function()? onSkip;
  @override
  State<CoachQuestionBubble> createState() => _CoachQuestionBubbleState();
}

class _CoachQuestionBubbleState extends State<CoachQuestionBubble> {
  final _text = TextEditingController();
  final _selected = <String>{};
  final _formSelected = <String, Set<String>>{};
  bool _submitting = false;
  int _questionGeneration = 0;
  bool get _active =>
      widget.enabled && !widget.question.answered && !_submitting;

  @override
  void initState() {
    super.initState();
    _restoreForm();
  }

  void _restoreForm() {
    _formSelected.clear();
    final question = widget.question;
    for (final field in question.fields) {
      final input =
          question.answered && question.answeredForm.containsKey(field.key)
          ? question.answeredForm[field.key]!
          : field.initialSelections;
      final valid = field.options.where(input.contains).toList();
      if (valid.isEmpty) continue;
      if (!field.multiple) {
        _formSelected[field.key] = {valid.first};
      } else if (valid.contains('徒手')) {
        _formSelected[field.key] = {'徒手'};
      } else {
        _formSelected[field.key] = valid.toSet();
      }
    }
    _filterEquipment();
  }

  List<String> _visibleOptions(CoachQuestionField field) {
    if (!widget.question.isConfirmation ||
        field.key != 'equipment' ||
        field.optionsByScene.isEmpty) {
      return field.options;
    }
    final scene = _formSelected['scene']?.firstOrNull;
    if (scene == null) return const [];
    final allowed = field.optionsByScene[scene] ?? const <String>[];
    return field.options.where(allowed.contains).toList();
  }

  void _filterEquipment() {
    if ((_formSelected['scene'] ?? const <String>{}).isEmpty) return;
    for (final field in widget.question.fields) {
      if (field.key == 'equipment') {
        final allowed = _visibleOptions(field).toSet();
        _formSelected[field.key]?.removeWhere(
          (value) => !allowed.contains(value),
        );
      }
    }
  }

  @override
  void didUpdateWidget(CoachQuestionBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.question.id != widget.question.id) {
      _questionGeneration++;
      _text.clear();
      _selected.clear();
      _restoreForm();
      _submitting = false;
    } else if (!oldWidget.question.answered &&
        widget.question.answered &&
        widget.question.answeredForm.isNotEmpty) {
      _restoreForm();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit(Future<void> Function() answer) async {
    if (!_active) return;
    final generation = _questionGeneration;
    setState(() => _submitting = true);
    try {
      await answer();
    } finally {
      if (mounted && generation == _questionGeneration) {
        setState(() => _submitting = false);
      }
    }
  }

  Map<String, List<String>> _currentAnswers() => {
    for (final field in widget.question.fields)
      field.key: field.options
          .where((_formSelected[field.key] ?? const <String>{}).contains)
          .toList(),
  };

  String _summary(Map<String, List<String>> answers) => [
    ...?answers['scene'],
    if ((answers['equipment'] ?? const <String>[]).isNotEmpty)
      answers['equipment']!.join('、'),
    ...?answers['minutes'],
  ].join(' · ');

  String _naturalAnswer(Map<String, List<String>> answers) {
    final equipment = answers['equipment'] ?? const <String>[];
    final equipmentText = equipment.isEmpty
        ? ''
        : equipment.length == 1 && equipment.first == '徒手'
        ? '徒手'
        : '有${equipment.join('和')}';
    return [
      ...?answers['scene'],
      if (equipmentText.isNotEmpty) equipmentText,
      ...?answers['minutes'],
    ].join('，');
  }

  Future<void> _confirm(Map<String, List<String>> answers) async {
    final callback = widget.onFormAnswer;
    await _submit(
      () => callback != null
          ? callback(answers)
          : widget.onTextAnswer(_naturalAnswer(answers)),
    );
  }

  Future<void> _confirmDefaults() async {
    await _submit(() => widget.onSkip?.call() ?? widget.onTextAnswer('按默认来'));
  }

  Future<void> _sendText() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    await _submit(() => widget.onTextAnswer(text));
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.question;
    final style = CoachUiTheme.of(context);
    if (q.mode == CoachQuestionMode.form && q.isConfirmation && q.answered) {
      final summary = _summary(q.answeredForm);
      return Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          key: ValueKey('question-summary-${q.id}'),
          decoration: BoxDecoration(
            color: style.colors.assistantBubble.withValues(alpha: 1),
            borderRadius: bubbleRadius(user: false),
            border: Border.all(color: style.colors.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              summary.isEmpty ? '已结束条件确认' : summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.typography.body.copyWith(color: style.colors.text),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .86,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: style.colors.assistantBubble.withValues(alpha: 1),
            borderRadius: bubbleRadius(user: false),
            border: Border.all(color: style.colors.outline),
            boxShadow: [
              BoxShadow(
                color: style.colors.shadow,
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  q.question,
                  style: style.typography.body.copyWith(
                    color: style.colors.text,
                  ),
                ),
                if (q.isConfirmation &&
                    q.focus != null &&
                    q.focus!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DecoratedBox(
                    key: ValueKey('question-focus-${q.id}'),
                    decoration: BoxDecoration(
                      color: style.colors.accentSoft,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        q.focus!,
                        style: style.typography.label.copyWith(
                          color: style.colors.accentText,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (q.mode == CoachQuestionMode.form) ...[
                  for (final field in q.fields) ...[
                    Text(
                      field.label,
                      style: style.typography.caption.copyWith(
                        color: style.colors.muted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < field.options.length; i++)
                          if (_visibleOptions(field).contains(field.options[i]))
                            CoachOptionPill(
                              key: ValueKey(
                                'question-field-${q.id}-${field.key}-$i',
                              ),
                              label:
                                  q.isConfirmation &&
                                      field.previousSelections.contains(
                                        field.options[i],
                                      )
                                  ? '${field.options[i]} · 上次'
                                  : field.options[i],
                              enabled: _active,
                              chosen:
                                  _formSelected[field.key]?.contains(
                                    field.options[i],
                                  ) ??
                                  false,
                              onTap: () {
                                if (!_active) return;
                                setState(() {
                                  final selected = _formSelected.putIfAbsent(
                                    field.key,
                                    () => <String>{},
                                  );
                                  final option = field.options[i];
                                  if (!field.multiple || option == '徒手') {
                                    selected
                                      ..clear()
                                      ..add(option);
                                  } else {
                                    selected.remove('徒手');
                                    if (!selected.add(option)) {
                                      selected.remove(option);
                                    }
                                  }
                                  if (field.key == 'scene') _filterEquipment();
                                });
                              },
                            ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!q.answered) ...[
                    if (q.isConfirmation)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          key: ValueKey('question-submit-${q.id}'),
                          onPressed:
                              _active &&
                                  q.fields.every(
                                    (field) =>
                                        _formSelected[field.key]?.isNotEmpty ??
                                        false,
                                  )
                              ? () => _confirm(_currentAnswers())
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: style.colors.accent,
                            foregroundColor: style.colors.onAccent,
                            minimumSize: const Size(0, 48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(q.submitLabel ?? '生成方案'),
                        ),
                      )
                    else
                      CoachTextAction(
                        key: ValueKey('question-submit-${q.id}'),
                        label: q.submitLabel ?? style.strings.submitAnswer,
                        onPressed:
                            _active &&
                                q.fields.every(
                                  (field) =>
                                      _formSelected[field.key]?.isNotEmpty ??
                                      false,
                                )
                            ? () => _submit(() {
                                final answers = {
                                  for (final field in q.fields)
                                    field.key: field.options
                                        .where(
                                          _formSelected[field.key]!.contains,
                                        )
                                        .toList(),
                                };
                                final callback = widget.onFormAnswer;
                                return callback != null
                                    ? callback(answers)
                                    : widget.onTextAnswer(
                                        q.fields
                                            .map(
                                              (field) =>
                                                  '${field.label}：${answers[field.key]!.join('、')}',
                                            )
                                            .join('；'),
                                      );
                              })
                            : null,
                      ),
                    if (q.showSkip)
                      CoachTextAction(
                        key: ValueKey('question-skip-${q.id}'),
                        label: q.isConfirmation && q.skipLabel == '直接出方案'
                            ? '按默认来'
                            : q.skipLabel,
                        onPressed: _active
                            ? q.isConfirmation
                                  ? _confirmDefaults
                                  : () => _submit(
                                      () => widget.onTextAnswer(q.skipLabel),
                                    )
                            : null,
                      ),
                  ],
                ],
                if (q.mode == CoachQuestionMode.text && !q.answered) ...[
                  // A solid backer keeps the original unfilled underline
                  // geometry, while host decoration/selection tints stay out.
                  ColoredBox(
                    color: style.colors.surfaceRaised.withValues(alpha: 1),
                    child: TextSelectionTheme(
                      data: TextSelectionThemeData(
                        cursorColor: style.colors.accent,
                        selectionColor: style.colors.accentSoft.withValues(
                          alpha: 1,
                        ),
                        selectionHandleColor: style.colors.accent,
                      ),
                      child: CupertinoTheme(
                        // iOS handles resolve through CupertinoTheme rather
                        // than Material's TextSelectionTheme.
                        data: CupertinoTheme.of(context).copyWith(
                          primaryColor: style.colors.accent,
                          selectionHandleColor: style.colors.accent,
                        ),
                        child: TextField(
                          key: ValueKey('question-input-${q.id}'),
                          controller: _text,
                          enabled: _active,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          style: style.typography.body.copyWith(
                            color: style.colors.text,
                          ),
                          cursorColor: style.colors.accent,
                          decoration: InputDecoration(
                            filled: false,
                            fillColor: style.colors.surfaceRaised.withValues(
                              alpha: 1,
                            ),
                            focusColor: style.colors.surfaceRaised.withValues(
                              alpha: 1,
                            ),
                            hoverColor: style.colors.surfaceRaised.withValues(
                              alpha: 1,
                            ),
                            hintText: style.strings.answerHint,
                            hintStyle: style.typography.body.copyWith(
                              color: style.colors.muted,
                            ),
                            enabledBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                color: style.colors.outline,
                              ),
                            ),
                            disabledBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                color: style.colors.outline,
                              ),
                            ),
                            focusedBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                color: style.colors.accent,
                              ),
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _sendText(),
                        ),
                      ),
                    ),
                  ),
                  CoachTextAction(
                    key: ValueKey('question-submit-${q.id}'),
                    label: style.strings.submitAnswer,
                    onPressed: _active && _text.text.trim().isNotEmpty
                        ? _sendText
                        : null,
                  ),
                ],
                if (q.mode == CoachQuestionMode.choice) ...[
                  if (q.multiple && !q.answered)
                    Text(
                      style.strings.multipleHint,
                      style: style.typography.caption.copyWith(
                        color: style.colors.muted,
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < q.options.length; i++)
                        CoachOptionPill(
                          key: ValueKey('question-option-${q.id}-$i'),
                          label: q.options[i],
                          enabled: _active,
                          chosen: q.answered
                              ? q.answeredChoices.contains(q.options[i])
                              : _selected.contains(q.options[i]),
                          dimmed:
                              q.answered &&
                              !q.answeredChoices.contains(q.options[i]),
                          onTap: () {
                            if (!_active) return;
                            final option = q.options[i];
                            if (!q.multiple) {
                              _submit(() => widget.onChoiceAnswer([option]));
                            } else {
                              setState(() {
                                if (!_selected.add(option)) {
                                  _selected.remove(option);
                                }
                              });
                            }
                          },
                        ),
                    ],
                  ),
                  if (q.multiple && !q.answered)
                    CoachTextAction(
                      key: ValueKey('question-submit-${q.id}'),
                      label: style.strings.submitAnswer,
                      onPressed: _active && _selected.isNotEmpty
                          ? () => _submit(
                              () => widget.onChoiceAnswer(
                                q.options.where(_selected.contains).toList(),
                              ),
                            )
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
