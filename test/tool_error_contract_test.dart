import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/skill_tool_handler.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/src/agent/terminal_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _json(String value) =>
    (jsonDecode(value) as Map).cast<String, Object?>();

void _contract(Map<String, Object?> value, {required String origin}) {
  expect(
    value.keys,
    containsAll(['ok', 'code', 'field', 'expected', 'actual', 'fix']),
    reason: origin,
  );
  expect(value['ok'], isFalse, reason: origin);
  for (final field in ['code', 'field', 'fix']) {
    expect(value[field], isA<String>(), reason: '$origin $field');
    expect(
      (value[field] as String).trim(),
      isNotEmpty,
      reason: '$origin $field',
    );
  }
  final fix = value['fix'] as String;
  for (final forbidden in [
    '见 message',
    '按期望改正',
    '按 expected 重交',
    '见 expected',
    '按上述修正',
  ]) {
    expect(fix, isNot(contains(forbidden)), reason: '$origin: $fix');
  }
  if (value['errors'] case final List<Object?> errors) {
    for (final error in errors.whereType<Map<Object?, Object?>>()) {
      _contract(error.cast<String, Object?>(), origin: '$origin nested');
    }
  }
}

LlmResponse _tool(String operation, Object parameters) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'memory-test',
      name: operation,
      arguments: jsonEncode(parameters),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);

class _FailingMemoryStore implements UserMemoryStore {
  @override
  Future<List<MemoryEntry>> load() async => [];

