/// build_plan 的配时：动作（含热身、收操、分段）全部由模型给定，代码只确定性配组数与时长，并报告偏差。
library;

import '../agent/plan_builder.dart';
import '../agent/session_state.dart';
import '../catalog/catalog.dart';
import '../plan/plan_codec.dart';
import '../plan/plan_execution_timing.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import 'qa_action.dart';
import 'qa_admission.dart';
import 'qa_finder.dart';

final class QaPlanResult {
  QaPlanResult(this.plan, this.seconds, this.notes);
  final TrainingPlan plan;
  final int seconds;
  final List<String> notes;

  List<String> get orderedIds => [
    for (final b in plan.blocks)
      for (final i in b.items) i.exerciseId,
  ];
  List<String> get mainIds => [
    for (final b in plan.blocks)
      if (b.type == BlockType.main || b.type == BlockType.circuit)
        for (final i in b.items) i.exerciseId,
  ];
}

final class QaPlanBuilder {
  QaPlanBuilder(
    this.finder, {
    this.warmupFromMinutes = 9,
    this.cooldownFromMinutes = 9,
    this.maxItems = 10,
  });

  final QaFinder finder;
  final int warmupFromMinutes;
  final int cooldownFromMinutes;
  final int maxItems;
  final _duration = const PlanDuration();

  Catalog get _catalog => finder.index.catalog;

