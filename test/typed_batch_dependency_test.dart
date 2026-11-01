import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/batch_handler.dart';
import 'package:ugk_coach/src/agent/tool_arguments.dart';
import 'package:ugk_coach/src/llm/llm_types.dart';

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

void main() {
  final start = _call('start', 'start_task', {'type': 'plan'});
  final parameters = _call('params', 'set_params', {
    'fields': {
      'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
    },
  });
  final search = _call('search', 'search_actions', {
    'tags': ['purpose.stretch'],
    'limit': 20,
  });
  final draft = _call('draft', 'draft_plan', {
    'blocks': [
      {
        'kind': 'main',
        'items': [
          {'id': 's-butterfly'},
        ],
      },
    ],
  });
  final show = _call('show', 'show_plan', {'plan_id': 'sdk-managed'});
  List<String> ids(Iterable<LlmToolCall> values) =>
      values.map((call) => call.id).toList();

  test('typed chain is start, parameters, original searches, then draft', () {
    final original = [draft, search, parameters, start];
    final ordered = ToolBatch.orderedCalls(original);
    expect(ids(ordered), ['start', 'params', 'search', 'draft']);
    expect(ids(original), ['draft', 'search', 'params', 'start']);
    expect(
      {for (final call in ordered) call.id: call.arguments},
      {for (final call in original) call.id: call.arguments},
      reason: 'normalization cannot rewrite IDs, user quotes or query data',
    );
  });

  test('search/get queries keep their order and limits', () {
    final second = _call('search-two', 'search_actions', {
      'tags': ['body.hip_flexors'],
      'limit': 3,
    });
    final detail = _call('detail', 'get_action', {
      'ids': ['s-butterfly'],
    });
    final ordered = ToolBatch.orderedCalls([
      draft,
      search,
      detail,
      parameters,
      second,
      start,
    ]);
    expect(ids(ordered), [
      'start',
      'params',
      'search',
      'detail',
      'search-two',
      'draft',
    ]);
    expect(jsonDecode(ordered[2].arguments), jsonDecode(search.arguments));
    expect(jsonDecode(ordered[4].arguments), jsonDecode(second.arguments));
  });

  for (final barrier in ['read', 'check', 'remember', 'unknown_tool']) {
    test('$barrier is a dependency barrier', () {
      final boundary = _call('boundary', barrier, {'node': 'parameters'});
      expect(
        ids(ToolBatch.orderedCalls([parameters, boundary, search, start])),
        ['params', 'boundary', 'start', 'search'],
      );
    });
  }

  for (final repeated in ['start_task', 'set_params', 'draft_plan']) {
    test('multiple $repeated writes retain the explicit sequence', () {
      final first = switch (repeated) {
        'start_task' => start,
        'set_params' => parameters,
        _ => draft,
      };
      final second = LlmToolCall(
        id: 'second',
        name: first.name,
        arguments: first.arguments,
      );
      final original = [draft, first, search, second, parameters, start];
      expect(ids(ToolBatch.orderedCalls(original)), ids(original));
    });
  }

  test('malformed typed arguments cannot be moved across a valid call', () {
    final malformed = LlmToolCall(
      id: 'bad',
      name: 'start_task',
      arguments: '{not-json',
    );
    expect(
      ids(ToolBatch.orderedCalls([search, malformed, parameters, start])),
      ['search', 'bad', 'start', 'params'],
    );
    final unknownType = _call('bad-type', 'start_task', {'type': 'arbitrary'});
    expect(
      ids(ToolBatch.orderedCalls([search, unknownType, parameters, start])),
      ['search', 'bad-type', 'start', 'params'],
    );
  });

  test(
    'scope assessment is ordered as set_params without changing its data',
    () {
      final scope = _call('scope', 'set_params', {
        'scope_request': {'kind': 'partial', 'sourceQuote': '用户原话'},
      });
      final ordered = ToolBatch.orderedCalls([search, scope, start]);
      expect(ids(ordered), ['start', 'scope', 'search']);
      expect(ordered[1].arguments, scope.arguments);
      final malformed = _call('bad-scope', 'set_params', {
        'fields': <String, Object?>{},
        'scope_request': ['not-an-object'],
      });
      expect(ids(ToolBatch.orderedCalls([search, malformed, start])), [
        'search',
        'bad-scope',
        'start',
      ]);
    },
  );

  test('normalizer preserves response metadata and orders terminal last', () {
    const usage = TokenUsage(promptTokens: 11, completionTokens: 7);
    final original = LlmResponse(
      content: 'public text',
      reasoning: 'opaque private protocol field',
      model: 'same-model',
      usage: usage,
      latency: const Duration(milliseconds: 17),
      httpAttempts: 2,
      finishReason: 'tool_calls',
      toolCalls: [draft, parameters, start, search, show],
    );
    final normalized = normalizeToolBatch(original);
    expect(ids(normalized.response.toolCalls), [
      'start',
      'params',
      'search',
      'draft',
      'show',
    ]);
    expect(normalized.response.content, original.content);
    expect(normalized.response.reasoning, original.reasoning);
    expect(normalized.response.usage, same(usage));
    expect(normalized.response.latency, original.latency);
    expect(normalized.response.httpAttempts, 2);
    expect(normalized.response.model, original.model);
    expect(normalized.response.finishReason, original.finishReason);
    expect(normalized.notes, isNotEmpty);
    expect(normalized.response.toolCalls, hasLength(original.toolCalls.length));
  });

  test('canonical ordering is an identity operation without receipt noise', () {
    final original = LlmResponse(
      content: '',
      toolCalls: [start, parameters, search, draft, show],
    );
    final result = normalizeToolBatch(original);
    expect(result.response, same(original));
    expect(result.notes, isEmpty);
  });

  test('the first card remains a completion fence for trailing mutations', () {
    final trailing = _call('after-show', 'set_params', {
      'fields': {
        'level': {'value': 2, 'source': 'user', 'quote': '进阶'},
      },
    });
    final original = LlmResponse(
      content: '',
      toolCalls: [parameters, start, search, draft, show, trailing],
    );
    final normalized = normalizeToolBatch(original);
    expect(ids(normalized.response.toolCalls), [
      'start',
      'params',
      'search',
      'draft',
      'show',
      'after-show',
    ]);
    expect(normalized.response.toolCalls.last.arguments, trailing.arguments);
  });

  test('duplicate tool IDs remain one-to-one after stable typed ordering', () {
    final duplicate = _call('start', 'set_params', {
      'fields': <String, Object?>{},
    });
    final normalized = normalizeToolBatch(
      LlmResponse(content: '', toolCalls: [duplicate, start, search]),
    );
    expect(normalized.response.toolCalls, hasLength(3));
    final values = normalized.response.toolCalls;
    expect(values.map((call) => call.id).toSet(), hasLength(3));
    expect(values[0].name, 'start_task');
    expect(values[1].name, 'set_params');
    expect(values[2].name, 'search_actions');
    expect(values[1].arguments, duplicate.arguments);
  });

  test(
    'failure still blocks each later call and leaves matched error receipts',
    () {
      final batch = ToolBatch();
      batch.results['params'] = jsonEncode({
        'ok': false,
        'code': 'quote_not_found',
      });
      batch.mark(2, 'params');
      expect(batch.firstFailure, 2);
      batch.skipped('search');
      batch.skipped('draft');
      expect(
        (jsonDecode(batch.results['search']!) as Map<String, Object?>)['code'],
        'skipped_after_error',
      );
      expect(
        (jsonDecode(batch.results['draft']!) as Map<String, Object?>)['code'],
        'skipped_after_error',
      );
      expect(batch.results.keys, ['params', 'search', 'draft']);
    },
  );
}
