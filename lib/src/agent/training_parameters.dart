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
              (label) =>
                  RegExp(
                    '(?:没(?:有|带)?|不用|不使用|不再用|不带|不需要|不想用|无)\\s*(?:任何|那个|这[个些])?${RegExp.escape(label)}',
                  ).hasMatch(clause) ||
                  RegExp(
                    '${RegExp.escape(label)}\\s*(?:不用(?:了)?|不要(?:了)?|没有了|不再用|移除|去掉|删掉)',
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
          final replaces = RegExp(
            r'只(?:能|要)?(?:用|使用|有)|仅(?:用|使用|有)|改(?:为|成)|换(?:为|成)',
          ).hasMatch(message);
          final adds = RegExp(
            r'增加|再加|加上|加(?:一个|一把|一张|个|把|张|些)|添加|加入|另加|多加',
          ).hasMatch(message);
          equipment = adds && !replaces && equipment != null
              ? ({...equipment, ...found}..removeAll(excluded))
              : (found..removeAll(excluded));
        } else if (excluded.isNotEmpty && equipment != null) {
          equipment = {...equipment}..removeAll(excluded);
        }
      }
      skipped = RegExp(r'直接出|按默认来|跳过|不确定|你决定|随便').hasMatch(message);
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
    return '# 本次训练参数\n'
        '本段仅适用于生成或调整训练组；动作搜索、讲解和安全筛查不使用这三项追问规则。\n'
        '当前条件：${jsonEncode(current.toJson())}\n'
        '仍缺：${clarificationFinished || skipped ? '无；使用用户确认或接受的默认值' : missing.join('、')}。'
        '新训练只以本次需求为准，历史条件仅作为可更改建议；缺项由 SDK 展示三项确认卡。'
        '用户本次已明确全部条件或已确认后，直接根据这些条件生成，不再重复询问。\n'
        '器械选项只能来自当前库：${jsonEncode(['徒手', ...equipmentLabels.values])}。'
        '已知或默认 equipment 为 [] 时，只选择不需要器械的动作；不额外假设家中有垫、椅或哑铃。'
        '用户选了器械时，优先选择适合训练目标、可使用所选器械的动作；不可为了使用器械牺牲目标或安全。'
        '计划 equipment 必须只列实际动作所需器械，包括椅、墙和垫；纯徒手用空列表，不要列出未使用的可用器械。';
  }

  Iterable<PlanIssue> validate(
    TrainingPlan plan,
    Catalog catalog,
    CoachContext effective, {
    bool enforceDurationEstimate = true,
  }) sync* {
    if (effective.minutes case final target?) {
      // This rule also runs for admitted fallback templates, which do not
      // pass through ToolGate's raw model-output checks.
      if (plan.targetMinutes != target) {
        yield PlanIssue(
          IssueCodes.contextConflict,
          '计划时长与已确认的时长不符',
          path: 'targetMinutes',
          expected: '$target',
          actual: '${plan.targetMinutes}',
          fix: '按已确认的时长重新安排训练',
        );
      }
      final estimated =
          const PlanDuration().estimateSeconds(plan, catalog) / 60;
      if (enforceDurationEstimate &&
          (estimated - target).abs() / target > .25) {
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
    // This field describes equipment used by the plan, not all equipment
    // the user owns. A subset is therefore valid; unconfirmed gear is not.
    final unconfirmed = plan.equipment
        .where((id) => id != 'none' && !allowed.contains(id))
        .toSet();
    if (unconfirmed.isNotEmpty) {
      yield PlanIssue(
        IssueCodes.equipment,
        '计划声明了用户未提供的器械',
        path: 'equipment',
        expected: (allowed.toList()..sort()).join('/'),
        actual: (unconfirmed.toList()..sort()).join('/'),
        fix: '只声明用户实际可用的器械',
      );
    }
    final used = <String>{};
    var unknownAction = false;
    for (var bi = 0; bi < plan.blocks.length; bi++) {
      final block = plan.blocks[bi];
      for (var ii = 0; ii < block.items.length; ii++) {
        final item = block.items[ii];
        // Segments replace the parent work dose in the trainer. Report the
        // equipment for the exercises that will actually be performed.
        final performed = item.segments.isEmpty
            ? [item.exerciseId]
            : item.segments.map((segment) => segment.exerciseId);
        for (final id in performed) {
          final drill = catalog[id];
          if (drill == null) {
            unknownAction = true; // The validator reports the unknown ID.
          } else {
            used.addAll(drill.equipment.where((id) => id != 'none'));
          }
        }
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
    if (!unknownAction) {
      final declared = plan.equipment.where((id) => id != 'none').toSet();
      if (used.difference(declared).isNotEmpty ||
          declared.difference(used).isNotEmpty) {
        yield PlanIssue(
          IssueCodes.equipment,
          '计划声明器械与实际动作所需器械不一致',
          path: 'equipment',
          expected: (used.toList()..sort()).join('/'),
          actual: (declared.toList()..sort()).join('/'),
          fix: '按动作实际所需器械填写 equipment，未用到的不要写',
        );
      }
    }
  }
}
