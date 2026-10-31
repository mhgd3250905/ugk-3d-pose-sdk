import 'session_state.dart';

// Presentation rules extracted from Sport-Helper@13c0bb4's task bubble.
/// Optional host copy for a [CoachTaskSummary], without reimplementing its rules.
///
/// Every callback receives the accepted Chinese fallback. Unknown parameter
/// values are filtered before [parameterLabel] is called. Callback values are
/// display-only and do not change the source task, parameters or picked IDs.
class CoachTaskSummaryCopy {
  const CoachTaskSummaryCopy({
    this.stageLabel,
    this.parameterLabel,
    this.status,
    this.title,
  });

  /// Formats a canonical stage ID and its default label.
  final String Function(String id, String fallback)? stageLabel;

  /// Formats a valid sourced field, its immutable value and default label.
  ///
  /// This also controls level labels; [levelZh] remains the default mapping.
  /// Returning an empty string omits the parameter from presentation.
  final String Function(String field, Object? value, String fallback)?
  parameterLabel;

  /// Formats the four-band phase, number of picks and sourced status sentence.
  final String Function(int phase, int pickedCount, String fallback)? status;

  /// Formats the already localized title fragments and its default sentence.
  final String Function(String? scene, String? goal, String fallback)? title;
}

/// Immutable, presentation-ready facts for a coach preparation card.
///
/// This pure Dart projection preserves SmartFit's task sentences and sourced
/// parameter labels. It does not advance a task, select exercises or admit a
/// delivered reply. A UI can consume the structural records without depending
/// on the session model, and can decide when to show visual completion.
class CoachTaskSummary {
  CoachTaskSummary._({
    required List<({String id, String label, String status})> stages,
    required this.phase,
    required this.status,
    required List<({String field, String label, bool user})> parameters,
    required this.sceneLabel,
    required this.goalLabel,
    required this.title,
    required List<String> picks,
    required this.complete,
  }) : stages = List.unmodifiable(stages),
       parameters = List.unmodifiable(parameters),
       picks = List.unmodifiable(picks);

  /// Projects [sessionState], using [task] in preference to its task snapshot.
  ///
  /// Null input is the initial waiting state: all six stages are pending,
  /// there are no parameter labels or picks, and the status reads
  /// `读懂你的需求`. Only `source == 'user'` highlights a parameter.
  factory CoachTaskSummary.fromState(
    CoachSessionState? sessionState, {
    CoachTaskState? task,
    CoachTaskSummaryCopy copy = const CoachTaskSummaryCopy(),
  }) {
    final nodes =
        (task ?? sessionState?.task)?.nodes ?? const <CoachNodeState>[];
    final node =
        nodes.where((node) => node.status == 'current').firstOrNull ??
        nodes.where(_done).lastOrNull;
    final phase = switch (node?.id) {
      'actions' => 1,
      'planning' => 2,
      'review' => 3,
      'output' => 4,
      _ => 0,
    };
    final picks = sessionState?.picks ?? const <String>[];
    final parameters = _parameterLabels(sessionState?.params ?? const {}, copy);
    final scene = parameters
        .where((parameter) => parameter.field == 'scene')
        .firstOrNull
        ?.label;
    final goal = parameters
        .where((parameter) => parameter.field == 'goal')
        .firstOrNull
        ?.label;
    final status = switch (phase) {
      1 when picks.isNotEmpty => '挑好了 ${picks.length} 个动作',
      2 => '安排顺序和时长',
      3 => '最后检查一遍',
      4 => '马上就好',
      _ => '读懂你的需求',
    };
    final title = scene != null && goal != null
        ? '为你准备 · $scene$goal'
        : '正在想怎么练';
    return CoachTaskSummary._(
      stages: [
        for (final entry in _stages.entries)
          (
            id: entry.key,
            label: copy.stageLabel?.call(entry.key, entry.value) ?? entry.value,
            status: _stageStatus(
              nodes.where((node) => node.id == entry.key).firstOrNull,
            ),
          ),
      ],
      phase: phase,
      status: copy.status?.call(phase, picks.length, status) ?? status,
      parameters: parameters,
      sceneLabel: scene,
      goalLabel: goal,
      title: copy.title?.call(scene, goal, title) ?? title,
      picks: picks,
      complete: nodes.any((node) => node.id == 'output' && _done(node)),
    );
  }

  /// The six ordered stage IDs and their labels (Chinese by default).
  ///
  /// Status is always `done`, `current` or `pending`. The task's `updated`
  /// status is presented as `done`; missing and unknown statuses are pending.
  /// Internal node stamps are deliberately excluded.
  final List<({String id, String label, String status})> stages;

  /// Number of filled progress bands (0–4), separate from the six stages.
  ///
  /// Follows the first current node, otherwise the last done/updated node in
  /// source order, matching the accepted preparation-card behavior.
  final int phase;