  /// Reuse the existing integer-dose fitter with the host's actual timeline.
  /// This only adjusts doses; selected IDs, block order and card numbers stay
  /// intact. Scope and final playback admission remain the caller's gates.
  QaPlanResult fitForExecution(
    TrainingPlan plan, {
    required CoachProfile profile,
    required PlanExecutionTimingCallback executionTiming,
  }) {
    // 时长已合格也要过同一准入：交付/恢复不能比 refit 更宽。
    for (final id in plan.exerciseIds) {
      final problem = finder.admission.problem(
        id,
        scene: plan.scene,
        equipment: plan.equipment,
        avoid: plan.avoid,
      );
      if (problem != null) {
        throw StateError('QA plan admission failed: $id $problem');
      }
    }
    final target = plan.targetMinutes * 60.0;
    final tolerance = profile.limits.durationTolerance.clamp(0.0, .1);
    final card = _duration.estimateSeconds(plan, _catalog);
    final execution = evaluatePlanExecutionTiming(plan, executionTiming);
    if ((card - target).abs() <= target * tolerance + 1e-9 &&
        (execution.totalSeconds - target).abs() <= target * tolerance + 1e-9) {
      return QaPlanResult(plan, card.round(), const []);
    }
    final admission = finder.admission;
    final catalog = admission.catalog;
    final state = CoachSessionState(
      params: admission.params(
        scene: plan.scene,
        equipment: plan.equipment,
        avoid: plan.avoid,
        minutes: plan.targetMinutes,
      ),
      seenActionIds: plan.exerciseIds,
      picks: plan.exerciseIds.toList(),
      activePlanId: plan.id,
      plans: {
        plan.id: [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: card,
            fitLog: const [],
          ),
        ],
      },
    );
    final fitted = PlanBuilder(
      profile,
      catalog,
      minPicks: profile.minActions,
      executionTiming: executionTiming,
    ).refit(state, plan);
    if (!fitted.ok || fitted.feasibility != null) {
      throw StateError('QA plan duration fit failed: ${fitted.error}');
    }
    final result = const PlanCodec()
        .decodeStrict(fitted.state.plans[plan.id]!.last.plan)
        .plan!;
    return QaPlanResult(
      result,
      _duration.estimateSeconds(result, catalog).round(),
      const [],
    );
  }

  /// The selected actions determine the declaration, including warm-up and
  /// cooldown. Owning an unused item does not make it part of this plan.
  List<String> equipmentFor(Iterable<String> actionIds) => (<String>{
    for (final id in actionIds) ...?finder.index[id]?.requiredEquipment,
  }.toList()..sort());

  /// 按给定动作配组数与时长：主训练、热身、收操、分段都原样用 [mainIds] / [warmIds] / [coolIds] /
  /// [segmentNames]，顺序不变；不补、不删、不换、不挑动作，也不检查范围（准入由调用方验收）。
  /// 只调主训练的组数，尽量落进目标 ±12%；落不进时 [QaPlanResult.seconds] 如实反映偏差，由调用方决定退回。
  QaPlanResult build({
    required List<String> mainIds,
    required int minutes,
    required QaQuery base,
    String? title,
    Map<String, String> blockNames = const {},
    List<String> warmIds = const [],
    List<String> coolIds = const [],
    List<String> segmentNames = const [],
    Map<String, int> segmentOf = const {},
  }) {
    final notes = <String>[];
    List<QaAction> resolve(List<String> ids) {
      final out = <QaAction>[];
      for (final id in ids) {
        final a = finder.index[id];
        if (a == null) {
          notes.add('unknown:$id');
        } else {
          out.add(a);
        }
      }
      return out;
    }

    final main = resolve(mainIds);
    final warm = resolve(warmIds);
    final cool = resolve(coolIds);
    final pureStretch = main.isNotEmpty && main.every((a) => a.isStretchOnly);
    final target = minutes * 60;
    final mainSets = <String, int>{
      for (final a in main) a.id: _defaultSets(a, pureStretch),
    };
    TrainingPlan make() => _plan(
      title: title,
      minutes: minutes,
      base: base,
      warm: warm,
      main: main,
      cool: cool,
      mainSets: mainSets,
      pureStretch: pureStretch,
      blockNames: blockNames,
      segmentNames: segmentNames,
      segmentOf: segmentOf,
    );

    var plan = make();
    var secs = _duration.estimateSeconds(plan, _catalog).round();
    final maxSets = pureStretch ? 2 : 4;
    for (var guard = 0; guard < 60; guard++) {
      if (secs < target * 0.88) {
        final grow = main.where((a) => mainSets[a.id]! < maxSets).toList()
          ..sort((x, y) => mainSets[x.id]!.compareTo(mainSets[y.id]!));
        if (grow.isEmpty) break;
        mainSets[grow.first.id] = mainSets[grow.first.id]! + 1;
      } else if (secs > target * 1.12) {
        final shrink = main.where((a) => mainSets[a.id]! > 1).toList()
          ..sort((x, y) => mainSets[y.id]!.compareTo(mainSets[x.id]!));
        if (shrink.isEmpty) break;
        mainSets[shrink.first.id] = mainSets[shrink.first.id]! - 1;
      } else {
        break;
      }
      plan = make();
      secs = _duration.estimateSeconds(plan, _catalog).round();
    }
    return QaPlanResult(plan, secs, notes);
  }

  /// 配时后与目标的偏差（比例，正 = 偏长）。
  static double deviation(QaPlanResult r) {
    final target = r.plan.targetMinutes * 60;
    return target <= 0 ? 0 : (r.seconds - target) / target;
  }

  int _defaultSets(QaAction a, bool pureStretch) {
    if (pureStretch || a.isStretchOnly) return 1;
    return a.drill.defaultDose.sets.clamp(1, 3);
  }

  PlanItem _item(QaAction a, int sets, {bool light = false}) {
    final d = a.drill.defaultDose;
    final range = a.drill.doseRange;
    if (d.mode == DoseMode.time) {
      var secs = d.seconds ?? 30;
      if (light) secs = secs.clamp(20, 40);
      final r = range.seconds;
      if (r != null) secs = secs.clamp(r.min, r.max);
      return PlanItem(
        exerciseId: a.id,
        mode: DoseMode.time,
        sets: sets,
        workSeconds: secs,
        perSide: a.drill.unilateral,
        restSeconds: light ? 10 : d.restSeconds,
      );
    }
    var reps = d.reps ?? 10;
    if (light) reps = reps.clamp(6, 10);
    final r = range.reps;
    if (r != null) reps = reps.clamp(r.min, r.max);
    return PlanItem(
      exerciseId: a.id,
      mode: DoseMode.reps,
      sets: sets,
      reps: reps,
      perSide: a.drill.unilateral,
      restSeconds: light ? 10 : d.restSeconds,
    );
  }

  TrainingPlan _plan({
    required String? title,
    required int minutes,
    required QaQuery base,
    required List<QaAction> warm,
    required List<QaAction> main,
    required List<QaAction> cool,
    required Map<String, int> mainSets,
    required bool pureStretch,
    required Map<String, String> blockNames,
    List<String> segmentNames = const [],
    Map<String, int> segmentOf = const {},
  }) {
    // 分段：模型按用户要求把主训练分成几段（如「坐姿」「站姿」），顺序原样保留。
    final segs = segmentNames.length > 1 ? segmentNames : const <String>[];
    final mainBlocks = <PlanBlock>[
      if (segs.isEmpty)
        PlanBlock(
          id: 'main',
          name: blockNames['main'] ?? (pureStretch ? 'Stretch' : 'Main'),
          type: BlockType.main,
          items: [for (final a in main) _item(a, mainSets[a.id] ?? 1)],
        )
      else
        for (var k = 0; k < segs.length; k++)
          if (main.any((a) => (segmentOf[a.id] ?? segs.length - 1) == k))
            PlanBlock(
              id: k == 0 ? 'main' : 'main-${k + 1}',
              name: segs[k],
              type: BlockType.main,
              items: [
                for (final a in main)
                  if ((segmentOf[a.id] ?? segs.length - 1) == k) _item(a, mainSets[a.id] ?? 1),
              ],
            ),
    ];
    // 段名由模型按用户语言给；没给时用目录约定的英文 id，App 可按 BlockType 自己本地化。
    final blocks = <PlanBlock>[
      if (warm.isNotEmpty)
        PlanBlock(
          id: 'warmup',
          name: blockNames['warmup'] ?? 'Warm-up',
          type: BlockType.warmup,
          items: [for (final a in warm) _item(a, 1, light: true)],
        ),
      ...mainBlocks,
      if (cool.isNotEmpty)
        PlanBlock(
          id: 'cooldown',
          name: blockNames['cooldown'] ?? 'Cool-down',
          type: BlockType.cooldown,
          items: [for (final a in cool) _item(a, 1, light: true)],
        ),
    ];
    final cleanTitle = (title ?? '').trim();
    return TrainingPlan(
      id: 'qa-v2-${DateTime.now().microsecondsSinceEpoch}',
      source: 'ai-qa-v2',
      title: cleanTitle.isEmpty
          ? (pureStretch ? 'Stretch' : 'Workout')
          : cleanTitle,
      goal: pureStretch ? 'relax' : 'strength',
      scene: QaAdmission.planScene(base.scene),
      equipment: equipmentFor([
        for (final block in blocks)
          for (final item in block.items) item.exerciseId,
      ]),
      level: 1,
      targetMinutes: minutes,
      blocks: blocks,
      avoid: base.avoidJoints,
    );
  }
}
