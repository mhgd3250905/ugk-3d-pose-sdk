/// Deterministic checks of the structured task state, without interpreting text.
library;

import '../catalog/catalog.dart';
import '../profile/coach_profile.dart';
import 'action_tags.dart';
import 'agent_task.dart';
import 'session_state.dart';

class NodeGates {
  NodeGates(this.profile, this.catalog, {required this.minPicks})
    : tags = ActionTags(profile, catalog);

  final CoachProfile profile;
  final Catalog catalog;
  final int minPicks;
  final ActionTags tags;

  NodeResult check(
    CoachSessionState state,
    String node, {
    List<String>? picks,
    String language = 'zh',
    String? planId,
  }) {
    final task = state.task;
    final current = task?.nodes.where((n) => n.status == 'current').firstOrNull;
    if (task == null ||
        current == null ||
        node != current.id ||
        node == 'output') {
      return NodeResult(
        state,
        error: nodeError(
          'wrong_node',
          'node',
          current?.id ?? '先创建任务',
          node,
          '按当前节点顺序打卡；output 在交付时自动完成。',
        ),
      );
    }
    var next = state;
    final en = language.toLowerCase().startsWith('en');
    final warnings = <String>[];
    String stamp;
    switch (node) {
      case 'understand':
        stamp = task.type == 'plan'
            ? (en ? 'Preparing a plan' : '准备训练计划')
            : (en ? 'Recommending actions' : '准备推荐动作');
      case 'parameters':
        final required = task.type == 'plan'
            ? ['scene', 'goal', 'minutes']
            : ['goal'];
        final missing = required.where((key) {
          final v = state.params[key]?.value;
          return v == null || (v is List && v.isEmpty);
        }).toList();
        if (missing.isNotEmpty) {
          return NodeResult(
            state,
            error: nodeError(
              'missing_parameters',
              'params',
              required,
              missing,
              '通过 set_params 或宿主条件补齐必需参数。',
            ),
          );
        }
        final turn = _turn(state);
        final params = Map<String, CoachParamValue>.of(state.params);
        for (final entry in <String, Object>{
          'equipment': <String>[],
          'level': 1,
          'limits': <String>[],
        }.entries) {
          params.putIfAbsent(
            entry.key,
            () => CoachParamValue(
              value: entry.value,
              source: 'default',
              turn: turn,
            ),
          );
        }
        next = state.copyWith(params: params);
        stamp = _parametersStamp(next, en);
      case 'actions':
        final selected = picks ?? const <String>[];
        if (selected.length < minPicks ||
            selected.toSet().length != selected.length) {
          return NodeResult(
            state,
            error: nodeError(
              'invalid_picks',
              'picks',
              '至少 $minPicks 个不同动作',
              selected,
              '选择至少 $minPicks 个不同的已搜索动作。',
            ),
          );
        }
        final unseen = selected
            .where((id) => !state.seenActionIds.contains(id))
            .toList();
        if (unseen.isNotEmpty) {
          return NodeResult(
            state,
            error: nodeError(
              'unseen_actions',
              'picks',
              '已由 search_actions 返回的动作',
              unseen,
              '先搜索这些动作，再选取已返回的动作。',
            ),
          );
        }
        final invalid = {
          for (final id in selected) id: ?actionProblem(state, id),
        };
        if (invalid.isNotEmpty) {
          return NodeResult(
            state,
            error: nodeError(
              'incompatible_actions',
              'picks',
              '符合场景、器械和限制的目录动作',
              invalid,
              '替换不符合当前条件的动作。',
            ),
          );
        }
        warnings.addAll(_unknownLimitWarnings(state));
        warnings.addAll(_unknownActionWarnings(selected));
        next = state.copyWith(picks: selected);
        stamp = en
            ? 'Selected ${selected.length} actions'
            : '选了 ${selected.length} 个动作';
      case 'planning':
      case 'review':
        final version = _version(state, planId);
        if (version == null) {
          return NodeResult(
            state,
            error: nodeError(
              'missing_plan',
              'plan_id',
              '当前计划的最新版本',
              planId,
              '先创建计划，并由内部调用方指定当前计划。',
            ),
          );
        }
        if (node == 'review' && version.check?['ok'] != true) {
          return NodeResult(
            state,
            error: nodeError(
              'plan_not_checked',
              'plan.check',
              '最新版本的 check_plan 通过',
              version.check,
              '对当前版本运行 check_plan 并修复问题。',
            ),
          );
        }
        if (node == 'review') {
          stamp = en ? 'Plan checks passed' : '安全、时长、器材、均衡、重点都通过';
        } else {
          stamp = en
              ? 'Plan drafted, about ${(version.estimateSec / 60).toStringAsFixed(1)} min'
              : '已编排计划，约 ${(version.estimateSec / 60).toStringAsFixed(1)} 分钟';
        }
      default:
        return NodeResult(
          state,
          error: nodeError('invalid_node', 'node', '固定任务节点', node, '选择当前固定节点。'),
        );
    }
    return _advance(next, stamp, warnings: warnings);
  }

