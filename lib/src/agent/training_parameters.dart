import 'dart:convert';

import '../catalog/catalog.dart';
import '../plan/coach_context.dart';
import '../plan/plan_issue.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';

/// Explicit conversation facts shared by prompting and the final plan gate.
/// Unknown values remain unknown until the single clarification has finished.
class TrainingParameters {
  TrainingParameters._(this.context, this.equipmentLabels, this.skipped);
  final CoachContext context;
  final Map<String, String> equipmentLabels;
  final bool skipped;

  Set<String> get missing => {
    if (context.scene == null) 'scene',
    if (context.equipment == null) 'equipment',
    if (context.minutes == null) 'minutes',
  };

  static TrainingParameters infer(
    Iterable<String> messages,
    CoachContext supplied,
    Catalog catalog,
    CoachProfile profile,
  ) {
    String? scene;
    Set<String>? equipment;
    int? minutes;
    var skipped = false;
    final usedEquipment = {
      for (final drill in profile.scope(catalog)) ...drill.equipment,
    }..remove('none');
    final labels = {
      for (final id in usedEquipment) id: catalog.taxonomy.equipmentLabel(id),
    };
    final inputs = messages.toList();
    for (var index = 0; index < inputs.length; index++) {
      final message = inputs[index];
      // Fresh App facts replace older turns. The newest explicit user message
      // can correct them (for example "改为办公室").
      if (index == inputs.length - 1) {
        scene = supplied.scene ?? scene;
        equipment = supplied.equipment ?? equipment;
        minutes = supplied.minutes ?? minutes;
      }
      final places = <({int offset, String id})>[];
      for (final entry in const {
        'office': r'办公室|在公司|在工位|办公区',
        'home': r'在家|家里|居家',
        'gym': r'健身房',
      }.entries) {
        for (final match in RegExp(entry.value).allMatches(message)) {
          final prefix = message
              .substring(0, match.start)
              .split(RegExp(r'[，,。；;\n]'))
              .last;
          if (RegExp(r'(?:不去|不在|不是|不想去|不要去|没在)\s*(?:去|在)?$').hasMatch(prefix)) {
            continue;
          }
          places.add((offset: match.start, id: entry.key));
        }
      }
      places.sort((a, b) => a.offset.compareTo(b.offset));
      if (places.isNotEmpty) scene = places.last.id;
      final duration = RegExp(
        r'(\d+|[一二三四五六七八九十两]+)\s*(?:\+|以上)?\s*(?:分钟|分(?!钟))',
      ).allMatches(message);
      if (duration.isNotEmpty) {
        final value = duration.last.group(1)!;
        const digits = {
          '一': 1,
          '二': 2,
          '两': 2,
          '三': 3,
          '四': 4,
          '五': 5,
          '六': 6,
          '七': 7,
          '八': 8,
          '九': 9,
        };
        final parts = value.split('十');
        minutes =
            int.tryParse(value) ??
            (parts.length == 2
                ? (parts.first.isEmpty ? 1 : digits[parts.first] ?? 0) * 10 +
                      (digits[parts.last] ?? 0)
                : digits[value]);
      }
      if (RegExp(
        r'徒手|没(?:有|什么)?(?:任何)?器械|无器械|不(?:用|需要)(?:任何)?器械',
      ).hasMatch(message)) {
        equipment = <String>{};
      } else {
        final found = <String>{};
        final excluded = <String>{};
        for (final entry in labels.entries) {
          final aliases = switch (entry.key) {
            'mat' => ['瑜伽垫', '垫子', '只有垫', '有垫'],
            'chair' => ['椅子', '椅'],
            'dumbbell' => ['哑铃'],
            _ => [entry.value],
          };
          for (final clause in message.split(RegExp(r'[，,。；;\n]'))) {
            if (!aliases.any(
              (label) => label.isNotEmpty && clause.contains(label),
            )) {
              continue;
            }
            final denied = aliases.any(
              (label) => RegExp(
                '(?:没(?:有|带)?|不用|不带|不需要|不想用|无)\\s*(?:任何|那个|这[个些])?${RegExp.escape(label)}',
              ).hasMatch(clause),
            );
            if (denied) {
              excluded.add(entry.key);
            } else {
              found.add(entry.key);
            }
          }
        }
        if (found.isNotEmpty) {
          equipment = found..removeAll(excluded);
        } else if (excluded.isNotEmpty && equipment != null) {
          equipment = {...equipment}..removeAll(excluded);
        }
      }
      skipped = RegExp(r'直接出|跳过|不确定|你决定|随便').hasMatch(message);
    }
    return TrainingParameters._(
      supplied.copyWith(scene: scene, equipment: equipment, minutes: minutes),
      labels,
      skipped,
    );
  }

