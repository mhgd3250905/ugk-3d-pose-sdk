import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_theme.dart';
import 'training_library_config.dart';
import 'training_library_style.dart';

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

/// User-facing facets derived from complete catalogue definitions.
abstract final class PoseHubActionFacets {
  static List<String> equipment(PoseHubPackAction action) =>
      (action.raw['equipment'] as List?)?.whereType<String>().toList() ?? [];

  static String equipmentText(PoseHubPackAction action) {
    final values = equipment(action);
    if (values.isEmpty) return '徒手';
    return values.map((id) => poseHubEquipmentLabels[id] ?? '其他器械').join('、');
  }

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

/// Public action search, facets and cards shared by product libraries.
///
/// This component owns no media paths, assets, downloads or practice routes.
/// The caller supplies the catalogue actions, artwork and selection callback.
class TrainingLibraryBrowser extends StatefulWidget {
  const TrainingLibraryBrowser({
    super.key,
    required this.actions,
    required this.actionArtwork,
    required this.onOpenAction,
    this.config,
    this.theme,
    this.embedded = false,
  });
  final Iterable<PoseHubPackAction> actions;
  final Widget Function(BuildContext, PoseHubPackAction, TrainerTheme)
  actionArtwork;
  final ValueChanged<PoseHubPackAction> onOpenAction;
  final TrainingLibraryConfig? config;
  final TrainerTheme? theme;
  final bool embedded;
  @override
  State<TrainingLibraryBrowser> createState() => _TrainingLibraryBrowserState();
}

class _TrainingLibraryBrowserState extends State<TrainingLibraryBrowser> {
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

  String _equipmentLabel(String value) => value == '全部'
      ? (widget.config?.strings.all ?? value)
      : const ['徒手', '需要器械'].contains(value)
      ? value
      : poseHubEquipmentLabels[value] ?? '其他器械';

  Color _selectedBackground(TrainerTheme theme) => Color.alphaBlend(
    theme.accent.withValues(alpha: theme.isDark ? .22 : .12),
    theme.surface,
  );

  Color _selectedForeground(TrainerTheme theme) => theme.accentText;

  @override
  Widget build(BuildContext context) {
    final theme = TrainingLibraryStyle.themeOf(context, widget.theme);
    final strings = widget.config?.strings ?? const TrainingLibraryStrings();
    final libraryActions = widget.config == null
        ? widget.actions
        : widget.actions.where(
            (action) =>
                widget.config!.allowedActionIds.contains(action.id) &&
                action.availableForApp,
          );
    final scaler = MediaQuery.textScalerOf(context);
    final nameHeight = scaler.scale(15) * 1.35 * 2;
    final tagHeight = scaler.scale(12) * 1.35;
    final equipment =
        libraryActions.expand(PoseHubActionFacets.equipment).toSet().toList()
          ..sort();
    final actions = libraryActions
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
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(
                widget.config?.brand.isNotEmpty == true
                    ? '${widget.config!.brand} · ${strings.title}'
                    : strings.title,
              ),
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
                  hintText: strings.searchHint,
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
              strings.equipment,
              ['全部', '徒手', '需要器械', ...equipment],
              _equipment,
              (value) => setState(() => _equipment = value),
              theme,
              label: _equipmentLabel,
            ),
            _filters(
              strings.bodyPart,
              const ['全部', '胸', '背', '肩', '手臂', '核心', '臀腿', '全身'],
              _body,
              (value) => setState(() => _body = value),
              theme,
            ),
            _filters(
              strings.category,
              [
                '全部',
                ...?widget.config?.categoryOrder,
                if (widget.config == null) ...['力量', '拉伸放松'],
              ],
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
                                onTap: () => widget.onOpenAction(action),
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
                                            child: widget.actionArtwork(
                                              context,
                                              action,
                                              theme,
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
                                              '${PoseHubActionFacets.type(action)} · ${PoseHubActionFacets.equipmentText(action)}',
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
      if (_query.trim().isNotEmpty)
        '${widget.config?.strings.searchHint ?? '搜索'}：${_query.trim()}',
      if (_equipment != '全部')
        '${widget.config?.strings.equipment ?? '器械'}：${_equipmentLabel(_equipment)}',
      if (_body != '全部') '${widget.config?.strings.bodyPart ?? '部位'}：$_body',
      if (_type != '全部') '${widget.config?.strings.category ?? '类型'}：$_type',
    ];
    return Padding(
      key: const ValueKey('posehub-selection-summary'),
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: labels.isEmpty
                ? Text(
                    widget.config?.strings.allActions ?? '全部动作',
                    style: theme.label,
                  )
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
            child: Text(widget.config?.strings.clear ?? '清除'),
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
          Text(
            widget.config?.strings.emptyTitle ?? '没有符合条件的动作',
            style: theme.callout,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            widget.config?.strings.emptyBody ?? '试试其他关键词，或清除筛选',
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
            child: Text(widget.config?.strings.clearFilters ?? '清除筛选'),
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
                label: Text(
                  label?.call(value) ??
                      (value == '全部'
                          ? widget.config?.strings.all ?? value
                          : value),
                ),
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
