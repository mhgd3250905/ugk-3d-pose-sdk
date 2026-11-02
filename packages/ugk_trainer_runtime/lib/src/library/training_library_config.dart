import 'package:ugk_coach/ugk_coach.dart';

/// One product's action library. The manifest is also the Coach scope source;
/// there is no second UI-only list of allowed IDs.
class TrainingLibraryConfig {
  const TrainingLibraryConfig({
    required this.scopeManifest,
    this.categoryOrder = const ['力量', '拉伸放松'],
    this.brand = '',
    this.strings = const TrainingLibraryStrings(),
    this.showStartAction = false,
  });

  final CoachActionScopeManifest scopeManifest;
  final List<String> categoryOrder;
  final String brand;
  final TrainingLibraryStrings strings;

  /// SF's action detail has no start button. Hosts can explicitly add one
  /// while retaining their own authored plan, safety and persistence callback.
  final bool showStartAction;
  Set<String> get allowedActionIds => scopeManifest.allowedActionIds;

  /// The library is a catalogue exposure boundary, like Coach tool exposure.
  Iterable<PoseHubPackAction> actions(PoseHubAppTestCatalog catalog) =>
      catalog.semanticCompleteActions.where(
        (action) =>
            allowedActionIds.contains(action.id) && action.availableForApp,
      );
}

class TrainingLibraryStrings {
  const TrainingLibraryStrings({
    this.title = '动作库',
    this.searchHint = '搜索动作',
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
  });
  final String title,
      searchHint,
      all,
      allActions,
      equipment,
      bodyPart,
      category;
  final String clear, emptyTitle, emptyBody, clearFilters, play, pause, start;
  final String unavailable, muscles, cues, cautions, cautionSuffix;
}
