import 'dart:convert';
import 'package:test/test.dart';
import '../tool/eval_quality.dart';

void main() {
  test(
    'advisories count actual emissions once, separate from final card copies',
    () {
      final warning = {'code': 'plan_block_purpose', 'message': 'Stage advice'};
      final receipt = {
        'role': 'tool',
        'tool_call_id': 'draft-1',
        'content': jsonEncode({
          'ok': true,
          'check': {
            'ok': true,
            'warningDetails': [warning],
          },
          'warningDetails': [warning],
        }),
      };
      final turns = <EvaluationJson>[
        {
          'turn': 1,
          'calls': [
            {
              'request': {
                'messages': [receipt],
              },
            },
            {
              'request': {
                'messages': [receipt],
              },
            },
          ],
          'agentHistoryAfterTurn': [receipt],
          'warnings': [
            {
              'code': 'plan_block_purpose',
              'message': 'Stage advice',
              'severity': 'warning',
            },
            {
              'code': 'catalog_safety_unknown',
              'message': 'Missing data',
              'severity': 'warning',
            },
          ],
        },
      ];
      final result = evaluationWarningSummary(turns);
      expect(result['advisoryEmissionCount'], 1);
      expect(result['advisoryCodes'], ['plan_block_purpose']);
      expect(result['deliveredWarningCount'], 2);
    },
  );
  test(
    'no visible warning receipt is not invented from a final card warning',
    () {
      expect(
        evaluationWarningSummary([
          {
            'turn': 1,
            'warnings': [
              {'code': 'plan_structure', 'message': 'Advice'},
            ],
          },
        ])['advisoryEmissionCount'],
        0,
      );
      expect(evaluationWarningSummary([])['deliveredWarningCount'], 0);
    },
  );
  test(
    'different tool ids remain distinct so a duplicate-emission regression is visible',
    () {
      final history = [
        for (final id in ['a', 'b'])
          {
            'role': 'tool',
            'tool_call_id': id,
            'content': jsonEncode({
              'ok': true,
              'warningDetails': [
                {'code': 'plan_structure', 'message': 'Advice'},
              ],
            }),
          },
      ];
      expect(
        evaluationWarningSummary([
          {'turn': 1, 'agentHistoryAfterTurn': history},
        ])['advisoryEmissionCount'],
        2,
      );
    },
  );
}
