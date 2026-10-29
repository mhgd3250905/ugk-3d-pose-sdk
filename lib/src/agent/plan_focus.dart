/// Public references for a host-saved plan selected for discussion.
library;

import '../catalog/catalog.dart';
import '../plan/plan_issue.dart';
import 'session_state.dart';

/// The current version of the plan under discussion. [savedRef] identifies
/// the host save and the imported base; editing does not move that base.
class CoachPlanFocus {
  const CoachPlanFocus({
    required this.planId,
    required this.title,
    required this.version,
    required this.savedRef,
  });

  final String planId;
  final String title;
  final int version;
  final CoachSavedPlanRef savedRef;

  Map<String, Object?> toJson() => {
    'planId': planId,
    'title': title,
    'version': version,
    'savedRef': savedRef.toJson(),
  };
}

/// Synchronous, atomic outcome of selecting an external plan. A rejection
/// does not change conversation facts, display messages or model history.
class CoachPlanFocusResult {
  const CoachPlanFocusResult.success({
    required String this.planId,
    required int this.version,
  }) : ok = true,
       errors = const [];

  CoachPlanFocusResult.failure(List<PlanIssue> errors)
    : ok = false,
      errors = List.unmodifiable(errors),
      planId = null,
      version = null;

  final bool ok;
  final List<PlanIssue> errors;
  final String? planId;
  final int? version;
}

CoachPlanFocus? currentPlanFocus(CoachSessionState state) {
  final id = state.focusPlanId;
  final saved = state.savedRef;
  final plan = state.plans[id]?.lastOrNull;
  if (id == null || saved == null || plan == null) return null;
  return CoachPlanFocus(
    planId: id,
    title: plan.plan['title'] as String? ?? id,
    version: plan.version,
    savedRef: saved,
  );
}

/// A complete ordered view shared by the selection message and every state
/// tail. It is rebuilt from the latest version, never from folded history.
Map<String, Object?>? focusPlanSummary(
  CoachSessionState state,
  Catalog catalog,
  String language,
) {
  final focus = currentPlanFocus(state);
  if (focus == null) return null;
  final version = state.plans[focus.planId]!.last;
  final items = <Map<String, Object?>>[];
  for (final block in version.plan['blocks'] as List<Object?>? ?? const []) {
    if (block is! Map<String, Object?>) continue;
    for (final item in block['items'] as List<Object?>? ?? const []) {
      if (item is! Map<String, Object?>) continue;
      final id = item['exerciseId'];
      if (id is! String) continue;
      items.add({
        'index': items.length + 1,
        'actionId': id,
        'name': catalog[id]?.name.of(language) ?? id,
        'dose': {
          for (final entry in item.entries)
            if (entry.key != 'exerciseId') entry.key: entry.value,
          'blockId': block['id'],
          'blockType': block['type'],
          'rounds': block['rounds'] ?? 1,
          'restBetweenRoundsSeconds': block['restBetweenRoundsSeconds'] ?? 0,
        },
      });
    }
  }
  return {
    'plan_id': focus.planId,
    'version': focus.version,
    'title': focus.title,
    'estimateSec': version.estimateSec,
    'equipment': version.plan['equipment'] ?? const <String>[],
    'items': items,
  };
}

const externalPlanSelectionPrefix = '用户从「我的计划」选中了计划（系统生成）：';

const planFocusSystemRules =
    '存在 focus_plan 时，“这个计划”指它；“第 N 个动作”指 items 中 index=N，保留完整 dose。'
    '修改、替换、插入、删除、缩时均基于其最新版本，用现有 set_params(operation=edit)、draft_plan、检查和show_plan，保持同plan_id追加版本。'
    'draft_plan保留旧项附sourceIndex=原index，新增项省略，重复actionId也按index区分。'
    '沿用计划地点及条件，不再问地点；不新增get_plan/edit_plan。无focus_plan则用通常指代规则。';
