import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const compactor = ContextCompactor();
  final base = loadCatalog();
  final drills = [
    for (var i = 0; i < 8; i++)
      Drill(
        id: 'action-$i',
        name: base.drills.first.name,
        category: 'strength',
        position: 'standing',
        unilateral: false,
        level: 1,
        defaultDose: base.drills.first.defaultDose,
        raw: {
          'trainingSemantics': {
            'unknownFields': [
              {'field': 'contraindications'},
              {'field': 'cautions'},
            ],
          },
        },
      ),
  ];
  final catalog = Catalog(version: 'test', drills: drills);
  String warning(String id, String field) => '$id 的 $field 尚未明确，不能视为已验证。';
  List<LlmMessage> history(List<String> warnings) => [
    LlmMessage.assistant(
      '',
      reasoning: '保留全部思考',
      toolCalls: [
        LlmToolCall(
          id: 'warnings',
          name: 'search_actions',
          arguments: '{"tags":[]}',
        ),
      ],
    ),
    LlmMessage.tool(
      'warnings',
      jsonEncode({
        'ok': true,
        'items': [
          {'id': 'action-0'},
        ],
        'warnings': warnings,
      }),
    ),
  ];
  List<Object?> restore(Object? value) {
    if (value is List) return value;
    final packed = value! as Map;
    expect(packed['template'], '{id} 的 {field} 尚未明确，不能视为已验证。');
    final fields = packed['fields'] as List;
    return [
      for (final row in packed['rows'] as List)
        if (row is String)
          row
        else
          warning((row as List)[0] as String, fields[row[1] as int] as String),
    ];
  }

  test(
    'catalogue warning compaction reconstructs every original warning in order',
    () {
      final warnings = [
        for (final drill in drills) ...[
          warning(drill.id, 'contraindications'),
          if (drill.id == 'action-2') '保持这条未识别的安全提示，不改变任何字。',
          warning(drill.id, 'cautions'),
        ],
      ];
      final original = history(warnings);
      final before = jsonEncode(
        original.map((message) => message.toJson()).toList(),
      );
      final composed = compactor.compose(
        system: const LlmMessage.system('角色'),
        state: CoachSessionState(),
        catalog: catalog,
        history: original,
      );
      final tool = composed.singleWhere(
        (message) => message.toolCallId == 'warnings',
      );
      final result = jsonDecode(tool.content) as Map;
      expect(result['warnings'], isA<Map<String, Object?>>());
      expect(restore(result['warnings']), warnings);
      expect(result['items'], [
        {'id': 'action-0'},
      ]);
      expect(
        composed
            .singleWhere((message) => message.role == LlmRole.assistant)
            .reasoning,
        '保留全部思考',
      );
      expect(
        jsonEncode(original.map((message) => message.toJson()).toList()),
        before,
      );
      expect(
        utf8.encode(jsonEncode(tool.toJson())).length,
        lessThan(utf8.encode(jsonEncode(original.last.toJson())).length),
      );
    },
  );

  test(
    'unrecognized or too-small warning lists remain byte-for-byte unchanged',
    () {
      for (final warnings in [
        <String>['未知安全提示'],
        [warning('action-0', 'contraindications')],
      ]) {
        final original = history(warnings);
        final composed = compactor.compose(
          system: const LlmMessage.system('角色'),
          state: CoachSessionState(),
          catalog: catalog,
          history: original,
        );
        expect(
          composed
              .singleWhere((message) => message.toolCallId == 'warnings')
              .content,
          original.last.content,
        );
      }
    },
  );
}
