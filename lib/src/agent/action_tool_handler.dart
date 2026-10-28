part of 'structured_tool_handler.dart';

extension ActionToolHandler on StructuredToolHandler {
  /// Old virtual catalogue paths use exactly the same admission and seen
  /// accounting as the structured search tools, never their unfiltered text.
  StructuredToolResult readActions(
    CoachSessionState state,
    String path,
    String language,
  ) {
    if (path.startsWith('${SkillFiles.actionLibrary}/details/') &&
        path.endsWith('.md')) {
      final id = path.substring(
        '${SkillFiles.actionLibrary}/details/'.length,
        path.length - 3,
      );
      final result = search(
        state,
        AgentTools.getAction,
        jsonEncode({
          'ids': [id],
        }),
        language,
      );
      final receipt = jsonDecode(result.response) as Map;
      return StructuredToolResult(
        result.state,
        jsonEncode({
          ...receipt,
          'notes': [
            if (receipt['notes'] is List) ...receipt['notes'] as List,
            '已将旧动作详情路径路由到 get_action，当前资格限制保持生效。',
          ],
        }),
        fresh: result.fresh,
        accessed: result.accessed,
      );
    }
    Set<String>? restricted;
    final parts = path.split('/');
    if (parts.length == 4 &&
        parts[1] == 'index' &&
        parts.last.endsWith('.md')) {
      final dimension = SkillFiles.dimensions(
        catalog,
      ).where((d) => d.id == parts[2]).firstOrNull;
      final value = parts.last.substring(0, parts.last.length - 3);
      if (dimension != null) {
        restricted = {
          for (final drill in profile.scope(catalog))
            if (dimension.valuesOf(drill).contains(value)) drill.id,
        };
      }
    }
    final found = ActionSearch(
      profile,
      catalog,
      minPicks: profile.minActions,
    ).search(state, restrictedIds: restricted, language: language);
    return StructuredToolResult(
      found.state,
      jsonEncode({
        ...found.toJson(),
        'notes': [...found.notes, '已将旧目录路径路由到安全动作检索；只返回符合当前条件的动作。'],
      }),
      fresh: found.state.seenActionIds.length > state.seenActionIds.length,
    );
  }

  StructuredToolResult search(
    CoachSessionState state,
    String tool,
    String raw,
    String language,
  ) {
    final searchCall = tool == AgentTools.searchActions;
    final keys = searchCall ? {'tags', 'keywords', 'limit'} : {'ids'};
    final listKey = searchCall ? 'tags' : 'ids';
    final normalized = normalizeToolArguments(
      raw,
      allowed: keys,
      lists: {listKey},
    );
    final args = normalized.value;
    final notes = [...normalized.notes];
    if (args != null && searchCall) {
      final suppliedLimit = args['limit'];
      final limit = suppliedLimit is num && suppliedLimit.isFinite
          ? suppliedLimit.toInt()
          : suppliedLimit is String
          ? int.tryParse(suppliedLimit)
          : null;
      args['limit'] = limit ?? 20;
      if (suppliedLimit != null && suppliedLimit != args['limit']) {
        notes.add('limit 已规范化为整数。');
      }
    }
    if (args == null ||
        args[listKey] is! List ||
        (args[listKey] as List).any((value) => value is! String) ||
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
      jsonEncode({
        ...found.toJson(),
        if (notes.isNotEmpty || found.notes.isNotEmpty)
          'notes': [...notes, ...found.notes],
      }),
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
