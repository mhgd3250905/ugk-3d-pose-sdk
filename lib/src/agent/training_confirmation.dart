import '../catalog/catalog.dart';
import '../plan/coach_context.dart';
import '../tools/ask_user.dart';

const _sceneLabels = {'office': '办公室', 'home': '家里', 'gym': '健身房'};

/// Validates the selections against the exact pending card before mapping
/// human-facing labels to an authoritative task context.
CoachContext? confirmedTrainingContext(
  AskUserQuestion question,
  Map<String, List<String>> values,
  CoachContext base,
  Catalog catalog,
) {
  if (!question.isConfirmation ||
      values.length != 3 ||
      !values.keys.toSet().containsAll(const {
        'scene',
        'equipment',
        'minutes',
      })) {
    return null;
  }
  for (final field in question.fields) {
    final selected = values[field.key];
    if (selected == null ||
        selected.isEmpty ||
        selected.toSet().length != selected.length ||
        (!field.multiple && selected.length != 1) ||
        selected.any((item) => !field.options.contains(item))) {
      return null;
    }
  }
  final sceneLabel = values['scene']!.single;
  final scene = _sceneLabels.entries
      .where((e) => e.value == sceneLabel)
      .firstOrNull
      ?.key;
  final equipmentField = question.fields.firstWhere(
    (field) => field.key == 'equipment',
  );
  final gear = values['equipment']!;
  if (scene == null ||
      (gear.contains('徒手') && gear.length != 1) ||
      gear.any(
        (item) =>
            !(equipmentField.optionsByScene[sceneLabel] ?? const <String>[])
                .contains(item),
      )) {
    return null;
  }
  final reverseLabels = {
    for (final e in catalog.taxonomy.equipment.entries) e.value: e.key,
  };
  if (gear
      .where((item) => item != '徒手')
      .any((item) => !reverseLabels.containsKey(item))) {
    return null;
  }
  final label = values['minutes']!.single;
  final token = label.endsWith('分钟')
      ? label.substring(0, label.length - 2).trim()
      : '';
  final minutes = int.tryParse(
    token.endsWith('+') ? token.substring(0, token.length - 1) : token,
  );
  if (minutes == null || minutes <= 0) return null;
  return CoachContext(
    scene: scene,
    equipment: {
      for (final item in gear)
        if (item != '徒手') reverseLabels[item]!,
    },
    minutes: minutes,
    avoid: base.avoid,
    level: base.level,
    goal: base.goal,
    language: base.language,
    notes: base.notes,
  );
}

/// Localized choices corresponding to the authoritative confirmed context.
Map<String, List<String>> trainingSelections(
  CoachContext context,
  Catalog catalog,
) {
  final scene = _sceneLabels[context.scene];
  final equipment = context.equipment;
  final minutes = context.minutes;
  return Map.unmodifiable({
    'scene': List<String>.unmodifiable([?scene]),
    'equipment': List<String>.unmodifiable(
      equipment == null
          ? []
          : equipment.isEmpty
          ? ['徒手']
          : [for (final id in equipment) catalog.taxonomy.equipmentLabel(id)],
    ),
    'minutes': List<String>.unmodifiable([
      if (minutes != null) minutes == 20 ? '20+ 分钟' : '$minutes 分钟',
    ]),
  });
}
