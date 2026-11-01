part of 'structured_tool_handler.dart';

extension ActionToolHandler on StructuredToolHandler {
  /// Old virtual catalogue paths use exactly the same admission and seen
  /// accounting as the structured search tools, never their unfiltered text.
  StructuredToolResult readActions(
    CoachSessionState state,
    String path,
    String language,
  ) {
    beginTool(AgentTools.read);
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
    final next = found.ok ? _recordSearch(state, found) : state;
    return StructuredToolResult(
      next,
      jsonEncode({
        ...found.toJson(),
        'notes': [...found.notes, '已将旧目录路径路由到安全动作检索；只返回符合当前条件的动作。'],
      }),
      fresh: found.ok && _searchProgress(state, next),
    );
  }

  StructuredToolResult search(
    CoachSessionState state,
    String tool,
    String raw,
    String language,
  ) {
    final searchCall = tool == AgentTools.searchActions;
    beginTool(tool);
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
      _lastSearch = null;
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
    final signature = searchCall
        ? _searchSignature(state, args, language)
        : null;
    final cached = _lastSearch;
    if (signature != null &&
        cached != null &&
        cached.signature == signature &&
        identical(cached.task, state.task) &&
        state.seenActionIds.containsAll(cached.ids)) {
      final emptySearches = state.consecutiveEmptySearches + 1;
      var summary =
          '${cached.receipt['summary'] ?? ''}'
          '${language.toLowerCase().startsWith('en') ? ' Reused the same query in this tool batch; no new IDs.' : ' 已复用本批同条件检索，没有新增动作 ID。'}';
      if (emptySearches >= 2) {
        final count = ActionSearch(
          profile,
          catalog,
          minPicks: profile.minActions,
        ).candidateRows(state, language: language).length;
        final deliver = state.task?.type == 'plan'
            ? 'draft_plan'
            : 'show_actions';
        summary += language.toLowerCase().startsWith('en')
            ? ' The candidate pool already has $count ${count == 1 ? 'action' : 'actions'}; choose from candidates and call $deliver.'
            : '候选池已有 $count 个，请从 candidates 中选择并调用 $deliver。';
      }
      return StructuredToolResult(
        state.copyWith(consecutiveEmptySearches: emptySearches),
        jsonEncode({
          ...cached.receipt,
          'items': [
            for (final raw in cached.receipt['items']! as List<Object?>)
              {
                for (final key in const ['id', 'doseMode', 'level'])
                  key: (raw! as Map<String, Object?>)[key],
              },
          ],
          'cacheHit': true,
          'newCount': 0,
          'notes': [
            ...notes,
            if (cached.receipt['notes'] case final List<Object?> values)
              ...values,
            '同一任务和条件下的连续相同检索已复用首次真实回执，仅返回已见 ID。',
          ],
          'summary': summary,
        }),
      );
    }
    _lastSearch = null;
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
    final next = found.ok && searchCall ? _recordSearch(state, found) : state;
    final newCount = found.items
        .where((item) => !state.seenActionIds.contains(item['id']))
        .length;
    if (found.ok && signature != null) {
      _lastSearch = _SearchReuse(
        task: state.task,
        signature: signature,
        receipt: found.toJson(),
        ids: found.items.map((item) => item['id']! as String),
      );
    }
    return StructuredToolResult(
      next,
      jsonEncode({
        ...found.toJson(),
        if (found.ok && searchCall) ...{
          'cacheHit': false,
          'newCount': newCount,
        },
        if (notes.isNotEmpty || found.notes.isNotEmpty)
          'notes': [...notes, ...found.notes],
      }),
      fresh: found.ok && searchCall && _searchProgress(state, next),
      accessed: found.ok && !searchCall
          ? (args['ids'] as List).cast<String>()
          : const [],
    );
  }

  String? _searchSignature(
    CoachSessionState state,
    Map<String, Object?> args,
    String language,
  ) {
    try {
      return jsonEncode({
        'turn': state.userTurns.lastOrNull?.turn,
        'params': {
          for (final entry in state.params.entries)
            entry.key: entry.value.toJson(),
        },
        'hostValues': state.hostValues,
        'activePlanId': state.activePlanId,
        'focusPlanId': state.focusPlanId,
        'actionScopeIdentity': state.actionScopeIdentity,
        'scopeAssessmentTurn': state.scopeAssessmentTurn,
        'scopeDecisionRecords': state.scopeDecisionRecords,
        'language': language,
        'query': {
          'tags': args['tags'],
          'keywords': args['keywords'] ?? '',
          'limit': args['limit'],
        },
      });
    } on JsonUnsupportedObjectError {
      // Opaque host metadata can disable an optimization, never the original
      // catalogue search or any admission/safety validation.
      return null;
    }
  }

  CoachSessionState _recordSearch(
    CoachSessionState before,
    ActionSearchResult found,
  ) {
    final turn = before.userTurns.lastOrNull?.turn ?? 0;
    return found.state.copyWith(
      pendingSearchTurn: turn,
      pendingSearchIds: {
        if (before.pendingSearchTurn == turn) ...before.pendingSearchIds,
        for (final item in found.items) item['id']! as String,
      },
    );
  }

  bool _searchProgress(CoachSessionState before, CoachSessionState after) =>
      after.seenActionIds.length > before.seenActionIds.length ||
      after.pendingSearchIds.isNotEmpty &&
          (after.pendingSearchTurn != before.pendingSearchTurn ||
              after.pendingSearchIds
                  .difference(before.pendingSearchIds)
                  .isNotEmpty);
}
