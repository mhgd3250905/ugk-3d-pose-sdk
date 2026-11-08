import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_theme.dart';
import 'training_library_config.dart';
import 'training_library_filter.dart';
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
  'towel': '毛巾',
  'doorframe': '门框',
  'bench': '训练凳',
  'barbell': '杠铃',
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
    int? level,
    TrainingLibrarySide side = TrainingLibrarySide.any,
    String? muscle,
    Iterable<String> extraNames = const [],
  }) {
    if (!action.trainingDefinitionComplete || !action.availableForApp) {
      return false;
    }
    final term = _normalize(query);
    if (term.isNotEmpty &&
        !searchNames(
          action,
          extraNames: extraNames,
        ).any((name) => _normalize(name).contains(term))) {
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
    if (level != null && PoseHubActionFacets.level(action) != level) {
      return false;
    }
    if (side != TrainingLibrarySide.any &&
        (action.raw['unilateral'] == true) !=
            (side == TrainingLibrarySide.unilateral)) {
      return false;
    }
    if (muscle != null && !muscles(action).contains(muscle)) return false;
    return true;
  }

  /// [matches] for one [TrainingLibraryFilter].
  static bool matchesFilter(
    PoseHubPackAction action,
    TrainingLibraryFilter filter, {
    Iterable<String> extraNames = const [],
  }) => matches(
    action,
    query: filter.query,
    equipment: filter.equipment,
    bodyPart: filter.bodyPart,
    type: filter.type,
    level: filter.level,
    side: filter.side,
    muscle: filter.muscle,
    extraNames: extraNames,
  );

  /// Catalogue difficulty 1–3, or null when the catalogue has none.
  static int? level(PoseHubPackAction action) => switch (action.raw['level']) {
    final int value => value,
    final num value => value.round(),
    _ => null,
  };

  static Set<String> muscles(PoseHubPackAction action) =>
      ((action.raw['muscleGroups'] as List?)?.whereType<String>() ??
              const <String>[])
          .toSet();

  /// Every name the search box matches: the Chinese name and aliases, any
  /// English name / alias fields, the action id as words, and [extraNames].
  static Iterable<String> searchNames(
    PoseHubPackAction action, {
    Iterable<String> extraNames = const [],
  }) sync* {
    yield action.nameZh;
    for (final key in const [
      'aliasesZh',
      'aliases',
      'nameEn',
      'aliasesEn',
      'name',
      'names',
    ]) {
      yield* _texts(action.raw[key]);
    }
    yield action.id.replaceAll(RegExp(r'[-_]+'), ' ');
    yield* _texts(action.raw['muscles']);
    for (final muscle in muscles(action)) {
      if (poseHubMuscleLabels[muscle] case final label?) yield label;
      yield* poseHubMuscleSearchTerms[muscle] ?? const <String>[];
    }
    yield* extraNames;
  }

  static Iterable<String> _texts(Object? value) sync* {
    if (value is String) {
      yield value;
    } else if (value is List) {
      for (final item in value) {
        yield* _texts(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        yield* _texts(item);
      }
    }
  }

  static String _normalize(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');
}

/// Body parts in the library's quick row and filter sheet.
const poseHubBodyParts = ['胸', '背', '肩', '手臂', '核心', '臀腿', '全身'];

/// Chinese labels of catalogue muscle-group ids.
const poseHubMuscleLabels = <String, String>{
  'chest': '胸部',
  'lats': '背阔肌',
  'erectors': '竖脊肌',
  'scapular': '肩胛肌群',
  'deltoids': '三角肌',
  'rotator-cuff': '肩袖',
  'serratus': '前锯肌',
  'biceps': '肱二头肌',
  'triceps': '肱三头肌',
  'forearms': '前臂',
  'abs': '腹肌',
  'obliques': '腹斜肌',
  'glute-max': '臀大肌',
  'hip-abductors': '髋外展肌',
  'hamstrings': '腘绳肌',
  'quadriceps': '股四头肌',
  'hip-flexors': '髋屈肌',
  'adductors': '内收肌',
  'calves': '小腿',
  'tibialis': '胫骨前肌',
  'neck': '颈部',
};

/// Everyday and anatomical names that find actions by catalogue muscle group.
///
/// Search matches by substring, so each term is at least two characters.
const poseHubMuscleSearchTerms = <String, List<String>>{
  'chest': ['胸大肌', '胸肌'],
  'lats': ['背部', '背肌'],
  'erectors': ['下背', '腰背', '背部'],
  'scapular': ['斜方肌', '菱形肌', '上背', '背部'],
  'deltoids': ['肩膀', '肩部'],
  'rotator-cuff': ['肩袖肌群', '肩膀', '肩部'],
  'serratus': ['肩胛'],
  'biceps': ['二头肌', '手臂', '臂部', '大臂'],
  'triceps': ['三头肌', '手臂', '臂部', '大臂', '拜拜肉'],
  'forearms': ['小臂', '手腕', '手臂', '臂部', '腕屈伸肌'],
  'abs': ['腹直肌', '腹横肌', '腹部', '核心'],
  'obliques': ['侧腹', '腹部', '核心'],
  'glute-max': ['臀部', '屁股', '臀肌'],
  'hip-abductors': ['臀中肌', '臀部', '臀肌', '髋外侧'],
  'hamstrings': ['大腿后侧', '腿后侧'],
  'quadriceps': ['大腿前侧', '腿前侧'],
  'hip-flexors': ['髂腰肌', '髋前侧', '屈髋'],
  'adductors': ['大腿内侧', '内收肌群'],
  'calves': ['小腿三头肌', '腓肠肌', '比目鱼肌'],
  'tibialis': ['小腿前侧'],
  'neck': ['脖子'],
};

/// Public action search, facets and cards shared by product libraries.
///
/// This component owns no media paths, assets, downloads or practice routes.
/// The caller supplies the catalogue actions, artwork and selection callback.
///
/// Layout: a search box, one horizontal row of quick body-part pills with a
/// fixed 筛选 button (badged with the facet count) that opens a bottom sheet
/// holding every facet, then the two-column action grid.
class TrainingLibraryBrowser extends StatefulWidget {
  const TrainingLibraryBrowser({
    super.key,
    required this.actions,
    required this.actionArtwork,
    required this.onOpenAction,
    this.config,
    this.theme,
    this.embedded = false,
    this.initialFilter = const TrainingLibraryFilter(),
  });
  final Iterable<PoseHubPackAction> actions;
  final Widget Function(BuildContext, PoseHubPackAction, TrainerTheme)
  actionArtwork;
  final ValueChanged<PoseHubPackAction> onOpenAction;
  final TrainingLibraryConfig? config;
  final TrainerTheme? theme;
  final bool embedded;

  /// Selection on first build (search text included). Later changes are not
  /// applied to a mounted browser; give it a new key to restart from one.
  final TrainingLibraryFilter initialFilter;
  @override
  State<TrainingLibraryBrowser> createState() => _TrainingLibraryBrowserState();
}

class _TrainingLibraryBrowserState extends State<TrainingLibraryBrowser> {
  late TrainingLibraryFilter _filter = widget.initialFilter;
  late final _search = TextEditingController(text: widget.initialFilter.query);

  static const _all = TrainingLibraryFilter.all;

  TrainingLibraryStrings get _strings =>
      widget.config?.strings ?? const TrainingLibraryStrings();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clear() {
    _search.clear();
    setState(() => _filter = const TrainingLibraryFilter());
  }

  /// Browsing lists everything but `retired`; `not_recommended` stays
  /// findable so users can still add it by hand.
  Iterable<PoseHubPackAction> get _libraryActions => widget.config == null
      ? widget.actions.where((action) => action.browsable)
      : widget.actions.where(
          (action) =>
              action.browsable &&
              widget.config!.allowedActionIds.contains(action.id) &&
              action.availableForApp,
        );

  List<PoseHubPackAction> _matching(
    Iterable<PoseHubPackAction> actions,
    TrainingLibraryFilter filter,
  ) {
    final names = widget.config?.searchNames;
    return actions
        .where(
          (action) => PoseHubActionFacets.matchesFilter(
            action,
            filter,
            extraNames: [
              ...names?.call(action.id) ?? const [],
              if (widget.config?.displayText?.call(action.id)?.name
                  case final String name)
                name,
            ],
          ),
        )
        .toList(growable: false);
  }

  String _equipmentLabel(String value) => value == _all
      ? _strings.all
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
    final strings = _strings;
    final libraryActions = _libraryActions.toList(growable: false);
    final scaler = MediaQuery.textScalerOf(context);
    final nameHeight = scaler.scale(15) * 1.35 * 2;
    final tagHeight = scaler.scale(12) * 1.35;
    final actions = _matching(libraryActions, _filter);
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
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: strings.searchHint,
                  hintStyle: theme.body.copyWith(color: theme.muted),
                  hintMaxLines: 1,
                  prefixIcon: Icon(CupertinoIcons.search, color: theme.muted),
                  suffixIcon: _filter.query.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('posehub-search-clear'),
                          tooltip: strings.clear,
                          icon: Icon(Icons.close_rounded, color: theme.muted),
                          onPressed: () {
                            _search.clear();
                            setState(
                              () => _filter = _filter.copyWith(query: ''),
                            );
                          },
                        ),
                  filled: true,
                  fillColor: theme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.radius),
                  ),
                ),
                onChanged: (value) =>
                    setState(() => _filter = _filter.copyWith(query: value)),
              ),
            ),
            _quickRow(theme, libraryActions),
            const SizedBox(height: 8),
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
                          itemBuilder: (context, index) => _card(
                            context,
                            actions[index],
                            theme,
                            nameHeight,
                            tagHeight,
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

  Widget _card(
    BuildContext context,
    PoseHubPackAction action,
    TrainerTheme theme,
    double nameHeight,
    double tagHeight,
  ) => Semantics(
    button: true,
    label: widget.config?.displayText?.call(action.id)?.name ?? action.nameZh,
    child: GestureDetector(
      key: ValueKey('posehub-action-${action.id}'),
      onTap: () => widget.onOpenAction(action),
      child: DecoratedBox(
        key: ValueKey('posehub-card-surface-${action.id}'),
        decoration: BoxDecoration(
          color: theme.cardSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.cardBorder),
        ),
        child: ClipRRect(
          key: ValueKey('posehub-card-clip-${action.id}'),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  key: ValueKey('posehub-image-area-${action.id}'),
                  aspectRatio: 1,
                  child: widget.actionArtwork(context, action, theme),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: nameHeight,
                  child: Text(
                    widget.config?.displayText?.call(action.id)?.name ??
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
                  key: ValueKey('posehub-card-tags-${action.id}'),
                  height: tagHeight,
                  child: Text(
                    widget.config?.displayText?.call(action.id)?.metadata ??
                        '${PoseHubActionFacets.type(action)} · ${PoseHubActionFacets.equipmentText(action)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.label.copyWith(fontSize: 12, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  double _pillHeight(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(14) * 1.3 + 16).clamp(
        34,
        double.infinity,
      );

  /// 全部 + the body parts present in this library, then the fixed 筛选
  /// button. A host-supplied muscle filter leads the row as its own pill.
  Widget _quickRow(TrainerTheme theme, List<PoseHubPackAction> actions) {
    final present = actions.expand(PoseHubActionFacets.bodyParts).toSet();
    final parts = [
      for (final part in poseHubBodyParts)
        if (present.contains(part) || part == _filter.bodyPart) part,
    ];
    final muscle = _filter.muscle;
    final count = _filter.activeCount;
    return SizedBox(
      key: const ValueKey('posehub-quick-row'),
      height: _pillHeight(context),
      child: Row(
        children: [
          Expanded(
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                colors: [Colors.white, Colors.white, Colors.transparent],
                stops: [0, .92, 1],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ListView(
                key: const ValueKey('posehub-quick-options'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsetsDirectional.only(start: 16, end: 20),
                children: [
                  if (muscle != null) ...[
                    _pill(
                      theme,
                      key: const ValueKey('posehub-quick-muscle'),
                      label: poseHubMuscleLabels[muscle] ?? muscle,
                      selected: true,
                      trailing: Icons.close_rounded,
                      onTap: () => setState(
                        () => _filter = _filter.copyWith(clearMuscle: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  _pill(
                    theme,
                    key: const ValueKey('posehub-quick-全部'),
                    label: _strings.all,
                    selected: _filter.bodyPart == _all && muscle == null,
                    onTap: () => setState(
                      () => _filter = _filter.copyWith(
                        bodyPart: _all,
                        clearMuscle: true,
                      ),
                    ),
                  ),
                  for (final part in parts) ...[
                    const SizedBox(width: 8),
                    _pill(
                      theme,
                      key: ValueKey('posehub-quick-$part'),
                      label: part,
                      selected: _filter.bodyPart == part,
                      onTap: () => setState(
                        () => _filter = _filter.copyWith(
                          bodyPart: _filter.bodyPart == part ? _all : part,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 16),
            child: Semantics(
              button: true,
              label: count == 0
                  ? _strings.filter
                  : '${_strings.filter}, ${_strings.activeFiltersFor(count)}',
              excludeSemantics: true,
              child: _pill(
                theme,
                key: const ValueKey('posehub-filter-button'),
                label: _strings.filter,
                leading: Icons.tune_rounded,
                selected: count > 0,
                badge: count > 0 ? count : null,
                onTap: () => _openSheet(theme, actions),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(
    TrainerTheme theme, {
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? leading,
    IconData? trailing,
    int? badge,
  }) {
    final foreground = selected ? _selectedForeground(theme) : theme.text;
    final height = _pillHeight(context);
    return Material(
      key: key,
      color: selected ? _selectedBackground(theme) : theme.surface,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? theme.accent.withValues(alpha: .6) : theme.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                Icon(leading, size: 16, color: foreground),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                maxLines: 1,
                style: theme.label.copyWith(
                  fontSize: 14,
                  height: 1.2,
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                Icon(trailing, size: 14, color: foreground),
              ],
              if (badge != null) ...[
                const SizedBox(width: 6),
                Container(
                  key: const ValueKey('posehub-filter-badge'),
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: theme.accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$badge',
                    style: theme.label.copyWith(
                      fontSize: 11,
                      height: 1.5,
                      fontWeight: FontWeight.w700,
                      color: theme.onAccent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(
    TrainerTheme theme,
    List<PoseHubPackAction> actions,
  ) async {
    final picked = await showModalBottomSheet<TrainingLibraryFilter>(
      context: context,
      routeSettings: const RouteSettings(name: 'training_library_filter'),
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: theme.surface,
      sheetAnimationStyle: TrainingLibraryStyle.sheetAnimation,
      shape: TrainingLibraryStyle.sheetShape,
      showDragHandle: true,
      builder: (_) => _FilterSheet(
        initial: _filter,
        theme: theme,
        strings: _strings,
        actions: actions,
        categories: [
          ...?widget.config?.categoryOrder,
          if (widget.config == null) ...['力量', '拉伸放松'],
        ],
        equipmentLabel: _equipmentLabel,
        count: (filter) => _matching(actions, filter).length,
        selectedBackground: _selectedBackground(theme),
        selectedForeground: _selectedForeground(theme),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _filter = picked.copyWith(query: _filter.query));
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
            _strings.emptyTitle,
            style: theme.callout,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            _strings.emptyBody,
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
            child: Text(_strings.clearFilters),
          ),
        ],
      ),
    ),
  );
}

/// Every facet as wrapping chips over a draft selection; 重置 clears the
/// draft, 查看 N 个动作 returns it.
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initial,
    required this.theme,
    required this.strings,
    required this.actions,
    required this.categories,
    required this.equipmentLabel,
    required this.count,
    required this.selectedBackground,
    required this.selectedForeground,
  });
  final TrainingLibraryFilter initial;
  final TrainerTheme theme;
  final TrainingLibraryStrings strings;
  final List<PoseHubPackAction> actions;
  final List<String> categories;
  final String Function(String) equipmentLabel;
  final int Function(TrainingLibraryFilter) count;
  final Color selectedBackground, selectedForeground;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late TrainingLibraryFilter _draft = widget.initial;
  static const _all = TrainingLibraryFilter.all;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final strings = widget.strings;
    final actions = widget.actions;
    final equipment =
        actions.expand(PoseHubActionFacets.equipment).toSet().toList()..sort();
    final parts = actions.expand(PoseHubActionFacets.bodyParts).toSet();
    final levels =
        actions.map(PoseHubActionFacets.level).whereType<int>().toSet().toList()
          ..sort();
    final hasUnilateral = actions.any((a) => a.raw['unilateral'] == true);
    final hasBilateral = actions.any((a) => a.raw['unilateral'] != true);
    final present = actions.expand(PoseHubActionFacets.muscles).toSet();
    final muscleIds = [
      for (final id in poseHubMuscleLabels.keys)
        if (present.contains(id) || id == _draft.muscle) id,
    ];
    final sections = <Widget>[
      if (muscleIds.isNotEmpty)
        _section(strings.muscleGroup, 'muscle', [
          _chip(
            'muscle',
            _all,
            strings.all,
            _draft.muscle == null,
            () => setState(() => _draft = _draft.copyWith(clearMuscle: true)),
          ),
          for (final id in muscleIds)
            _chip(
              'muscle',
              id,
              poseHubMuscleLabels[id] ?? id,
              _draft.muscle == id,
              () => setState(
                () => _draft = _draft.muscle == id
                    ? _draft.copyWith(clearMuscle: true)
                    : _draft.copyWith(muscle: id),
              ),
            ),
        ]),
      _section(strings.bodyPart, strings.bodyPart, [
        for (final part in [
          _all,
          ...poseHubBodyParts.where(
            (p) => parts.contains(p) || p == _draft.bodyPart,
          ),
        ])
          _chip(
            strings.bodyPart,
            part,
            part == _all ? strings.all : part,
            _draft.bodyPart == part,
            () => setState(() => _draft = _draft.copyWith(bodyPart: part)),
          ),
      ]),
      _section(strings.equipment, strings.equipment, [
        for (final value in [_all, '徒手', '需要器械', ...equipment])
          _chip(
            strings.equipment,
            value,
            widget.equipmentLabel(value),
            _draft.equipment == value,
            () => setState(() => _draft = _draft.copyWith(equipment: value)),
          ),
      ]),
      _section(strings.category, strings.category, [
        for (final value in [_all, ...widget.categories])
          _chip(
            strings.category,
            value,
            value == _all ? strings.all : value,
            _draft.type == value,
            () => setState(() => _draft = _draft.copyWith(type: value)),
          ),
      ]),
      if (levels.length > 1)
        _section(strings.level, 'level', [
          _chip(
            'level',
            _all,
            strings.all,
            _draft.level == null,
            () => setState(() => _draft = _draft.copyWith(clearLevel: true)),
          ),
          for (final level in levels)
            _chip(
              'level',
              '$level',
              strings.levelLabel(level),
              _draft.level == level,
              () => setState(() => _draft = _draft.copyWith(level: level)),
            ),
        ]),
      if (hasUnilateral && hasBilateral)
        _section(strings.side, 'side', [
          for (final (side, label) in [
            (TrainingLibrarySide.any, strings.all),
            (TrainingLibrarySide.bilateral, strings.bilateral),
            (TrainingLibrarySide.unilateral, strings.unilateral),
          ])
            _chip(
              'side',
              side.name,
              label,
              _draft.side == side,
              () => setState(() => _draft = _draft.copyWith(side: side)),
            ),
        ]),
    ];
    final count = widget.count(_draft);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Column(
        key: const ValueKey('posehub-filter-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              strings.filter,
              style: TrainingLibraryStyle.detailTitle(theme),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('posehub-filter-sections'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: sections,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.border)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(
                  children: [
                    OutlinedButton(
                      key: const ValueKey('posehub-filter-reset'),
                      onPressed: _draft.activeCount == 0
                          ? null
                          : () => setState(() => _draft = _draft.cleared()),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.text,
                        side: BorderSide(color: theme.border),
                        minimumSize: const Size(88, 48),
                        shape: const StadiumBorder(),
                      ),
                      child: Text(strings.reset),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('posehub-filter-apply'),
                        onPressed: () => Navigator.of(context).pop(_draft),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.accent,
                          foregroundColor: theme.onAccent,
                          minimumSize: const Size.fromHeight(48),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(
                          strings.viewResultsFor(count),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String id, List<Widget> chips) => Padding(
    key: ValueKey('posehub-filter-section-$id'),
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: widget.theme.label.copyWith(
            color: widget.theme.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: chips),
      ],
    ),
  );

  Widget _chip(
    String group,
    String value,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    final theme = widget.theme;
    return ChoiceChip(
      key: ValueKey('posehub-$group-$value'),
      label: Text(label),
      selected: selected,
      showCheckmark: true,
      checkmarkColor: widget.selectedForeground,
      labelStyle: theme.label.copyWith(
        color: selected ? widget.selectedForeground : theme.text,
      ),
      selectedColor: widget.selectedBackground,
      backgroundColor: theme.surface,
      side: BorderSide(color: selected ? theme.accent : theme.border),
      onSelected: (_) => onTap(),
    );
  }
}
