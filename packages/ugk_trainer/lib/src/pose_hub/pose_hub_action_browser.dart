import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';
import '../result/session_result.dart';
import '../rhythm/rhythm.dart';
import '../ui/trainer_player.dart';
import '../ui/trainer_strings.dart';
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
    this.onStartTraining,
    this.onCompleted,
  });
  final PoseHubAppTestCatalog catalog;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  final TrainerVoice? voice;
  final VoidCallback? onStartTraining;
  final Future<void> Function(SessionResult result)? onCompleted;
  @override
  State<PoseHubActionBrowser> createState() => _PoseHubActionBrowserState();
}

class _PoseHubActionBrowserState extends State<PoseHubActionBrowser> {
  String _query = '', _equipment = '全部', _body = '全部', _type = '全部';
  final _search = TextEditingController();

  bool get _hasSelection =>
      _query.trim().isNotEmpty ||
      _equipment != '全部' ||
      _body != '全部' ||
      _type != '全部';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clear() {
    _search.clear();
    setState(() {
      _query = '';
      _equipment = _body = _type = '全部';
    });
  }

  String _equipmentLabel(String value) =>
      const ['全部', '徒手', '需要器械'].contains(value)
      ? value
      : poseHubEquipmentLabels[value] ?? '其他器械';

  Color _selectedBackground(TrainerTheme theme) => Color.alphaBlend(
    theme.accent.withValues(alpha: theme.isDark ? .22 : .12),
    theme.surface,
  );

  Color _selectedForeground(TrainerTheme theme) => theme.accentText;

  @override
  Widget build(BuildContext context) {
    final theme = _themeOf(context, widget.theme);
    final scaler = MediaQuery.textScalerOf(context);
    final nameHeight = scaler.scale(15) * 1.35 * 2;
    final tagHeight = scaler.scale(12) * 1.35;
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
                controller: _search,
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
              label: _equipmentLabel,
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
            _selectionSummary(theme),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final cardWidth = (box.maxWidth - 44) / 2;
                  return actions.isEmpty
                      ? _emptyState(theme)
                      : GridView.builder(
                          key: const ValueKey('posehub-action-list'),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                mainAxisExtent:
                                    cardWidth + 12 + nameHeight + 4 + tagHeight,
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
                                      startMode: TrainerStartMode.preview,
                                      onStartTraining: widget.onStartTraining,
                                      onCompleted: widget.onCompleted,
                                    ),
                                  ),
                                ),
                                child: DecoratedBox(
                                  key: ValueKey(
                                    'posehub-card-surface-${action.id}',
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.cardSurface,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: theme.cardBorder),
                                  ),
                                  child: ClipRRect(
                                    key: ValueKey(
                                      'posehub-card-clip-${action.id}',
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          AspectRatio(
                                            key: ValueKey(
                                              'posehub-image-area-${action.id}',
                                            ),
                                            aspectRatio: 1,
                                            child: PoseHubStandingImage(
                                              action: action,
                                              theme: theme,
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                            height: nameHeight,
                                            child: Text(
                                              action.nameZh,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.callout.copyWith(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w600,
                                                height: 1.35,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          SizedBox(
                                            key: ValueKey(
                                              'posehub-card-tags-${action.id}',
                                            ),
                                            height: tagHeight,
                                            child: Text(
                                              '${PoseHubActionFacets.type(action)} · ${_actionEquipment(action)}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.label.copyWith(
                                                fontSize: 12,
                                                height: 1.35,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionSummary(TrainerTheme theme) {
    final labels = [
      if (_query.trim().isNotEmpty) '搜索：${_query.trim()}',
      if (_equipment != '全部') '器械：${_equipmentLabel(_equipment)}',
      if (_body != '全部') '部位：$_body',
      if (_type != '全部') '类型：$_type',
    ];
    return Padding(
      key: const ValueKey('posehub-selection-summary'),
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: labels.isEmpty
                ? Text('全部动作', style: theme.label)
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final label in labels)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: _selectedBackground(theme),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                child: Text(
                                  label,
                                  style: theme.label.copyWith(
                                    color: _selectedForeground(theme),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          TextButton(
            key: const ValueKey('posehub-clear-filters'),
            onPressed: _hasSelection ? _clear : null,
            style: TextButton.styleFrom(
              foregroundColor: _selectedForeground(theme),
            ),
            child: const Text('清除'),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(TrainerTheme theme) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        key: const ValueKey('posehub-empty-state'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 44, color: theme.muted),
          const SizedBox(height: 12),
          Text('没有符合条件的动作', style: theme.callout, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(
            '试试其他关键词，或清除筛选',
            style: theme.label,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextButton(
            key: const ValueKey('posehub-empty-clear'),
            onPressed: _clear,
            style: TextButton.styleFrom(
              foregroundColor: _selectedForeground(theme),
            ),
            child: const Text('清除筛选'),
          ),
        ],
      ),
    ),
  );

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
            key: ValueKey('posehub-filter-options-$title'),
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
                showCheckmark: true,
                checkmarkColor: _selectedForeground(theme),
                labelStyle: theme.label.copyWith(
                  color: selected == value
                      ? _selectedForeground(theme)
                      : theme.text,
                ),
                selectedColor: _selectedBackground(theme),
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
    this.startMode = TrainerStartMode.training,
    this.onStartTraining,
    this.onCompleted,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  final TrainerVoice? voice;
  final TrainerStartMode startMode;
  final VoidCallback? onStartTraining;
  final Future<void> Function(SessionResult result)? onCompleted;

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
    final cueList =
        zh?.whereType<String>().toList(growable: false) ?? const <String>[];
    final cautionAreas =
        (action.raw['cautions'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final precautions = [
      if (cautionAreas.isNotEmpty) '注意部位：${cautionAreas.join('、')}',
      ...(action.raw['contraindications'] as List?)?.whereType<String>() ??
          const <String>[],
    ];
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
      startMode: startMode,
      onStartTraining: onStartTraining,
      onCompleted: onCompleted,
      drillOf: (id) => id == action.id
          ? TrainerDrill(
              id: id,
              name: action.nameZh,
              cues: cueList,
              precautions: precautions,
              targetMuscles: action.raw['muscleGroupsZh'] as String?,
              equipment: _actionEquipment(action),
              thumbnailAsset:
                  'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/standing/$id.webp',
            )
          : null,
      poseHubActionOf: (id) => id == action.id ? action : null,
      poseHubMediaBaseUri: mediaBaseUri,
      poseHubMediaPreparer: mediaPreparer,
      voice: voice,
      prepSeconds: startMode == TrainerStartMode.preview ? 10 : 0,
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

String _actionEquipment(PoseHubPackAction action) {
  final equipment = PoseHubActionFacets.equipment(action);
  if (equipment.isEmpty) return '徒手';
  return equipment.map((id) => poseHubEquipmentLabels[id] ?? '其他器械').join('、');
}

TrainerTheme _themeOf(BuildContext context, TrainerTheme? supplied) =>
    supplied ??
    (Theme.of(context).brightness == Brightness.dark
        ? TrainerTheme.dark
        : TrainerTheme.light);
