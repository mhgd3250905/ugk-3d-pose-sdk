import 'package:test/test.dart';
import '../tool/eval_coach_agent_v2.dart';

void main() {
  test(
    'runner accepts updated parameters without relaxing stamps or order',
    () {
      const ids = ['understand', 'parameters', 'actions', 'output'];
      final nodes = <Json>[
        for (final id in ids)
          {
            'id': id,
            'status': id == 'parameters' ? 'updated' : 'done',
            'stamp': 'Complete $id',
          },
      ];
      expect(evaluationNodesComplete(nodes, ids), isTrue);
      nodes[1]['status'] = 'current';
      expect(evaluationNodesComplete(nodes, ids), isFalse);
      nodes[1]['status'] = 'updated';
      nodes[1]['stamp'] = '';
      expect(evaluationNodesComplete(nodes, ids), isFalse);
      nodes[1]['stamp'] = 'Updated';
      expect(evaluationNodesComplete(nodes.reversed.toList(), ids), isFalse);
    },
  );
  test('R6 locale comes from evaluation configuration only', () {
    expect(evaluationCaseContext({'id': 'R6', 'locale': 'en'}).language, 'en');
    expect(evaluationCaseContext({'id': 'R1'}).language, 'zh');
    expect(evaluationCaseContext({'id': 'R6'}).language, 'zh');
  });
}
