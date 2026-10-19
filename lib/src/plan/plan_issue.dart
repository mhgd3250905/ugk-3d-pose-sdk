/// 校验问题。[code] 稳定（测试、统计、App 自定义处理用），[message] 是给人和模型看的中文。
library;

enum IssueSeverity { error, warning }

class PlanIssue {
  const PlanIssue(this.code, this.message, {this.path, this.exerciseId, this.severity = IssueSeverity.error});
  const PlanIssue.warning(this.code, this.message, {this.path, this.exerciseId}) : severity = IssueSeverity.warning;

  final String code;
  final String message;

  /// JSON 路径，如 `plan.blocks[1].items[0].reps`。
  final String? path;
  final String? exerciseId;
  final IssueSeverity severity;

  bool get isError => severity == IssueSeverity.error;

  /// E_JSON / E_SCHEMA / E_DOSE …（见 [IssueCodes.category]）。
  String get category => IssueCodes.category(code);

  /// 回传给模型的一行：`[reps_range] plan.blocks[1].items[0].reps：徒手深蹲 次数 40 超出 1–30`。
  String get feedbackLine => '[$code]${path == null ? '' : ' $path'}：$message';

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (path != null) 'path': path,
    if (exerciseId != null) 'exerciseId': exerciseId,
    'severity': severity.name,
  };

  @override
  String toString() => '${severity.name} $feedbackLine';
}

/// 内置问题代码。
abstract final class IssueCodes {
  // 输出结构
  static const notJson = 'not_json';
  static const envelope = 'envelope';
  static const schema = 'schema';
  // 计划规则
  static const schemaVersion = 'schema_version';
  static const emptyPlan = 'empty_plan';
  static const emptyBlock = 'empty_block';
  static const tooManyItems = 'too_many_items';
  static const blockOrder = 'block_order';
  static const unknownExercise = 'unknown_exercise';
  static const outOfProfile = 'out_of_profile';
  static const modeMismatch = 'mode_mismatch';
  static const setsRange = 'sets_range';
  static const repsRange = 'reps_range';
  static const workSecondsRange = 'work_seconds_range';
  static const restRange = 'rest_range';
  static const roundsRange = 'rounds_range';
  static const restBetweenRoundsRange = 'rest_between_rounds_range';
  static const perSide = 'per_side';
  static const equipment = 'equipment';
  static const scene = 'scene';
  static const position = 'position';
  static const avoid = 'avoid';
  static const goal = 'goal';
  static const sceneUnsupported = 'scene_unsupported';
  static const minutesRange = 'minutes_range';
  // 警告
  static const levelHigh = 'level_high';
  static const duration = 'duration';
  static const duplicateExercise = 'duplicate_exercise';
  static const doseRange = 'dose_range';
  static const equipmentUndeclared = 'equipment_undeclared';
  static const avoidVocabulary = 'avoid_vocabulary';
  static const goalOutOfProfile = 'goal_out_of_profile';

  /// 粗分类，与 ai-coach-eval `tools/validate.py` 的 E_* 代码一一对应（评测与线上统计口径一致）。
  static String category(String code) => switch (code) {
    notJson || envelope => 'E_JSON',
    schema || schemaVersion || emptyPlan || emptyBlock || goal => 'E_SCHEMA',
    unknownExercise => 'E_UNKNOWN',
    outOfProfile => 'E_SCOPE',
    modeMismatch || setsRange || repsRange || workSecondsRange || restRange || roundsRange ||
        restBetweenRoundsRange || tooManyItems || minutesRange => 'E_DOSE',
    perSide => 'E_SIDE',
    avoid => 'E_AVOID',
    equipment => 'E_EQUIP',
    scene || position || sceneUnsupported => 'E_SCENE',
    blockOrder => 'E_ORDER',
    _ => 'W',
  };
}