  /// Applies the step-three reset after an already committed parameter change.
  NodeResult parametersChanged(
    CoachSessionState state, {
    String language = 'zh',
  }) {
    final task = state.task;
    if (task == null) return NodeResult(state);
    final paramIndex = task.nodes.indexWhere((n) => n.id == 'parameters');
    if (paramIndex < 0 ||
        !{'done', 'updated'}.contains(task.nodes[paramIndex].status)) {
      return NodeResult(state);
    }
    final actionIndex = task.nodes.indexWhere((n) => n.id == 'actions');
    final nodes = List<CoachNodeState>.of(task.nodes);
    final changes = <CoachNodeState>[];
    nodes[paramIndex] = nodes[paramIndex].copyWith(
      status: 'updated',
      stamp: _parametersStamp(state, language.toLowerCase().startsWith('en')),
      doneAtTurn: _turn(state),
    );
    changes.add(nodes[paramIndex]);
    for (var i = actionIndex; i < nodes.length; i++) {
      final status = i == actionIndex ? 'current' : 'pending';
      if (nodes[i].status != status ||
          nodes[i].stamp != null ||
          nodes[i].doneAtTurn != null) {
        nodes[i] = nodes[i].copyWith(
          status: status,
          clearStamp: true,
          clearDoneAtTurn: true,
        );
        changes.add(nodes[i]);
      }
    }
    return NodeResult(
      state.copyWith(
        task: task.copyWith(nodes: nodes),
        plans: {
          for (final entry in state.plans.entries)
            entry.key: [
              for (var i = 0; i < entry.value.length; i++)
                if (i == entry.value.length - 1)
                  CoachPlanVersion(
                    version: entry.value[i].version,
                    plan: entry.value[i].plan,
                    estimateSec: entry.value[i].estimateSec,
                    fitLog: entry.value[i].fitLog,
                  )
                else
                  entry.value[i],
            ],
        },
        picks: state.picks
            .where((id) => actionProblem(state, id) == null)
            .toList(),
      ),
      changes: List.unmodifiable(changes),
      warnings: [
        ..._unknownLimitWarnings(state),
        ..._unknownActionWarnings(state.picks),
      ],
    );
  }

  NodeResult completeOutput(CoachSessionState state, {String language = 'zh'}) {
    final task = state.task;
    final current = task?.nodes.where((n) => n.status == 'current').firstOrNull;
    if (current?.id != 'output' ||
        task!.nodes
            .take(task.nodes.length - 1)
            .any((node) => node.status != 'done' && node.status != 'updated')) {
      return NodeResult(
        state,
        error: nodeError(
          'nodes_incomplete',
          'node',
          'output',
          current?.id,
          '先完成当前节点，再交付结果。',
        ),
      );
    }
    return _advance(
      state,
      language.toLowerCase().startsWith('en') ? 'Delivered' : '已交付',
    );
  }

  /// Null means catalogue fields do not show a conflict; unknown safety data is
  /// separately returned in warnings and is never represented as verified.
  String? actionProblem(CoachSessionState state, String id) {
    final drill = catalog[id];
    if (drill == null || !profile.select.matches(drill)) {
      return '不在目录或 profile 范围';
    }
    final equipment =
        ((state.params['equipment']?.value as List<Object?>?) ?? const [])
            .cast<String>()
            .toSet();
    for (final raw in drill.equipment) {
      if (raw == 'none') continue;
      final code = tags.equipmentCode(raw);
      if (code == null || !equipment.contains(code)) return '器械不符合';
    }
    final scene = state.params['scene']?.value as String?;
    if (scene != null) {
      final rule = profile.sceneRule(scene);
      final acceptable = rule.acceptDrillScenes.isEmpty
          ? {scene}
          : rule.acceptDrillScenes;
      if (drill.scenes.isNotEmpty && !drill.scenes.any(acceptable.contains)) {
        return '场景不符合';
      }
      if ((rule.forbidFloor &&
              catalog.taxonomy.floorPositions.contains(drill.position)) ||
          rule.forbidPositions.contains(drill.position)) {
        return '姿态不符合场景';
      }
    }
    final limits =
        ((state.params['limits']?.value as List<Object?>?) ?? const [])
            .cast<String>()
            .map((v) => tags.canonicalLimitCode(v) ?? v)
            .toSet();
    if ([
      ...drill.cautions,
      ...drill.contraindications,
    ].any((v) => limits.contains(tags.canonicalLimitCode(v)))) {
      return '触及伤痛限制';
    }
    return null;
  }

