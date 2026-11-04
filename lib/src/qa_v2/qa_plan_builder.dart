/// build_plan：模型只给主训练动作和时长，热身/主训/收操、组数、时长由代码确定性排出。
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

  QaPlanResult build({
    required List<String> mainIds,
    required int minutes,
    required QaQuery base,
    String? title,
    Map<String, String> blockNames = const {},
    List<String>? warmIds,
    List<String>? coolIds,
  }) {
    final notes = <String>[];
    final target = minutes.clamp(3, 60) * 60;
    final main = <QaAction>[];
    for (final id in mainIds) {
      final a = finder.index[id];
      if (a == null) {
        notes.add('unknown:$id');
        continue;
      }
      if (!finder.passes(a, base.withExclude(const {}))) {
        // 圈定过范围（或有伤痛禁忌）时绝不越界：直接去掉，后面按同条件补。
        notes.add('out_of_scope:$id');
        continue;
      }
      if (!main.any((m) => m.id == a.id)) main.add(a);
    }
    final pureStretch = main.isNotEmpty && main.every((a) => a.isStretchOnly);
    final used = {for (final a in main) a.id};

    // 主训练不足 2 个时，用同条件补。
    if (main.length < 2) {
      for (final h in finder.find(base.withExclude(used))) {
        if (main.length >= 3) break;
        main.add(h.action);
        used.add(h.action.id);
      }
    }

    // 改时长时沿用原来的热身/收操（含用户换过的），不重新挑。
    final warm = <QaAction>[
      for (final id in warmIds ?? const <String>[])
        if (finder.index[id] != null && !used.contains(id)) finder.index[id]!,
    ];
    final cool = <QaAction>[
      for (final id in coolIds ?? const <String>[])
        if (finder.index[id] != null && !used.contains(id)) finder.index[id]!,
    ];
    used.addAll([...warm.map((a) => a.id), ...cool.map((a) => a.id)]);
    if (warmIds == null && !pureStretch && minutes >= warmupFromMinutes) {
      final region = {for (final a in main) ...a.primaryMuscles};
      warm.addAll(
        finder
            .find(
              // 范围条件（含小空间、难度上限）整体沿用主训的确认条件。
              base.scopeOnly.copyWith(
                muscles: region,
                types: const {'mobility', 'dynamic-stretch'},
                roles: const {'warmup'},
                exclude: used,
                limit: 2,
              ),
            )
            .map((h) => h.action),
      );
      used.addAll(warm.map((a) => a.id));
    }
    if (coolIds == null && !pureStretch && minutes >= cooldownFromMinutes) {
      final region = {for (final a in main) ...a.primaryMuscles};
      cool.addAll(
        finder
            .find(
              base.scopeOnly.copyWith(
                stretchMuscles: region,
                types: const {'static-stretch'},
                roles: const {'cooldown'},
                exclude: used,
                limit: 2,
              ),
            )
            .map((h) => h.action),
      );
      used.addAll(cool.map((a) => a.id));
    }

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
    );

    var plan = make();
    var secs = _duration.estimateSeconds(plan, _catalog).round();
    // 先调组数，再增删动作，直到落在 ±12% 内。
    for (var guard = 0; guard < 40; guard++) {
      if (secs < target * 0.88) {
        final grow =
            main.where((a) => mainSets[a.id]! < (pureStretch ? 2 : 4)).toList()
              ..sort((x, y) => mainSets[x.id]!.compareTo(mainSets[y.id]!));
        if (grow.isNotEmpty &&
            (main.length >= 4 || pureStretch || mainSets[grow.first.id]! < 3)) {
          mainSets[grow.first.id] = mainSets[grow.first.id]! + 1;
        } else if (main.length + warm.length + cool.length < maxItems) {
          final extra = finder.find(base.withExclude(used)).firstOrNull;
          if (extra == null) {
            if (grow.isEmpty) break;
            mainSets[grow.first.id] = mainSets[grow.first.id]! + 1;
          } else {
            main.add(extra.action);
            used.add(extra.action.id);
            mainSets[extra.action.id] = _defaultSets(extra.action, pureStretch);
          }
        } else if (grow.isNotEmpty) {
          mainSets[grow.first.id] = mainSets[grow.first.id]! + 1;
        } else {
          break;
        }
      } else if (secs > target * 1.12) {
        final shrink = main.where((a) => mainSets[a.id]! > 1).toList()
          ..sort((x, y) => mainSets[y.id]!.compareTo(mainSets[x.id]!));
        if (shrink.isNotEmpty) {
          mainSets[shrink.first.id] = mainSets[shrink.first.id]! - 1;
        } else if (main.length > 2) {
          final drop = main.removeLast();
          used.remove(drop.id);
          mainSets.remove(drop.id);
        } else if (warm.isNotEmpty || cool.isNotEmpty) {
          if (warm.length > 1) {
            warm.removeLast();
          } else if (cool.length > 1) {
            cool.removeLast();
          } else {
            warm.clear();
            cool.clear();
          }
        } else {
          break;
        }
      } else {
        break;
      }
      plan = make();
      secs = _duration.estimateSeconds(plan, _catalog).round();
    }
    return QaPlanResult(plan, secs, notes);
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
  }) {
    // 段名由模型按用户语言给；没给时用目录约定的英文 id，App 可按 BlockType 自己本地化。
    final blocks = <PlanBlock>[
      if (warm.isNotEmpty)
        PlanBlock(
          id: 'warmup',
          name: blockNames['warmup'] ?? 'Warm-up',
          type: BlockType.warmup,
          items: [for (final a in warm) _item(a, 1, light: true)],
        ),
      PlanBlock(
        id: 'main',
        name: blockNames['main'] ?? (pureStretch ? 'Stretch' : 'Main'),
        type: BlockType.main,
        items: [for (final a in main) _item(a, mainSets[a.id] ?? 1)],
      ),
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
