part of 'structured_tool_handler.dart';

extension ActionToolHandler on StructuredToolHandler {
  StructuredToolResult search(
    CoachSessionState state,
    String tool,
    String raw,
    String language,
  ) {
    final args = _decode(raw);
    final searchCall = tool == AgentTools.searchActions;
    final keys = searchCall ? {'tags', 'keywords', 'limit'} : {'ids'};
    final listKey = searchCall ? 'tags' : 'ids';
    if (args is! Map ||
        args.keys.any((key) => key is! String || !keys.contains(key)) ||
        args[listKey] is! List ||
        (args[listKey] as List).any((value) => value is! String) ||
        (args[listKey] as List).toSet().length !=
            (args[listKey] as List).length ||
        (searchCall &&
            args['keywords'] != null &&
            args['keywords'] is! String) ||
        (searchCall && args['limit'] != null && args['limit'] is! int)) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'arguments',
            searchCall
                ? '{tags: string[], keywords?: string, limit?: 1–20}'
                : '{ids: 1–10 unique strings}',
            args,
            '使用工具 schema 中的字段和值。',
          ),
        ),
      );
    }
    final service = ActionSearch(
      profile,
      catalog,
      minPicks: profile.minActions,
    );
    final found = searchCall
        ? service.search(
            state,
            tags: (args['tags'] as List).cast<String>(),
            keywords: args['keywords'] as String? ?? '',
            limit: args['limit'] as int? ?? 20,
            language: language,
          )
        : service.getActions(
            state,
            (args['ids'] as List).cast<String>(),
            language: language,
          );
    return StructuredToolResult(
      found.ok && searchCall ? found.state : state,
      jsonEncode(found.toJson()),
      fresh:
          found.ok &&
          searchCall &&
          found.state.seenActionIds.length > state.seenActionIds.length,
      accessed: found.ok && !searchCall
          ? (args['ids'] as List).cast<String>()
          : const [],
    );
  }
}
