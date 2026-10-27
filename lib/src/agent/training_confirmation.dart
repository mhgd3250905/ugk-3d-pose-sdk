import '../catalog/catalog.dart';
import '../plan/coach_context.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../tools/ask_user.dart';
import 'training_parameters.dart';

const _sceneLabels = {'office': '办公室', 'home': '家里', 'gym': '健身房'};

/// Constructs a deterministic confirmation from a trusted catalog. Earlier
/// values are suggestions only; only [current] contains this task's facts.
AskUserQuestion buildTrainingConfirmation({
  required TrainingParameters current,
  required TrainingParameters previous,
  required Catalog catalog,
  required CoachProfile profile,
  String? focus,
}) {
  final scenes = <String>[
    for (final id in ['office', 'home', 'gym'])
      if (profile.scenes.containsKey(id)) _sceneLabels[id]!,
  ];
  final used = <String>{
    for (final drill in profile.scope(catalog)) ...drill.equipment,
    for (final rule in profile.scenes.values) ...rule.assumedEquipment,
  }..remove('none');
  final ids = [
    for (final id in used)
      if (catalog.taxonomy.equipment.containsKey(id)) id,
  ]..sort();
  final labels = <String, String>{
    for (final id in ids) id: catalog.taxonomy.equipmentLabel(id),
  };
  final byScene = <String, List<String>>{};
  for (final entry in _sceneLabels.entries) {
    final rule = profile.scenes[entry.key];
    if (rule == null) continue;
    final accepted = rule.acceptDrillScenes.isEmpty
        ? {entry.key}
        : rule.acceptDrillScenes;
    final sceneEquipment = <String>{
      ...rule.assumedEquipment,
      for (final drill in profile.scope(catalog))
        if (drill.scenes.any(accepted.contains) &&
            !(rule.forbidFloor &&
                catalog.taxonomy.floorPositions.contains(drill.position)) &&
            !rule.forbidPositions.contains(drill.position))
          ...drill.equipment,
    };
    byScene[entry.value] = [
      '徒手',
      for (final id in ids)
        if (sceneEquipment.contains(id)) labels[id]!,
    ];
  }
  final equipmentOptions = ['徒手', ...labels.values];
  final minutesOptions = ['5 分钟', '10 分钟', '15 分钟', '20+ 分钟'];
  String? scene(CoachContext c) => _sceneLabels[c.scene];
  String? minutes(CoachContext c) {
    final n = c.minutes;
    if (n == null) return null;
    if (n == 20) return '20+ 分钟';
    final label = '$n 分钟';
    if (!minutesOptions.contains(label)) minutesOptions.add(label);
    return label;
  }

  List<String> equipment(CoachContext c) {
    if (c.equipment == null) return [];
    if (c.equipment!.isEmpty) return ['徒手'];
    return [
      for (final id in c.equipment!)
        if (labels.containsKey(id)) labels[id]!,
    ];
  }

  final currentScene = scene(current.context);
  final previousScene = scene(previous.context);
  final selectedScene = currentScene ?? previousScene;
  final nowEquipment = equipment(current.context);
  final oldEquipment = equipment(previous.context);
  final resolved = current.resolved(profile, clarificationFinished: true);
  final defaultScene = scene(resolved);
  // A user can own equipment even if the catalog has no suitable exercise
  // for it in that scene. Preserve explicit facts in this card, while other
  // scene choices continue to follow the catalog's actual eligible actions.
  for (final key in {selectedScene, defaultScene}) {
    if (key != null && byScene.containsKey(key)) {
      for (final value in nowEquipment) {
        if (!byScene[key]!.contains(value)) byScene[key]!.add(value);
      }
    }
  }
  final allowed = byScene[selectedScene] ?? equipmentOptions;
  final selectedEquipment =
      (nowEquipment.isNotEmpty ? nowEquipment : oldEquipment)
          .where(allowed.contains)
          .toList();
  final nowMinutes = minutes(current.context);
  final oldMinutes = minutes(previous.context);
  final defaultMinutes = minutes(resolved);
  return AskUserQuestion.confirmation(
    question: focus == null ? '先确认一下训练条件' : '先确认一下$focus训练条件',
    focus: focus,
    fields: [
      AskUserField(
        key: 'scene',
        label: '场景',
        options: scenes,
        preselected: [
          if (selectedScene != null && scenes.contains(selectedScene))
            selectedScene,
        ],
        previousSelections: [
          if (currentScene == null &&
              previousScene != null &&
              scenes.contains(previousScene))
            previousScene,
        ],
      ),
      AskUserField(
        key: 'equipment',
        label: '器械',
        options: equipmentOptions,
        multiple: true,
        optionsByScene: byScene,
        preselected: selectedEquipment,
        previousSelections: nowEquipment.isEmpty ? selectedEquipment : const [],
      ),
      AskUserField(
        key: 'minutes',
        label: '时长',
        options: minutesOptions,
        preselected: [?(nowMinutes ?? oldMinutes)],
        previousSelections: [
          if (nowMinutes == null && oldMinutes != null) oldMinutes,
        ],
      ),
    ],
    defaultSelections: {
      'scene': [?defaultScene],
      'equipment': equipment(resolved),
      'minutes': [?defaultMinutes],
    },
  );
}

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
  final m = RegExp(r'^(\d+)\+?\s*分钟$').firstMatch(values['minutes']!.single);
  final minutes = m == null ? null : int.tryParse(m.group(1)!);
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

