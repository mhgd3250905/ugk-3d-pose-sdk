/// QA v2 的唯一动作准入：候选圈定、热身/收操补选、配时 refit、交付与恢复
/// 都用同一份已确认条件（场景、计划器械声明、避开部位）调用 core
/// [NodeGates.actionProblem]。QA 标签过滤（不躺地、小空间、冲击、关节负担）
/// 只会在此之上进一步收窄，永远不会放进 core 门禁拒绝的动作。
library;

import '../agent/action_tags.dart';
import '../agent/node_gates.dart';
import '../agent/session_state.dart';
import '../catalog/catalog.dart';
import '../profile/coach_profile.dart';

final class QaAdmission {
  QaAdmission(this.profile, this.catalog)
    : gates = NodeGates(profile, catalog, minPicks: profile.minActions),
      tags = ActionTags(profile, catalog);

  final CoachProfile profile;

  /// QA 准入目录（[QaActionIndex.equipmentCatalog]），与 refit 用的是同一份。
  final Catalog catalog;
  final NodeGates gates;
  final ActionTags tags;
  final Map<String, String?> _memo = {};

  /// QA 场所 → 计划/core 场景。计划声明与准入都只经过这一个映射。
  static String planScene(String scene) =>
      scene == 'hotel' || scene == 'outdoor' ? 'home' : scene;

  /// 计划持久化的确认条件（scene / equipment / avoid）投影成 core 参数。
  /// 选动作、refit、恢复都从这里取，不允许各自拼装。
  Map<String, CoachParamValue> params({
    required String scene,
    required Iterable<String> equipment,
    required Iterable<String> avoid,
    int? minutes,
  }) {
    CoachParamValue param(Object value) =>
        CoachParamValue(value: value, source: 'app', turn: 0);
    return {
      'scene': param(planScene(scene)),
      if (minutes != null) 'minutes': param(minutes),
      'equipment': param(
        <String>{for (final id in equipment) ?tags.equipmentCode(id)}.toList()
          ..sort(),
      ),
      'limits': param(
        <String>{
          for (final id in avoid) tags.canonicalLimitCode(id) ?? id,
        }.toList()..sort(),
      ),
    };
  }

  /// core 门禁对该动作的判定；null = 准入。[equipment] 是计划会为它声明的器械。
  String? problem(
    String id, {
    required String scene,
    required Iterable<String> equipment,
    required Iterable<String> avoid,
  }) {
    final key = [
      id,
      planScene(scene),
      (equipment.toSet().toList()..sort()).join(','),
      (avoid.toSet().toList()..sort()).join(','),
    ].join('|');
    return _memo.putIfAbsent(
      key,
      () => gates.actionProblem(
        CoachSessionState(
          params: params(scene: scene, equipment: equipment, avoid: avoid),
        ),
        id,
      ),
    );
  }
}
