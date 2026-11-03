/// build_plan：模型只给主训练动作和时长，热身/主训/收操、组数、时长由代码确定性排出。
library;

import '../catalog/catalog.dart';
import '../plan/training_plan.dart';
import 'qa_action.dart';
import 'qa_finder.dart';

final class QaPlanResult {
  QaPlanResult(this.plan, this.seconds, this.notes);
  final TrainingPlan plan;
  final int seconds;
  final List<String> notes;

  List<String> get orderedIds => [for (final b in plan.blocks) for (final i in b.items) i.exerciseId];
  List<String> get mainIds => [
    for (final b in plan.blocks)
      if (b.type == BlockType.main || b.type == BlockType.circuit) for (final i in b.items) i.exerciseId,
  ];
}

final class QaPlanBuilder {
  QaPlanBuilder(this.finder, {this.warmupFromMinutes = 9, this.cooldownFromMinutes = 9, this.maxItems = 10});

  final QaFinder finder;
  final int warmupFromMinutes;
  final int cooldownFromMinutes;
  final int maxItems;
  final _duration = const PlanDuration();

  Catalog get _catalog => finder.index.catalog;

  QaPlanResult build({
    required List<String> mainIds,
    required int minutes,
    required QaQuery base,
    String? title,
    String lang = 'zh',
  }) {
    final notes = <String>[];
    final target = minutes.clamp(3, 60) * 60;
    final main = <QaAction>[];
    for (final id in mainIds) {
      final a = finder.index[id];
      if (a == null) {
        notes.add('未知动作 $id 已忽略');
        continue;
      }
      if (!finder.passes(a, base.withExclude(const {}))) notes.add('${a.name(lang)} 不符合当前场景/限制，已保留但请注意');
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

    final warm = <QaAction>[];
    final cool = <QaAction>[];
    if (!pureStretch && minutes >= warmupFromMinutes) {
      final region = {for (final a in main) ...a.primaryMuscles};
      warm.addAll(
        finder
            .find(
              QaQuery(
                scene: base.scene,
                equipment: base.equipment,
                muscles: region,
                types: const {'mobility', 'dynamic-stretch'},
                roles: const {'warmup'},
                avoidJoints: base.avoidJoints,
                noFloor: base.noFloor,
                maxImpact: base.maxImpact,
                exclude: used,
                limit: 2,
              ),
              lang: lang,
            )
            .map((h) => h.action),
      );
      used.addAll(warm.map((a) => a.id));
    }
    if (!pureStretch && minutes >= cooldownFromMinutes) {
      final region = {for (final a in main) ...a.primaryMuscles};
      cool.addAll(
        finder
            .find(
              QaQuery(
                scene: base.scene,
                equipment: base.equipment,
                stretchMuscles: region,
                types: const {'static-stretch'},
                roles: const {'cooldown'},
                avoidJoints: base.avoidJoints,
                noFloor: base.noFloor,
                exclude: used,
                limit: 2,
              ),
              lang: lang,
            )
            .map((h) => h.action),
      );
      used.addAll(cool.map((a) => a.id));
    }

    final mainSets = <String, int>{for (final a in main) a.id: _defaultSets(a, pureStretch)};
    TrainingPlan make() => _plan(
      title: title,
      minutes: minutes,
      base: base,
      warm: warm,
      main: main,
      cool: cool,
      mainSets: mainSets,
      pureStretch: pureStretch,
      lang: lang,
    );

    var plan = make();
    var secs = _duration.estimateSeconds(plan, _catalog).round();
    // 先调组数，再增删动作，直到落在 ±12% 内。
    for (var guard = 0; guard < 40; guard++) {
      if (secs < target * 0.88) {
        final grow = main.where((a) => mainSets[a.id]! < (pureStretch ? 2 : 4)).toList()
          ..sort((x, y) => mainSets[x.id]!.compareTo(mainSets[y.id]!));
        if (grow.isNotEmpty && (main.length >= 4 || pureStretch || mainSets[grow.first.id]! < 3)) {
          mainSets[grow.first.id] = mainSets[grow.first.id]! + 1;
        } else if (main.length + warm.length + cool.length < maxItems) {
          final extra = finder.find(base.withExclude(used), lang: lang).firstOrNull;
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
    required String lang,
  }) {
    final en = lang == 'en';
    final blocks = <PlanBlock>[
      if (warm.isNotEmpty)
        PlanBlock(id: 'warmup', name: en ? 'Warm-up' : '热身', type: BlockType.warmup, items: [for (final a in warm) _item(a, 1, light: true)]),
      PlanBlock(
        id: 'main',
        name: pureStretch ? (en ? 'Stretch' : '拉伸') : (en ? 'Main' : '主训练'),
        type: BlockType.main,
        items: [for (final a in main) _item(a, mainSets[a.id] ?? 1)],
      ),
      if (cool.isNotEmpty)
        PlanBlock(id: 'cooldown', name: en ? 'Cool-down' : '放松', type: BlockType.cooldown, items: [for (final a in cool) _item(a, 1, light: true)]),
    ];
    final cleanTitle = (title ?? '').replaceAll(RegExp(r'[\d一二两三四五六七八九十]+\s*(分钟|min(utes)?)|\d+'), '').trim();
    return TrainingPlan(
      id: 'qa-v2-${DateTime.now().microsecondsSinceEpoch}',
      source: 'ai-qa-v2',
      title: cleanTitle.isEmpty ? (pureStretch ? (en ? 'Stretch' : '拉伸放松') : (en ? 'Workout' : '训练')) : cleanTitle,
      goal: pureStretch ? 'relax' : 'strength',
      scene: base.scene == 'hotel' || base.scene == 'outdoor' ? 'home' : base.scene,
      equipment: base.equipment.toList(),
      level: 1,
      targetMinutes: minutes,
      blocks: blocks,
      avoid: base.avoidJoints,
    );
  }
}