  /// Sourced status sentence, including the empty-picks fallback.
  final String status;

  /// Displayable parameter labels in scene, goal, equipment, level, limits order.
  ///
  /// Unknown raw identifiers are omitted rather than turned into default tags.
  /// `user` is true only for a parameter explicitly sourced from the user.
  final List<({String field, String label, bool user})> parameters;

  /// Scene and purpose labels used in the preparation title, when known.
  final String? sceneLabel, goalLabel;

  /// Picked action IDs in their original order, without consulting a library.
  final List<String> picks;

  /// Whether the output node is done or updated.
  ///
  /// This is a data fact, not a marker that a delivered reply was admitted.
  final bool complete;

  /// The accepted Chinese title, or host-formatted presentation copy.
  final String title;
}

/// The accepted Chinese level label: 1 入门, 2 基础, all other values 进阶.
String levelZh(int level) => switch (level) {
  1 => '入门',
  2 => '基础',
  _ => '进阶',
};

const _stages = {
  'understand': '理解需求',
  'parameters': '确认参数',
  'actions': '挑选动作',
  'planning': '安排计划',
  'review': '检查计划',
  'output': '交付结果',
};

bool _done(CoachNodeState node) =>
    node.status == 'done' || node.status == 'updated';

String _stageStatus(CoachNodeState? node) => node == null
    ? 'pending'
    : _done(node)
    ? 'done'
    : node.status == 'current'
    ? 'current'
    : 'pending';

List<({String field, String label, bool user})> _parameterLabels(
  Map<String, CoachParamValue> params,
  CoachTaskSummaryCopy copy,
) {
  final result = <({String field, String label, bool user})>[];
  for (final field in ['scene', 'goal', 'equipment', 'level', 'limits']) {
    final param = params[field];
    if (param == null) continue;
    final value = param.value;
    final label = switch (field) {
      'scene' => const {
        'home': '居家',
        'office': '办公室',
        'gym': '健身房',
        'outdoor': '户外',
      }[value],
      'goal' =>
        value is List<Object?>
            ? [for (final code in value) ?_purposes[code]].firstOrNull
            : null,
      'equipment' => _equipmentLabel(value),
      'level' => value is int ? levelZh(value) : null,
      'limits' => _limitsLabel(value),
      _ => null,
    };
    if (label != null && label.isNotEmpty) {
      final text = copy.parameterLabel?.call(field, value, label) ?? label;
      if (text.isNotEmpty) {
        result.add((field: field, label: text, user: param.source == 'user'));
      }
    }
  }
  return result;
}

const _purposes = {
  'purpose.strength': '力量',
  'purpose.core': '核心',
  'purpose.cardio': '有氧',
  'purpose.mobility': '灵活',
  'purpose.stretch': '拉伸',
};

String? _equipmentLabel(Object? value) {
  if (value is! List<Object?>) return null;
  if (value.isEmpty || value.every((code) => code == 'none')) return '徒手';
  final code = value.whereType<String>().firstOrNull;
  if (code == null) return null;
  final id = code.startsWith('equip.')
      ? code.substring('equip.'.length).replaceAll('_', '-')
      : code;
  final translated = (_equipment[id] ?? id).split(RegExp('[（(]')).first.trim();
  return translated == id && RegExp(r'[A-Za-z]').hasMatch(translated)
      ? null
      : translated;
}

// Preserves the labels from SmartFit's Equipment/equipmentLabel projection.
const _equipment = {
  'none': '徒手',
  'mat': '瑜伽垫',
  'chair': '椅子',
  'wall': '墙',
  'band': '弹力带',
  'dumbbell': '哑铃',
  'block': '瑜伽砖',
  'slider': '滑垫',
  'cable': '绳索器械',
  'dip-bars': '双杠',
  'foam-roller': '泡沫轴',
  'ghd': 'GHD训练器',
  'hip-abductor-machine': '髋外展训练器',
  'kettlebell': '壶铃',
  'landmine': '地雷架',
  'leg-extension-machine': '腿屈伸训练器',
  'parallettes': '小双杠',
  'pullup-bar': '单杠',
  'reverse-hyper': '反向挺身器',
  'rings': '吊环',
  'roman-chair': '罗马椅',
  'swiss-ball': '健身球',
};

String? _limitsLabel(Object? value) {
  if (value is! List<Object?>) return null;
  if (value.isEmpty) return '无伤痛';
  const labels = {
    'limit.knee': '膝',
    'limit.waist': '腰',
    'limit.shoulder': '肩',
    'limit.wrist': '手腕',
    'limit.neck': '颈',
    'limit.hip': '髋',
    'limit.inner_thigh': '大腿内侧',
  };
  final known = [for (final code in value) ?labels[code]];
  return known.length == value.length ? known.join('、') : '身体限制';
}