  CoachContext resolved(
    CoachProfile profile, {
    required bool clarificationFinished,
  }) {
    if (!clarificationFinished && !skipped) return context;
    return context.copyWith(
      scene: context.scene ?? profile.defaultScene,
      equipment: context.equipment ?? const <String>{},
      minutes:
          context.minutes ??
          int.tryParse(profile.vars['defaultMinutes'] ?? '') ??
          15,
    );
  }

  String prompt(CoachProfile profile, {required bool clarificationFinished}) {
    final current = resolved(
      profile,
      clarificationFinished: clarificationFinished,
    );
    return '# 本次训练参数（只补缺项，一次完成）\n'
        '仅请求训练组/计划或继续未完成的排课任务时适用；找动作、讲解动作不为补齐这些条件而提问。\n'
        '已知：${jsonEncode(current.toJson())}\n'
        '仍缺：${clarificationFinished || skipped ? '无；使用上述默认值直接生成' : missing.join('、')}。'
        '从用户原话、前轮回答和 App 上下文可推断的不再问。\n'
        '器械选项只能来自当前库：${jsonEncode(['徒手', ...equipmentLabels.values])}。'
        '一次 form 可同时询问缺少的 scene/equipment/minutes；有“直接出方案”。'
        '已知或默认 equipment 为 [] 时，只选择不需要器械的动作；不额外假设家中有垫、椅或哑铃。';
  }

  Iterable<PlanIssue> validate(
    TrainingPlan plan,
    Catalog catalog,
    CoachContext effective,
  ) sync* {
    if (effective.minutes case final target?) {
      final estimated =
          const PlanDuration().estimateSeconds(plan, catalog) / 60;
      if ((estimated - target).abs() / target > .25) {
        yield PlanIssue(
          IssueCodes.contextConflict,
          '实际训练估时偏离用户要求过大',
          path: 'blocks',
          expected: '目标$target分钟上下25%以内',
          actual: '${estimated.toStringAsFixed(1)}分钟',
          fix: '调整动作数、组数和工作时长，不只修改targetMinutes标签',
        );
      }
    }
    final allowed = effective.equipment;
    if (allowed == null) return;
    for (var bi = 0; bi < plan.blocks.length; bi++) {
      final block = plan.blocks[bi];
      for (var ii = 0; ii < block.items.length; ii++) {
        final item = block.items[ii];
        for (final id in [
          item.exerciseId,
          ...item.segments.map((s) => s.exerciseId).whereType<String>(),
        ]) {
          final drill = catalog[id];
          final absent =
              drill?.equipment
                  .where((id) => id != 'none' && !allowed.contains(id))
                  .toList() ??
              [];
          if (absent.isNotEmpty) {
            yield PlanIssue(
              IssueCodes.equipment,
              '动作需要用户未提供的器械',
              path: 'blocks[$bi].items[$ii].exerciseId',
              exerciseId: id,
              expected: allowed.join('/'),
              actual: absent.join('/'),
              fix: '只用用户实际可用器械的动作',
            );
          }
        }
      }
    }
  }
}