  List<String> _unknownLimitWarnings(CoachSessionState state) {
    final unknown =
        ((state.hostValues['limitsOpaque'] as List<Object?>?) ?? const [])
            .cast<String>();
    return [
      for (final code in unknown)
        '目录缺少限制 ${tags.limitValue(code) ?? code} 的可核对禁忌，不能确认其安全性。',
    ];
  }

  List<String> _unknownActionWarnings(Iterable<String> ids) {
    final warnings = <String>[];
    for (final id in ids) {
      final semantics = catalog[id]?.raw['trainingSemantics'];
      if (semantics is! Map) continue;
      final fields = semantics['unknownFields'];
      if (fields is! List) continue;
      for (final item in fields) {
        if (item is Map && item['field'] is String) {
          warnings.add('$id 的 ${item['field']} 尚未明确，不能视为已验证。');
        }
      }
    }
    return warnings;
  }

  CoachPlanVersion? _version(CoachSessionState state, String? id) {
    final key =
        id ?? (state.plans.length == 1 ? state.plans.keys.single : null);
    final versions = key == null ? null : state.plans[key];
    return versions == null || versions.isEmpty ? null : versions.last;
  }

  NodeResult _advance(
    CoachSessionState state,
    String stamp, {
    List<String> warnings = const [],
  }) {
    final task = state.task!;
    final nodes = List<CoachNodeState>.of(task.nodes);
    final index = nodes.indexWhere((n) => n.status == 'current');
    nodes[index] = nodes[index].copyWith(
      status: 'done',
      stamp: stamp,
      doneAtTurn: _turn(state),
    );
    final changes = <CoachNodeState>[nodes[index]];
    if (index + 1 < nodes.length) {
      nodes[index + 1] = nodes[index + 1].copyWith(status: 'current');
      changes.add(nodes[index + 1]);
    }
    return NodeResult(
      state.copyWith(task: task.copyWith(nodes: nodes)),
      changes: List.unmodifiable(changes),
      warnings: List.unmodifiable(warnings),
    );
  }

  int _turn(CoachSessionState state) =>
      state.userTurns.isEmpty ? 0 : state.userTurns.last.turn;

  String _parametersStamp(CoachSessionState state, bool en) {
    final parts = <String>[];
    for (final key in [
      'scene',
      'goal',
      'equipment',
      'minutes',
      'level',
      'limits',
    ]) {
      final param = state.params[key];
      if (param == null) continue;
      final value = param.value;
      final label = switch (key) {
        'scene' =>
          (en
                  ? {
                      'home': 'Home',
                      'office': 'Office',
                      'gym': 'Gym',
                      'outdoor': 'Outdoors',
                    }
                  : {
                      'home': '居家',
                      'office': '办公室',
                      'gym': '健身房',
                      'outdoor': '户外',
                    })[value] ??
              '$value',
        'equipment' =>
          (value as List).isEmpty
              ? (en ? 'Bodyweight' : '徒手')
              : value
                    .map((v) {
                      final id = tags.equipmentId(v as String) ?? v;
                      return en ? id : catalog.taxonomy.equipmentLabel(id);
                    })
                    .join(en ? ', ' : '、'),
        'limits' =>
          (value as List).isEmpty
              ? (en ? 'No restrictions' : '无伤痛')
              : value
                    .map((v) => tags.limitValue(v as String) ?? v)
                    .join(en ? ', ' : '、'),
        'goal' =>
          (value as List)
              .map((v) => _goalLabel(v as String, en))
              .join(en ? ', ' : '、'),
        'minutes' => en ? '$value min' : '$value 分钟',
        'level' =>
          en
              ? 'Level $value'
              : (value == 1
                    ? '初学'
                    : value == 2
                    ? '基础'
                    : '进阶'),
        _ => '$value',
      };
      final source =
          (en
              ? {
                  'user': 'you said',
                  'host': 'app setting',
                  'preselect': 'previous habit',
                  'default': 'default',
                }
              : {
                  'user': '你说的',
                  'host': 'App 设置',
                  'preselect': '上次习惯',
                  'default': '默认',
                })[param.source] ??
          param.source;
      parts.add(en ? '$label ($source)' : '$label（$source）');
    }
    return parts.join(' · ');
  }

  String _goalLabel(String code, bool en) {
    final dot = code.indexOf('.');
    if (dot < 0) return code;
    final kind = code.substring(0, dot);
    final id = code.substring(dot + 1);
    if (en) return id.replaceAll('_', ' ');
    if (kind == 'body') {
      final lookup = id == 'inner_thigh' ? 'adductors' : id;
      return catalog.taxonomy.muscleGroups[lookup] ??
          catalog.taxonomy.categories[lookup] ??
          id;
    }
    return catalog.taxonomy.categories[id] ?? id;
  }
}
