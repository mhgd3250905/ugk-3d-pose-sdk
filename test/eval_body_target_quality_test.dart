import 'package:test/test.dart';
import '../tool/eval_quality.dart';

void main() {
  EvaluationJson turn({bool plan = false}) => {
    'turn': 1,
    'params': {
      'goal': {
        'value': ['body.core'],
      },
    },
    'expandedBodyGoalCodes': ['body.core', 'body.abs', 'body.obliques'],
    'bodyFocusMinRatio': .5,
    'actions': plan
        ? []
        : [
            {'id': 'a'},
            {'id': 'b'},
          ],
    if (plan)
      'plan': {
        'blocks': [
          {
            'type': 'warmup',
            'items': [
              {'exerciseId': 'c'},
            ],
          },
          {
            'type': 'main',
            'items': [
              {'exerciseId': 'a'},
              {'exerciseId': 'b'},
            ],
          },
        ],
      },
    'actionFacts': [
      {
        'id': 'a',
        'tags': ['body.shoulder', 'body.obliques'],
      },
      {
        'id': 'b',
        'tags': ['body.legs'],
      },
      {
        'id': 'c',
        'tags': ['body.legs'],
      },
    ],
  };
  test(
    'recommend requires every target hit; main counts secondary descendant and excludes warmup',
    () {
      expect(evaluationBodyTargetQuality([turn()])['status'], 'fail');
      final result = evaluationBodyTargetQuality([turn(plan: true)]);
      expect(result['status'], 'pass');
      final check = (result['checks'] as List).single as Map;
      expect(check['matched'], 1);
      expect(check['total'], 2);
    },
  );
  test('missing facts need manual review and no delivery is not observed', () {
    final t = turn()..remove('actionFacts');
    expect(evaluationBodyTargetQuality([t])['status'], 'manual_review');
    expect(evaluationBodyTargetQuality([])['status'], 'not_observed');
  });
  test('purpose-only goal is not fabricated as a body goal', () {
    final t = turn()
      ..['params'] = {
        'goal': {
          'value': ['purpose.stretch'],
        },
      };
    expect(evaluationBodyTargetQuality([t])['status'], 'not_applicable');
  });
}
