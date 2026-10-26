import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';
import '../rhythm/rhythm.dart';
import '../ui/trainer_player.dart';
import '../ui/trainer_strings.dart';
import '../ui/trainer_surface.dart';
import '../ui/trainer_theme.dart';
import 'pose_hub_media_preparation.dart';
import 'pose_hub_pack_image.dart';

const poseHubEquipmentLabels = <String, String>{
  'mat': '瑜伽垫',
  'chair': '椅子',
  'band': '弹力带',
  'dumbbell': '哑铃',
  'wall': '墙',
  'cable': '绳索器械',
  'block': '瑜伽砖',
  'pullup-bar': '单杠',
  'parallettes': '俯卧撑架',
  'dip-bars': '双杠',
  'slider': '滑盘',
  'rings': '吊环',
  'landmine': '地雷杆',
  'swiss-ball': '健身球',
  'roman-chair': '罗马椅',
  'kettlebell': '壶铃',
  'reverse-hyper': '反向挺身机',
  'ghd': '臀腿训练器',
  'hip-abductor-machine': '髋外展机',
  'leg-extension-machine': '腿屈伸机',
  'foam-roller': '泡沫轴',
};

@Deprecated(
  'The user library only exposes complete actions with user-facing facets.',
)
enum PoseHubActionFilter { all, semanticComplete, pending }

/// User-facing facets derived from complete catalogue definitions.
abstract final class PoseHubActionFacets {
  static List<String> equipment(PoseHubPackAction action) =>
      (action.raw['equipment'] as List?)?.whereType<String>().toList() ?? [];

  static Set<String> bodyParts(PoseHubPackAction action) {
    final muscles =
        (action.raw['muscleGroups'] as List?)?.whereType<String>() ?? [];
    final parts = <String>{};
    for (final muscle in muscles) {
      parts.add(switch (muscle) {
        'chest' => '胸',
        'lats' || 'erectors' || 'scapular' => '背',
        'deltoids' || 'rotator-cuff' || 'serratus' => '肩',
        'biceps' || 'triceps' || 'forearms' => '手臂',
        'abs' || 'obliques' => '核心',
        'glute-max' ||
        'hip-abductors' ||
        'hamstrings' ||
        'quadriceps' ||
        'hip-flexors' ||
        'adductors' ||
        'calves' ||
        'tibialis' => '臀腿',
        _ => '全身',
      });
    }
    if (parts.length >= 3 || action.raw['category'] == 'cardio') {
      parts.add('全身');
    }
    return parts;
  }

  static String type(PoseHubPackAction action) =>
      switch (action.raw['category']) {
        'stretch' || 'mobility' => '拉伸放松',
        'strength' || 'core' => '力量',
        _ => '其他',
      };

  static bool matches(
    PoseHubPackAction action, {
    String query = '',
    String equipment = '全部',
    String bodyPart = '全部',
    String type = '全部',
  }) {
    if (!action.trainingDefinitionComplete || !action.availableForApp) {
      return false;
    }
    final aliases = action.raw['aliasesZh'] ?? action.raw['aliases'];
    final names = [
      action.nameZh,
      if (aliases is List) ...aliases.whereType<String>(),
    ];
    final term = query.trim();
    if (term.isNotEmpty &&
        !names.any(
          (name) =>
              RegExp(r'[\u3400-\u9fff]').hasMatch(name) && name.contains(term),
        )) {
      return false;
    }
    final tools = PoseHubActionFacets.equipment(action);
    if (equipment == '徒手' && tools.isNotEmpty) return false;
    if (equipment == '需要器械' && tools.isEmpty) return false;
    if (!const ['全部', '徒手', '需要器械'].contains(equipment) &&
        !tools.contains(equipment)) {
      return false;
    }
    if (bodyPart != '全部' && !bodyParts(action).contains(bodyPart)) return false;
    if (type != '全部' && PoseHubActionFacets.type(action) != type) return false;
    return true;
  }
}

class PoseHubActionBrowser extends StatefulWidget {
  const PoseHubActionBrowser({
    super.key,
    required this.catalog,
    required this.mediaBaseUri,
    this.theme,
    this.onPracticeFinished,
    this.mediaPreparer,
    this.voice,
  });
  final PoseHubAppTestCatalog catalog;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  final TrainerVoice? voice;
  @override
  State<PoseHubActionBrowser> createState() => _PoseHubActionBrowserState();
}

