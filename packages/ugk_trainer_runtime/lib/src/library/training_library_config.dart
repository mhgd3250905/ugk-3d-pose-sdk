import 'package:ugk_coach/ugk_coach.dart';
import 'training_library_strings_i18n.dart';

/// One product's action library. The manifest is also the Coach scope source;
/// there is no second UI-only list of allowed IDs.
class TrainingLibraryConfig {
  const TrainingLibraryConfig({
    required this.scopeManifest,
    this.categoryOrder = const ['力量', '拉伸放松'],
    this.brand = '',
    this.strings = const TrainingLibraryStrings(),
    this.showStartAction = false,
    this.searchNames,
    this.displayText,
  });

  final CoachActionScopeManifest scopeManifest;
  final List<String> categoryOrder;
  final String brand;
  final TrainingLibraryStrings strings;

  /// SF's action detail has no start button. Hosts can explicitly add one
  /// while retaining their own authored plan, safety and persistence callback.
  final bool showStartAction;

  /// Extra names the search box matches for one action (for example the
  /// host's localized or English names). The catalogue's Chinese name,
  /// aliases, any English name fields and the action id always match.
  final Iterable<String> Function(String actionId)? searchNames;

  /// Optional host-authored display copy. Null retains the catalogue's current
  /// presentation, including Chinese defaults. It never changes action IDs,
  /// catalogue semantics, filtering, media integrity or training execution.
  final TrainingLibraryActionText? Function(String actionId)? displayText;
  Set<String> get allowedActionIds => scopeManifest.allowedActionIds;

  /// The library is a catalogue exposure boundary, like Coach tool exposure.
  Iterable<PoseHubPackAction> actions(PoseHubAppTestCatalog catalog) =>
      catalog.semanticCompleteActions.where(
        (action) =>
            allowedActionIds.contains(action.id) && action.availableForApp,
      );
}

/// A presentation-only localized view of one catalogue action. Each null field
/// retains the corresponding catalogue text; an empty list intentionally
/// supplies no rows. Hosts remain responsible for the accuracy of translated
/// instructions and safety copy.
class TrainingLibraryActionText {
  const TrainingLibraryActionText({
    this.name,
    this.metadata,
    this.muscles,
    this.cues,
    this.cautions,
  });
  final String? name;
  final String? metadata;
  final String? muscles;
  final List<String>? cues;
  final List<String>? cautions;
}

class TrainingLibraryStrings {
  const TrainingLibraryStrings({
    this.title = '动作库',
    this.searchHint = '搜动作，中文或英文都行',
    this.all = '全部',
    this.allActions = '全部动作',
    this.equipment = '器械',
    this.bodyPart = '部位',
    this.category = '类型',
    this.clear = '清除',
    this.emptyTitle = '没有符合条件的动作',
    this.emptyBody = '试试其他关键词，或清除筛选',
    this.clearFilters = '清除筛选',
    this.play = '播放示范',
    this.pause = '暂停示范',
    this.start = '开始练习',
    this.unavailable = '此动作暂无公共示范',
    this.muscles = '练到',
    this.cues = '要领',
    this.cautions = '注意',
    this.cautionSuffix = '不适时减小幅度或换动作',
    this.filter = '筛选',
    this.reset = '重置',
    this.viewResults = '查看 {count} 个动作',
    this.activeFilters = '已选 {count} 项筛选',
    this.level = '难度',
    this.side = '单侧/双侧',
    this.bilateral = '双侧',
    this.unilateral = '单侧',
    this.levelBeginner = '入门',
    this.levelBasic = '基础',
    this.levelAdvanced = '进阶',
    this.muscleGroup = '肌群',
  });

  /// Shared library copy for one of the 14 product languages (`zh`,
  /// `zh-Hant`, `en`, `ja`, `ko`, `de`, `fr`, `es`, `it`, `pt`, `ru`, `ar`,
  /// `hi`, `id`). Unknown tags fall back to Simplified Chinese. Facet values
  /// from the catalogue (body parts, equipment names) stay as the catalogue
  /// labels them.
  factory TrainingLibraryStrings.forLanguage(String languageTag) {
    final tag = languageTag.replaceAll('_', '-').toLowerCase();
    final traditional =
        tag.startsWith('zh') &&
        (tag.contains('hant') ||
            tag.endsWith('-tw') ||
            tag.endsWith('-hk') ||
            tag.endsWith('-mo'));
    if (traditional) return trainingLibraryStringsByLanguage['zh-Hant']!;
    return trainingLibraryStringsByLanguage[tag.split('-').first] ??
        const TrainingLibraryStrings();
  }

  final String title,
      searchHint,
      all,
      allActions,
      equipment,
      bodyPart,
      category;
  final String clear, emptyTitle, emptyBody, clearFilters, play, pause, start;
  final String unavailable, muscles, cues, cautions, cautionSuffix;

  /// Filter button and sheet title.
  final String filter;

  /// Sheet action that clears every facet (the search text stays).
  final String reset;

  /// Sheet confirm button; `{count}` is replaced with the result count.
  final String viewResults;

  /// Filter badge semantics; `{count}` is replaced with the facet count.
  final String activeFilters;
  final String level, side, bilateral, unilateral;
  final String levelBeginner, levelBasic, levelAdvanced, muscleGroup;

  String viewResultsFor(int count) =>
      viewResults.replaceAll('{count}', '$count');
  String activeFiltersFor(int count) =>
      activeFilters.replaceAll('{count}', '$count');
  String levelLabel(int level) => switch (level) {
    1 => levelBeginner,
    2 => levelBasic,
    _ => levelAdvanced,
  };
}
