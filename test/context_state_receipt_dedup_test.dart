import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/src/agent/skill_disclosure.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const compactor = ContextCompactor();
  final catalog = loadCatalog();
  CoachTaskState task(String status) => CoachTaskState(
    type: 'recommend',
    reused: false,
    nodes: [
      const CoachNodeState(
        id: 'understand',
        status: 'done',
        stamp: '已理解',
        doneAtTurn: 1,
      ),
      CoachNodeState(
        id: 'parameters',
        status: status,
        stamp: status == 'done' ? '10 分钟（你说的）' : null,
        doneAtTurn: status == 'done' ? 1 : null,
      ),
      CoachNodeState(
        id: 'actions',
        status: status == 'done' ? 'current' : 'pending',
      ),
      const CoachNodeState(id: 'output', status: 'pending'),
    ],
  );
  final current = CoachSessionState(
    task: task('done'),
    params: {
      'minutes': CoachParamValue(
        value: 10,
        source: 'user',
        quote: '10 分钟',
        turn: 1,
      ),
    },
  );
  LlmToolCall call(String id, String name) =>
      LlmToolCall(id: id, name: name, arguments: '{}');
  LlmMessage receipt(String id, Object value) =>
      LlmMessage.tool(id, jsonEncode(value));
  Map<String, dynamic> body(List<LlmMessage> messages, String id) =>
      jsonDecode(
            messages.singleWhere((message) => message.toolCallId == id).content,
          )
          as Map<String, dynamic>;
  List<LlmMessage> compose(List<LlmMessage> history) => compactor.compose(
    system: const LlmMessage.system('角色'),
    state: current,
    catalog: catalog,
    history: history,
  );
  Map<String, Object?> restoredTask(List<LlmMessage> messages) {
    final summary =
        jsonDecode(messages[1].content.substring('当前状态：'.length)) as Map;
    final task = summary['task'] as List;
    return {
      'type': task[0],
      'reused': task[1],
      'nodes': [
        for (final row in task[2] as List)
          {
            'id': (row as List)[0],
            'status': row[1],
            'stamp': row[2],
            'doneAtTurn': row[3],
          },
      ],
    };
  }

  test(
    'unconsumed first receipts retain their full task and parameter dictionaries',
    () {
      final original = [
        LlmMessage.assistant(
          '',
          toolCalls: [call('task', 'check'), call('params', 'set_params')],
        ),
        receipt('task', {'ok': true, 'task': current.task!.toJson()}),
        receipt('params', {
          'ok': true,
          'params': {
            for (final entry in current.params.entries)
              entry.key: entry.value.toJson(),
          },
        }),
      ];
      final composed = compose(original);
      expect(body(composed, 'task'), body(original, 'task'));
      expect(body(composed, 'params'), body(original, 'params'));
    },
  );

  test(
    'consumed matching receipts reference fully reconstructable current state',
    () {
      final params = {
        for (final entry in current.params.entries)
          entry.key: entry.value.toJson(),
      };
      final original = [
        LlmMessage.assistant(
          '',
          reasoning: '思考保留',
          toolCalls: [call('task', 'check'), call('params', 'set_params')],
        ),
        receipt('task', {'ok': true, 'task': current.task!.toJson()}),
        receipt('params', {'ok': true, 'params': params}),
        LlmMessage.assistant('继续。'),
      ];
      final before = jsonEncode(
        original.map((message) => message.toJson()).toList(),
      );
      final composed = compose(original);
      expect(body(composed, 'task')['task'], {'sameAsCurrentState': 'task'});
      expect(restoredTask(composed), current.task!.toJson());
      expect(body(composed, 'params')['params'], {
        'sameAsCurrentState': 'params',
      });
      final summary =
          jsonDecode(composed[1].content.substring('当前状态：'.length)) as Map;
      expect(summary['params'], params);
      expect(
        composed
            .where((message) => message.role == LlmRole.assistant)
            .first
            .reasoning,
        '思考保留',
      );
      expect(
        jsonEncode(original.map((message) => message.toJson()).toList()),
        before,
      );
    },
  );

  test(
    'changed older values stay full; duplicate old check task points to first full receipt',
    () {
      final oldTask = task('current').toJson();
      final oldParams = {
        'minutes': CoachParamValue(
          value: 15,
          source: 'user',
          quote: '15 分钟',
          turn: 0,
        ).toJson(),
      };
      final original = [
        LlmMessage.assistant(
          '',
          toolCalls: [
            call('start', 'start_task'),
            call('old-params', 'set_params'),
          ],
        ),
        receipt('start', {'ok': true, 'task': oldTask}),
        receipt('old-params', {'ok': true, 'params': oldParams}),
        LlmMessage.assistant('', toolCalls: [call('repeat-check', 'check')]),
        receipt('repeat-check', {'ok': true, 'task': oldTask}),
        LlmMessage.assistant('继续。'),
      ];
      final composed = compose(original);
      expect(body(composed, 'start')['task'], oldTask);
      expect(body(composed, 'old-params')['params'], oldParams);
      expect(body(composed, 'repeat-check')['task'], {
        'sameAsToolCall': 'start',
        'field': 'task',
      });
      expect(
        body(composed, 'start')['task'],
        body(original, 'repeat-check')['task'],
      );
      expect(
        composed.indexWhere((message) => message.toolCallId == 'start'),
        lessThan(
          composed.indexWhere(
            (message) => message.toolCallId == 'repeat-check',
          ),
        ),
      );
      final withoutOriginal = compose(original.sublist(3));
      expect(
        body(withoutOriginal, 'repeat-check')['task'],
        oldTask,
        reason: 'No visible full dictionary means no reference',
      );
    },
  );

  test(
    'metadata-only state compression retains full skill disclosure metadata',
    () {
      final history = [
        LlmMessage.assistant('', toolCalls: [call('start', 'start_task')]),
        SkillDisclosureMessage(
          'start',
          jsonEncode({
            'ok': true,
            'task': current.task!.toJson(),
            'skills': {'ask': '完整技能正文'},
          }),
          fullRead: true,
          fullSkills: const {'ask/SKILL.md'},
          requiredSkills: const {'ask/SKILL.md', 'action-library/SKILL.md'},
        ),
        LlmMessage.assistant('继续。'),
      ];
      final composed = compose(history);
      final message = composed.singleWhere(
        (message) => message.toolCallId == 'start',
      );
      expect(body(composed, 'start')['task'], {'sameAsCurrentState': 'task'});
      expect(body(composed, 'start')['skills'], {'ask': '完整技能正文'});
      expect(message, isA<SkillDisclosureMessage>());
      final disclosure = message as SkillDisclosureMessage;
      expect(disclosure.fullRead, isTrue);
      expect(disclosure.fullSkills, {'ask/SKILL.md'});
      expect(disclosure.requiredSkills, {
        'ask/SKILL.md',
        'action-library/SKILL.md',
      });
      expect(
        SkillDisclosures.fromMessages(composed).sources['ask/SKILL.md'],
        SkillSource.startTask,
      );
      final wire = jsonEncode(message.toJson());
      for (final field in ['fullRead', 'fullSkills', 'requiredSkills']) {
        expect(wire, isNot(contains('"$field"')));
      }
    },
  );

  test('archived unrelated skills never regain full-text metadata', () {
    final history = [
      LlmMessage.assistant(
        '',
        toolCalls: [
          LlmToolCall(
            id: 'old-read',
            name: 'read',
            arguments: '{"path":"plan-training/SKILL.md"}',
          ),
        ],
      ),
      SkillDisclosureMessage('old-read', '不再相关的技能正文', fullRead: true),
      LlmMessage.assistant(
        '',
        toolCalls: [
          LlmToolCall(
            id: 'start',
            name: 'start_task',
            arguments: '{"type":"recommend"}',
          ),
        ],
      ),
      SkillDisclosureMessage(
        'start',
        jsonEncode({
          'ok': true,
          'task': current.task!.toJson(),
          'skills': {'ask': '完整技能正文'},
        }),
        fullSkills: const {'ask/SKILL.md'},
        requiredSkills: const {'ask/SKILL.md', 'action-library/SKILL.md'},
      ),
      LlmMessage.assistant('继续。'),
    ];
    final composed = compose(history);
    final archived = composed.singleWhere(
      (message) => message.toolCallId == 'old-read',
    );
    expect(archived.content, SkillDisclosures.unrelatedArchive);
    expect(archived, isNot(isA<SkillDisclosureMessage>()));
    expect(
      SkillDisclosures.fromMessages(
        composed,
      ).sources.containsKey('plan-training/SKILL.md'),
      isFalse,
    );
    expect(
      SkillDisclosures.fromMessages(composed).sources['ask/SKILL.md'],
      SkillSource.startTask,
    );
    expect((history[1] as SkillDisclosureMessage).fullRead, isTrue);
  });
}