class _PoseHubActionBrowserState extends State<PoseHubActionBrowser> {
  String _query = '', _equipment = '全部', _body = '全部', _type = '全部';

  @override
  Widget build(BuildContext context) {
    final theme = _themeOf(context, widget.theme);
    final nameHeight =
        MediaQuery.textScalerOf(context).scale(theme.callout.fontSize ?? 16) *
            (theme.callout.height ?? 1.3) *
            2 +
        8;
    final equipment =
        widget.catalog.semanticCompleteActions
            .expand(PoseHubActionFacets.equipment)
            .toSet()
            .toList()
          ..sort();
    final actions = widget.catalog.semanticCompleteActions
        .where(
          (action) => PoseHubActionFacets.matches(
            action,
            query: _query,
            equipment: _equipment,
            bodyPart: _body,
            type: _type,
          ),
        )
        .toList(growable: false);
    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: const Text('动作库'),
        backgroundColor: theme.surface,
        foregroundColor: theme.text,
        surfaceTintColor: theme.surface,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                key: const ValueKey('posehub-search'),
                style: theme.body,
                cursorColor: theme.accent,
                decoration: InputDecoration(
                  hintText: '搜索动作',
                  hintStyle: theme.body.copyWith(color: theme.muted),
                  prefixIcon: Icon(CupertinoIcons.search, color: theme.muted),
                  filled: true,
                  fillColor: theme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.radius),
                  ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            _filters(
              '器械',
              ['全部', '徒手', '需要器械', ...equipment],
              _equipment,
              (value) => setState(() => _equipment = value),
              theme,
              label: (value) => const ['全部', '徒手', '需要器械'].contains(value)
                  ? value
                  : poseHubEquipmentLabels[value] ?? '其他器械',
            ),
            _filters(
              '部位',
              const ['全部', '胸', '背', '肩', '手臂', '核心', '臀腿', '全身'],
              _body,
              (value) => setState(() => _body = value),
              theme,
            ),
            _filters(
              '类型',
              const ['全部', '力量', '拉伸放松'],
              _type,
              (value) => setState(() => _type = value),
              theme,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: actions.isEmpty
                  ? Center(child: Text('没有符合条件的动作', style: theme.body))
                  : GridView.builder(
                      key: const ValueKey('posehub-action-list'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        mainAxisExtent:
                            (MediaQuery.sizeOf(context).width - 44) / 2 +
                            nameHeight +
                            8,
                      ),
                      itemCount: actions.length,
                      itemBuilder: (context, index) {
                        final action = actions[index];
                        return Semantics(
                          button: true,
                          label: action.nameZh,
                          child: GestureDetector(
                            key: ValueKey('posehub-action-${action.id}'),
                            onTap: () => Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => PoseHubSinglePracticePage(
                                  action: action,
                                  mediaBaseUri: widget.mediaBaseUri,
                                  theme: theme,
                                  onFinished: widget.onPracticeFinished,
                                  mediaPreparer: widget.mediaPreparer,
                                  voice: widget.voice,
                                ),
                              ),
                            ),
                            child: TrainerSurface(
                              theme: theme,
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: PoseHubStandingImage(
                                      action: action,
                                      theme: theme,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: nameHeight,
                                    child: Center(
                                      child: Text(
                                        action.nameZh,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: theme.callout,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filters(
    String title,
    List<String> options,
    String selected,
    ValueChanged<String> onChanged,
    TrainerTheme theme, {
    String Function(String)? label,
  }) => SizedBox(
    height:
        (MediaQuery.textScalerOf(context).scale(theme.label.fontSize ?? 13) +
                28)
            .clamp(42, double.infinity),
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Text(title, style: theme.label),
        ),
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(right: 16),
            itemCount: options.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (_, index) {
              final value = options[index];
              return ChoiceChip(
                key: ValueKey('posehub-$title-$value'),
                label: Text(label?.call(value) ?? value),
                selected: selected == value,
                showCheckmark: false,
                labelStyle: theme.label.copyWith(
                  color: selected == value ? theme.accentText : theme.text,
                ),
                selectedColor: theme.surfaceHigh,
                backgroundColor: theme.surface,
                side: BorderSide(color: theme.border),
                onSelected: (_) => onChanged(value),
              );
            },
          ),
        ),
      ],
    ),
  );
}

@immutable
class PoseHubPracticeResult {
  const PoseHubPracticeResult({
    required this.actionId,
    required this.activeDuration,
    required this.trainingDefinitionComplete,
  });
  final String actionId;
  final Duration activeDuration;
  final bool trainingDefinitionComplete;
}

/// Kept for source compatibility; the removed detail UI now opens training.
@Deprecated(
  'Use PoseHubSinglePracticePage; details now open the shared trainer.',
)
class PoseHubActionDetail extends StatelessWidget {
  const PoseHubActionDetail({
    super.key,
    required this.action,
    required this.mediaBaseUri,
    this.theme,
    this.onPracticeFinished,
    this.mediaPreparer,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  @override
  Widget build(BuildContext context) => PoseHubSinglePracticePage(
    action: action,
    mediaBaseUri: mediaBaseUri,
    theme: theme,
    onFinished: onPracticeFinished,
    mediaPreparer: mediaPreparer,
  );
}

/// Compatibility entry backed by the same one-action training player.
/// Dose comes from complete catalogue semantics, never from video duration.
class PoseHubSinglePracticePage extends StatelessWidget {
  const PoseHubSinglePracticePage({
    super.key,
    required this.action,
    required this.mediaBaseUri,
    this.theme,
    this.onFinished,
    this.mediaPreparer,
    this.voice,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  final TrainerVoice? voice;

  @override
  Widget build(BuildContext context) {
    if (!action.trainingDefinitionComplete) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('此动作暂未开放训练')),
      );
    }
    final dose = action.raw['defaultDose']! as Map;
    final cues = action.raw['cues'] as Map?;
    final zh = cues?['zh'] as List?;
    final cue = zh?.whereType<String>().join('；');
    final item = PlanItem(
      exerciseId: action.id,
      mode: dose['mode'] == 'reps' ? DoseMode.reps : DoseMode.time,
      sets: dose['sets']! as int,
      reps: dose['reps'] as int?,
      workSeconds: dose['seconds'] as int?,
      perSide: action.raw['unilateral'] == true,
      restSeconds: dose['restSeconds']! as int,
    );
    final rhythms = {
      action.id: Rhythm.forDose(
        item.mode,
        category: action.raw['category'] as String?,
        holdSeconds: (dose['holdSeconds'] as num?)?.toDouble(),
      ),
    };
    final scenes = (action.raw['scenes'] as List).whereType<String>();
    var plan = TrainingPlan(
      id: 'practice-${action.id}',
      source: 'template',
      title: action.nameZh,
      goal: action.raw['purpose'] as String? ?? '',
      scene: scenes.first,
      equipment: PoseHubActionFacets.equipment(action),
      level: action.raw['level'] as int? ?? 1,
      targetMinutes: 1,
      blocks: [
        PlanBlock(
          id: 'single',
          name: action.nameZh,
          type: BlockType.main,
          items: [item],
        ),
      ],
    );
    final seconds = SessionBuilder(
      rhythms: rhythms,
      prepSeconds: 0,
    ).phases(plan).fold<double>(0, (sum, phase) => sum + phase.seconds);
    plan = plan.copyWith(targetMinutes: (seconds / 60).ceil().clamp(1, 10000));
    return TrainerPlayer(
      key: ValueKey('posehub-practice-${action.id}'),
      plan: plan,
      rhythms: rhythms,
      strings: TrainerStrings.zh(),
      theme: _themeOf(context, theme),
      drillOf: (id) => id == action.id
          ? TrainerDrill(id: id, name: action.nameZh, cue: cue)
          : null,
      poseHubActionOf: (id) => id == action.id ? action : null,
      poseHubMediaBaseUri: mediaBaseUri,
      poseHubMediaPreparer: mediaPreparer,
      voice: voice,
      prepSeconds: 0,
      onFinished: (result) async => onFinished?.call(
        PoseHubPracticeResult(
          actionId: action.id,
          activeDuration: Duration(
            microseconds: (result.activeSeconds * 1e6).round(),
          ),
          trainingDefinitionComplete: true,
        ),
      ),
    );
  }
}

TrainerTheme _themeOf(BuildContext context, TrainerTheme? supplied) =>
    supplied ??
    (Theme.of(context).brightness == Brightness.dark
        ? TrainerTheme.dark
        : TrainerTheme.light);