  @override
  Future<void> save(List<MemoryEntry> entries) async =>
      throw StateError('unavailable');
}

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final skills = SkillFiles.build(profile, catalog, memory: true);
  final structured = StructuredToolHandler(
    profile,
    catalog,
    newPlanId: () => 'test-plan',
    files: skills,
  );

  test(
    'Agent and tool error construction has no circular repair placeholders',
    () {
      for (final dir in ['lib/src/agent', 'lib/src/tools']) {
        for (final file
            in Directory(dir)
                .listSync(recursive: true)
                .whereType<File>()
                .where((f) => f.path.endsWith('.dart'))) {
          final source = file.readAsStringSync();
          for (final forbidden in ['见 message', '按期望改正']) {
            expect(
              source,
              isNot(contains(forbidden)),
              reason: '${file.path}: $forbidden',
            );
          }
        }
      }
    },
  );

  test(
    'structured task params search draft and checker errors share the contract',
    () {
      final state = CoachSessionState(
        userTurns: [const CoachUserTurn(turn: 1, text: '在家徒手20分钟')],
      );
      final samples = <String, String>{
        'start schema': structured
            .task(state, AgentTools.startTask, '{}', 'zh')
            .response,
        'check node': structured
            .task(state, AgentTools.check, '{"node":"actions"}', 'zh')
            .response,
        'params schema': structured
            .setParams(
              state,
              {
                'fields': {
                  'scene': {
                    'value': 'outdoor',
                    'source': 'user',
                    'quote': '在家',
                  },
                },
              },
              'zh',
              [],
            )
            .response,
        'params source': structured
            .setParams(
              state,
              {
                'fields': {
                  'minutes': {'value': 20, 'source': 'host'},
                },
              },
              'zh',
              [],
            )
            .response,
        'search schema': structured
            .search(state, AgentTools.searchActions, '{"tags":17}', 'zh')
            .response,
        'search tag': structured
            .search(
              state,
              AgentTools.searchActions,
              '{"tags":["invented.tag"]}',
              'zh',
            )
            .response,
        'search limit': structured
            .search(
              state,
              AgentTools.searchActions,
              '{"tags":[],"limit":21}',
              'zh',
            )
            .response,
        'details': structured
            .search(
              state,
              AgentTools.getAction,
              '{"ids":["missing-action"]}',
              'zh',
            )
            .response,
        'draft malformed': structured.draft(state, '[1]', 'zh').response,
        'draft no task': structured
            .draft(state, '{"title":"计划","blocks":[]}', 'zh')
            .response,
        'check plan schema': structured.checkPlan(state, '{}').response,
        'check missing plan': structured
            .checkPlan(state, '{"plan_id":"missing"}')
            .response,
      };
      for (final sample in samples.entries) {
        _contract(_json(sample.value), origin: sample.key);
      }
    },
  );

  test(
    'ask payload and batch-position failures expose concrete repair fields',
    () {
      final terminal = TerminalToolHandler(
        ToolGate(catalog: catalog, profile: profile),
      );
      for (final raw in [
        'not json',
        '{}',
        '{"question":"练什么？","mode":"choice","options":["一个"]}',
      ]) {
        final result = terminal.ask(raw, 1, 1);
        expect(result.rejected, isTrue);
        _contract(_json(result.response), origin: 'ask $raw');
      }
      _contract(
        _json(terminal.ask('{"question":"练什么？","mode":"text"}', 1, 2).response),
        origin: 'ask position',
      );
    },
  );

  test('unknown and prohibited skill reads return the same error contract', () {
    final handler = SkillToolHandler(skills, {}, [], {});
    for (final path in [
      'missing/SKILL.md',
      'action-library/index/scene/home.md',
    ]) {
      final result = handler.execute(
        'read-error',
        path,
        read: true,
        hasTask: true,
      );
      expect(result.failed, isTrue);
      _contract(_json(result.response), origin: 'read $path');
    }
  });

  test('card output failures and legacy gate feedback keep the contract', () {
    final gate = ToolGate(catalog: catalog, profile: profile);
    final terminal = TerminalToolHandler(gate);
    final result = terminal.show(
      CoachSessionState(),
      AgentTools.showPlan,
      '{"plan_id":"missing","note":"说明"}',
      language: 'zh',
    );
    expect(result.rejected, isTrue);
    _contract(_json(result.response), origin: 'show before nodes');
    final legacy = gate.check('', [
      const LlmToolCall(id: 'unknown', name: 'unknown', arguments: '{}'),
    ]);
    expect(legacy.ok, isFalse);
    _contract(_json(legacy.feedback()), origin: 'legacy gate');
  });

  for (final operation in ['remember', 'forget']) {
    for (final invalid in [true, false]) {
      test(
        '$operation ${invalid ? 'invalid argument' : 'failed save'} has a repair contract',
        () async {
          final client = FakeLlmClient([
            _tool(
              operation,
              invalid
                  ? <String, Object?>{}
                  : {'kind': 'goal', 'text': '想改善灵活性'},
            ),
            (LlmRequest request) {
              final feedback = request.messages.singleWhere(
                (m) => m.toolCallId == 'memory-test',
              );
              final data = _json(feedback.content);
              _contract(data, origin: '$operation memory');
              expect(
                data['code'],
                invalid ? 'invalid_memory' : 'memory_save_failed',
              );
              return '这次没有保存成功。';
            },
          ], latency: Duration.zero);
          final agent = CoachAgent(
            client: client,
            catalog: () => catalog,
            profile: profile,
            memoryStore: _FailingMemoryStore(),
            maxRequestRetries: 0,
          );
          addTearDown(agent.dispose);
          final result = await agent.send('记住我想改善灵活性');
          expect(
            result.status,
            TurnStatus.ok,
            reason: '${result.error}; ${result.issues}',
          );
          expect(client.requests, hasLength(2));
        },
      );
    }
  }

  test(
    'kernel and task skills have no old preload fast paths or thinking and response length caps',
    () {
      for (final path in [
        'prompts/agent_kernel.md',
        'skills/ask/SKILL.md',
        'skills/action-library/SKILL.md',
        'skills/plan-training/SKILL.md',
      ]) {
        final source = File(path).readAsStringSync();
        for (final forbidden in [
          'fastPaths',
          'compactIndex',
          'action-index-data',
          'action-details-data',
          '预加载动作目录',
          '预注入目录',
          '本轮已预载动作详情',
          '动作目录已内联',
          '最多一轮追问',
          '最多追问一轮',
          '不要思考',
          '禁止思考',
          '思考不超过',
          '最多思考',
          '限制思考',
          '回答不超过',
          '回答最多',
          '限制回答长度',
        ]) {
          expect(
            source,
            isNot(contains(forbidden)),
            reason: '$path: $forbidden',
          );
        }
      }
    },
  );
}
