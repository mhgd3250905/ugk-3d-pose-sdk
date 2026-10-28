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
    final requested = task?.nodes.where((n) => n.id == node).firstOrNull;
    if (requested?.status == 'done' || requested?.status == 'updated') {
      if (node == 'actions' && picks != null) {
        return validateRecommendationPicks(state, picks, language: language);
      }
      return NodeResult(state);
    }
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
    final notices = <String>[];
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
        final focused = validateRecommendationPicks(
          state,
          selected,
          language: language,
        );
        if (!focused.ok) return focused;
        next = focused.state;
        notices.addAll(focused.notices);
        final minimum = recommendationMinimum(state);
        if (selected.length < minimum ||
            selected.toSet().length != selected.length) {
          return NodeResult(
            state,
            error: nodeError(
              'invalid_picks',
              'picks',
              '至少 $minimum 个不同动作',
              selected,
              '选择至少 $minimum 个不同的已搜索动作。',
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
        next = next.copyWith(picks: selected);
        stamp = _actionsStamp(selected.length, en);
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
          stamp =
              (en ? 'Plan checks passed' : '安全、时长、器材、均衡、重点都通过') +
              _planAmbientStamp(state, version, en);
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
    return _advance(next, stamp, warnings: warnings, notices: notices);
  }

  Set<String> _recommendationGoals(CoachSessionState state) =>
      state.task?.type != 'recommend'
      ? const {}
      : tags.expandCodes(
          (state.params['goal']?.value as List<Object?>? ?? const [])
              .cast<String>()
              .where((code) => code.startsWith('body.')),
        );

  /// Only already-seen, currently safe and in-scope catalogue actions count.
  List<String> recommendationCandidates(CoachSessionState state) {
    final goals = _recommendationGoals(state);
    return [
      for (final id in state.seenActionIds)
        if (actionProblem(state, id) == null &&
            (goals.isEmpty ||
                tags.forActionId(id).intersection(goals).isNotEmpty))
          id,
    ];
  }

  int recommendationMinimum(CoachSessionState state) {
    if (_recommendationGoals(state).isEmpty) return minPicks;
    final count = recommendationCandidates(state).length;
    return count < 1
        ? 1
        : count < 3
        ? count
        : 3;
  }

  /// Shared by explicit check(actions) and delivery, including after a previous
  /// actions stamp. The optional hint flag is the only mutation on rejection.
  NodeResult validateRecommendationPicks(
    CoachSessionState state,
    List<String> picks, {
    String language = 'zh',
  }) {
    final goals = _recommendationGoals(state);
    if (goals.isEmpty) return NodeResult(state);
    final candidates = recommendationCandidates(state);
    final count = candidates.length;
    final minimum = count < 1
        ? 1
        : count < 3
        ? count
        : 3;
    final en = language.toLowerCase().startsWith('en');
    final notices = count < 3 && !state.recommendationHintShown
        ? [
            en
                ? 'Found $count matching actions. You may search once more without level/pose filters, or use these candidates.'
                : '命中候选有 $count 个；可以去掉 level/pose 限制再搜一次，也可直接选用现有候选。',
          ]
        : <String>[];
    final next = notices.isEmpty
        ? state
        : state.copyWith(recommendationHintShown: true);
    NodeResult failure(
      String code,
      String field,
      Object? expected,
      Object? actual,
      String fix,
    ) => NodeResult(
      next,
      error: {
        ...nodeError(code, field, expected, actual, fix),
        'candidateCount': count,
        'minimum': minimum,
        'candidates': [
          for (final id in candidates.take(40))
            [
              id,
              catalog[id]!.name.of(language),
              tags
                  .forActionId(id)
                  .where((code) => code.startsWith('body.'))
                  .firstOrNull,
            ],
        ],
        if (notices.isNotEmpty) 'notices': notices,
      },
      notices: notices,
    );
    if (picks.length < minimum || picks.toSet().length != picks.length) {
      return failure(
        'invalid_picks',
        'picks',
        '至少 $minimum 个不同的命中动作',
        picks,
        '从 candidates 中选择符合部位的已搜索动作。',
      );
    }
    final unseen = picks
        .where((id) => !state.seenActionIds.contains(id))
        .toList();
    if (unseen.isNotEmpty) {
      return failure(
        'unseen_actions',
        'picks',
        '已由 search_actions 返回的动作',
        unseen,
        '先搜索动作再选取。',
      );
    }
    final invalid = {for (final id in picks) id: ?actionProblem(state, id)};
    if (invalid.isNotEmpty) {
      return failure(
        'incompatible_actions',
        'picks',
        '符合当前场景、器械和限制的动作',
        invalid,
        '从 candidates 中选择仍合规的动作。',
      );
    }
    final missed = picks
        .where((id) => tags.forActionId(id).intersection(goals).isEmpty)
        .toList();
    if (missed.isNotEmpty) {
      return failure(
        'recommendation_focus',
        'picks',
        '每个动作均命中任一目标部位',
        missed,
        '从 candidates 中选择命中目标部位的动作。',
      );
    }
    return NodeResult(next, notices: notices);
  }

  /// Adds already searched, currently compatible draft actions to completed
  /// picks; the task never passes through a second actions-check stage.
  NodeResult addDraftPicks(
    CoachSessionState state,
    Iterable<String> ids, {
    String language = 'zh',
  }) {
    final additions = <String>[];
    final seen = state.picks.toSet();
    for (final id in ids) {
      if (seen.add(id)) additions.add(id);
    }
    if (additions.isEmpty) return NodeResult(state);
    final task = state.task;
    final index = task?.nodes.indexWhere((node) => node.id == 'actions') ?? -1;
    if (task?.type != 'plan' ||
        index < 0 ||
        task!.nodes[index].status != 'done') {
      return NodeResult(
        state,
        error: nodeError(
          'actions_not_complete',
          'task.actions',
          '已完成的计划动作节点',
          index < 0 ? null : task?.nodes[index].status,
          '先完成动作节点再补充草稿动作。',
        ),
      );
    }
    final unseen = additions
        .where((id) => !state.seenActionIds.contains(id))
        .toList();
    if (unseen.isNotEmpty) {
      return NodeResult(
        state,
        error: nodeError(
          'unseen_actions',
          'picks',
          '已搜索的动作 ID',
          unseen,
          '先搜索动作再添加到计划。',
        ),
      );
    }
    final incompatible = {
      for (final id in additions) id: ?actionProblem(state, id),
    };
    if (incompatible.isNotEmpty) {
      return NodeResult(
        state,
        error: nodeError(
          'incompatible_actions',
          'picks',
          '符合当前条件的动作',
          incompatible,
          '替换不符合当前条件的动作。',
        ),
      );
    }
    final picks = [...state.picks, ...additions];
    final nodes = List<CoachNodeState>.of(task.nodes);
    nodes[index] = nodes[index].copyWith(
      stamp: _actionsStamp(
        picks.length,
        language.toLowerCase().startsWith('en'),
      ),
    );
    return NodeResult(
      state.copyWith(
        task: task.copyWith(nodes: nodes),
        picks: picks,
      ),
      changes: [nodes[index]],
      warnings: [
        ..._unknownLimitWarnings(state),
        ..._unknownActionWarnings(additions),
      ],
    );
  }

  String _actionsStamp(int count, bool en) =>
      en ? 'Selected $count actions' : '选了 $count 个动作';

  /// Applies the step-three reset after an already committed parameter change.
  NodeResult parametersChanged(
    CoachSessionState state, {
    String language = 'zh',
    Set<String>? changedFields,
    Set<String>? valueChangedFields,
  }) {
    final task = state.task;
    if (task == null) return NodeResult(state);
    final paramIndex = task.nodes.indexWhere((n) => n.id == 'parameters');
    if (paramIndex < 0 ||
        !{'done', 'updated'}.contains(task.nodes[paramIndex].status)) {
      return NodeResult(state);
    }
    final actionIndex = task.nodes.indexWhere((n) => n.id == 'actions');
    final actualChanges = valueChangedFields ?? changedFields;
    final planningIndex = task.nodes.indexWhere((n) => n.id == 'planning');
    final preserveActions =
        task.type == 'plan' &&
        actualChanges != null &&
        actualChanges.length == 1 &&
        actualChanges.contains('minutes') &&
        actionIndex >= 0 &&
        planningIndex > actionIndex &&
        {'done', 'updated'}.contains(task.nodes[actionIndex].status);
    final restartIndex = preserveActions ? planningIndex : actionIndex;
    final nodes = List<CoachNodeState>.of(task.nodes);
    final changes = <CoachNodeState>[];
    nodes[paramIndex] = nodes[paramIndex].copyWith(
      status: 'updated',
      stamp: _parametersStamp(state, language.toLowerCase().startsWith('en')),
      doneAtTurn: _turn(state),
    );
    changes.add(nodes[paramIndex]);
    if (actualChanges != null && actualChanges.isEmpty) {
      return NodeResult(
        state.copyWith(task: task.copyWith(nodes: nodes)),
        changes: List.unmodifiable(changes),
      );
    }
    for (var i = restartIndex; i < nodes.length; i++) {
      final status = i == restartIndex ? 'current' : 'pending';
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
                    createdAtTurn: entry.value[i].createdAtTurn,
                    operation: entry.value[i].operation,
                  )
                else
                  entry.value[i],
            ],
        },
        picks: preserveActions
            ? state.picks
            : state.picks
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
      (language.toLowerCase().startsWith('en') ? 'Delivered' : '已交付') +
          (task.type == 'plan' && _version(state, null) != null
              ? _planAmbientStamp(
                  state,
                  _version(state, null)!,
                  language.toLowerCase().startsWith('en'),
                )
              : ''),
    );
  }

  /// Environmental items are configured per scene and can only be removed by
  /// explicit user exclusions, never added through the exclusion field.
  Set<String> ambientEquipment(CoachSessionState state) {
    final scene = state.params['scene']?.value as String?;
    final configured = profile.ambientEquipmentFor(scene);
    final excluded =
        (state.params['equipment_exclude']?.value as List<Object?>? ?? const [])
            .cast<String>()
            .toSet();
    return Set.unmodifiable(configured.difference(excluded));
  }

  /// Shared admission rule for search, drafts, node checks and plan checks.
  Set<String> effectiveEquipment(CoachSessionState state) => Set.unmodifiable(
    {
      ...((state.params['equipment']?.value as List<Object?>?) ?? const [])
          .cast<String>(),
      ...ambientEquipment(state),
    }.difference(
      (state.params['equipment_exclude']?.value as List<Object?>? ?? const [])
          .cast<String>()
          .where(
            profile
                .ambientEquipmentFor(state.params['scene']?.value as String?)
                .contains,
          )
          .toSet(),
    ),
  );

  /// Null means catalogue fields do not show a conflict; unknown safety data is
  /// separately returned in warnings and is never represented as verified.
  String? actionProblem(CoachSessionState state, String id) {
    final drill = catalog[id];
    if (drill == null || !profile.select.matches(drill)) {
      return '不在目录或 profile 范围';
    }
    final equipment = effectiveEquipment(state);
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
    if (state.activePlanId != null && id != null && id != state.activePlanId) {
      return null;
    }
    final key =
        id ??
        state.activePlanId ??
        (state.legacyPlanFallback && state.plans.length == 1
            ? state.plans.keys.single
            : null);
    final versions = key == null ? null : state.plans[key];
    return versions == null || versions.isEmpty ? null : versions.last;
  }

  NodeResult _advance(
    CoachSessionState state,
    String stamp, {
    List<String> warnings = const [],
    List<String> notices = const [],
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
      notices: List.unmodifiable(notices),
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
      'equipment_exclude',
      'minutes',
      'level',
      'limits',
    ]) {
      final param = state.params[key];
      if (param == null) continue;
      final value = param.value;
      if (key == 'equipment_exclude' && (value as List).isEmpty) continue;
      if (key == 'minutes' &&
          param.source == 'derived' &&
          param.basedOn != null) {
        final quote = param.quote ?? '';
        final oldValue = param.basedOn!.value;
        parts.add(
          en
              ? '$value min (adjusted as you said “$quote”, previously $oldValue min)'
              : '$value 分钟（按你说的“$quote”调整，原 $oldValue 分钟）',
        );
        continue;
      }
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
              ? _bodyweightLabel(state, en)
              : value
                    .map(
                      (v) => tags.localizedLabel(v as String, en ? 'en' : 'zh'),
                    )
                    .join(en ? ', ' : '、'),
        'equipment_exclude' =>
          (en ? 'Excluded: ' : '不使用：') +
              (value as List)
                  .map(
                    (v) => tags.localizedLabel(v as String, en ? 'en' : 'zh'),
                  )
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
                  'derived': 'inferred',
                }
              : {
                  'user': '你说的',
                  'host': 'App 设置',
                  'preselect': '上次习惯',
                  'default': '默认',
                  'derived': '推测',
                })[param.source] ??
          param.source;
      parts.add(en ? '$label ($source)' : '$label（$source）');
    }
    return parts.join(' · ');
  }

  String _goalLabel(String code, bool en) {
    return tags.localizedLabel(code, en ? 'en' : 'zh');
  }

  String _bodyweightLabel(CoachSessionState state, bool en) {
    final available = ambientEquipment(state).toList()..sort();
    if (available.isEmpty) return en ? 'Bodyweight' : '徒手';
    final labels = available
        .map(
          (code) => state.params['scene'] == null && code == 'equip.mat'
              ? (en ? 'floor' : '地面')
              : tags.localizedLabel(code, en ? 'en' : 'zh'),
        )
        .join(en ? ', ' : '/');
    return en ? 'Bodyweight ($labels available)' : '徒手（可用$labels）';
  }

  String _planAmbientStamp(
    CoachSessionState state,
    CoachPlanVersion version,
    bool en,
  ) {
    final used = <String>{};
    void collect(Object? value) {
      if (value is Map) {
        final segments = value['segments'];
        final usesSegments = segments is List && segments.isNotEmpty;
        if (!usesSegments) {
          if (value['exerciseId'] case final String id) {
            for (final equipment
                in catalog[id]?.equipment ?? const <String>[]) {
              if (tags.equipmentCode(equipment) case final code?) {
                used.add(code);
              }
            }
          }
        }
        for (final child in value.values) {
          collect(child);
        }
      } else if (value is List) {
        for (final child in value) {
          collect(child);
        }
      }
    }

    collect(version.plan);
    final actual = used.intersection(ambientEquipment(state)).toList()..sort();
    if (actual.isEmpty) return en ? ' · No ambient items used' : ' · 未使用环境物';
    final labels = actual
        .map((code) => tags.localizedLabel(code, en ? 'en' : 'zh'))
        .join(en ? ', ' : '、');
    return en ? ' · Ambient items used: $labels' : ' · 实际用到环境物：$labels';
  }
}