/// Conservative body-region extraction. Null means no verified focus.
String? trainingFocus(String text) {
  final matches = RegExp(
    r'大腿内侧|大腿后侧|大腿前侧|髋屈肌|髋前侧|内收肌|肩颈|肩膀|肩部|颈部|脖子|背部|后背|腰部|腰背|胸部|手臂|手腕|核心|腹部|臀腿|臀部|腿部|大腿|小腿|髋部|髋关节|开胯|全身|肩|颈|背|腰|胸|腹|臀|腿|髋',
  ).allMatches(text);
  if (matches.isEmpty) return null;
  final word = matches.last.group(0)!;
  if (const {'肩膀', '肩部'}.contains(word)) return '肩';
  if (const {'颈部', '脖子'}.contains(word)) return '颈';
  if (const {'背部', '后背'}.contains(word)) return '背';
  if (word == '腹部') return '核心';
  if (const {'臀部', '臀'}.contains(word)) return '臀';
  if (const {'髋部', '髋关节', '开胯'}.contains(word)) return '髋';
  return word;
}

/// A distinct training objective can start a new task even without the words
/// "plan" or "routine". Questions about the term are classified separately.
String? trainingGoal(String text) {
  final matches = RegExp(
    r'减脂|燃脂|增肌|改善体能|提升体能|体能|耐力|塑形|力量训练|增强力量',
  ).allMatches(text);
  if (matches.isEmpty) return null;
  final goal = matches.last.group(0)!;
  if (goal == '燃脂') return '减脂';
  if (goal == '改善体能' || goal == '提升体能') return '体能';
  if (goal == '力量训练' || goal == '增强力量') return '力量';
  return goal;
}

/// A preset is offered only if trusted catalog metadata proves a majority of
/// the actual actions target the named focus. Segments replace the parent
/// action when present; unknown or unmapped actions count against a match.
Set<String> _focusGroups(String? focus) => switch (focus) {
  '大腿内侧' || '内收肌' => const {'adductors'},
  '大腿后侧' => const {'hamstrings'},
  '大腿前侧' => const {'quadriceps'},
  '髋屈肌' || '髋前侧' => const {'hip-flexors'},
  '核心' => const {'abs', 'obliques', 'core'},
  '臀' || '臀腿' => const {'glute-max', 'glute-med', 'glutes'},
  '髋' => const {'hip-flexors', 'hip-abductors', 'adductors'},
  '大腿' || '腿部' || '腿' => const {'quadriceps', 'hamstrings', 'adductors'},
  '肩' => const {'deltoids'},
  '肩颈' => const {'scapular', 'deltoids'},
  '小腿' => const {'calves', 'tibialis'},
  '腰' || '腰部' => const {'erectors'},
  '背' || '腰背' => const {'lats', 'erectors', 'scapular'},
  '胸' || '胸部' => const {'chest', 'pectorals'},
  _ => const <String>{},
};

({int matching, int total}) _focusCounts(
  TrainingPlan plan,
  Catalog catalog,
  Set<String> groups,
) {
  var matching = 0;
  var total = 0;
  for (final item in plan.items) {
    final segmentIds = item.segments.map((s) => s.exerciseId).toList();
    final ids = segmentIds.isEmpty ? [item.exerciseId] : segmentIds;
    for (final id in ids) {
      total++;
      final drill = catalog[id];
      if (drill != null && drill.muscleGroups.any(groups.contains)) matching++;
    }
  }
  return (matching: matching, total: total);
}

bool presetMatchesFocus(TrainingPlan plan, Catalog catalog, String? focus) {
  final groups = _focusGroups(focus);
  if (groups.isEmpty) return false;
  final counts = _focusCounts(plan, catalog, groups);
  return counts.total > 0 && counts.matching * 2 > counts.total;
}

/// Null means the focus has no trustworthy mapping and cannot be enforced.
bool? planTouchesFocus(TrainingPlan plan, Catalog catalog, String? focus) {
  final groups = _focusGroups(focus);
  if (groups.isEmpty) return null;
  return _focusCounts(plan, catalog, groups).matching > 0;
}

/// Explicitly denied symptoms do not raise the emergency gate. Positive or
/// ambiguous symptoms remain conservative; this does not diagnose the user.
bool hasTrainingRedFlag(String text) {
  final pattern = RegExp(
    r'刺痛|麻木|手脚麻|胳膊麻|肢体麻|腿麻|手麻|脚麻|胸闷|胸痛|放射痛|肿胀|刚受伤|刚受了伤|术后|手术后|孕期|怀孕|产后|头晕|眩晕',
  );
  for (final match in pattern.allMatches(text)) {
    final prefix = text
        .substring(0, match.start)
        .split(RegExp(r'[，,。；;、\n]'))
        .last;
    if (RegExp(r'(?:没有|无|未曾|未出现|不曾|否认|并无)\s*$').hasMatch(prefix)) continue;
    return true;
  }
  return false;
}
