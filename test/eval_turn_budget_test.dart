import 'package:test/test.dart';

import '../tool/eval_turn_budget.dart';

EvaluationRecord _task(String type, {bool complete = false}) => {
  'type': type,
  'nodes': [
    {'id': 'actions', 'status': complete ? 'done' : 'current'},
    {'id': 'output', 'status': complete ? 'done' : 'pending'},
  ],
};

EvaluationRecord _event(
  int turn,
  int at,
  String type, {
  bool complete = false,
}) => {
  'turn': turn,
  'caseElapsedMs': at,
  'task': _task(type, complete: complete),
};

void main() {
  test(
    'cancelled recommendation retains observed 5-call and 25-second limits',
    () {
      final calls = List<EvaluationRecord>.generate(
        6,
        (index) => {
          'turn': 1,
          'caseElapsedMs': 100 + index,
          'requestBytes': 12000,
          'taskAtRequest': _task('recommend'),
        },
      );
      final events = [_event(1, 10, 'recommend')];
      // Cancellation can roll the final task snapshot back to null. Neither
      // classification nor the checks depend on that final snapshot.
      expect(
        evaluationTurnTaskType(turn: 1, events: events, calls: calls),
        'recommend',
      );
      expect(
        evaluationTurnBudgetFailures(
          turn: 1,
          elapsedMs: 83971,
          calls: calls,
          events: events,
        ),
        ['turn 1 exceeds 5 calls', 'turn 1 exceeds 25000 ms'],
      );
    },
  );

  test('cancelled plan uses the 8-call and 60-second thresholds', () {
    final events = [_event(1, 10, 'plan')];
    final calls = List<EvaluationRecord>.generate(
      9,
      (index) => {
        'turn': 1,
        'caseElapsedMs': 100 + index,
        'requestBytes': 12000,
      },
    );
    expect(
      evaluationTurnBudgetFailures(
        turn: 1,
        elapsedMs: 60001,
        calls: calls,
        events: events,
      ),
      ['turn 1 exceeds 8 calls', 'turn 1 exceeds 60000 ms'],
    );
    expect(
      evaluationTurnBudgetFailures(
        turn: 1,
        elapsedMs: 60000,
        calls: calls.take(8).toList(),
        events: events,
      ),
      isEmpty,
    );
  });

  test(
    'completed old task never imposes recommendation limits on a new QA turn',
    () {
      final events = [
        _event(1, 10, 'recommend'),
        _event(1, 20, 'recommend', complete: true),
        _event(2, 100, 'recommend', complete: true),
      ];
      final calls = List<EvaluationRecord>.generate(
        6,
        (index) => {
          'turn': 2,
          'caseElapsedMs': 101 + index,
          'requestBytes': 12000,
          'taskAtRequest': _task('recommend', complete: true),
        },
      );
      expect(
        evaluationTurnTaskType(turn: 2, events: events, calls: calls),
        'qa',
      );
      expect(
        evaluationTurnBudgetFailures(
          turn: 2,
          elapsedMs: 30000,
          calls: calls,
          events: events,
        ),
        isEmpty,
      );
    },
  );

  test(
    'latest timestamped active task wins and a completion keeps same-turn activity',
    () {
      final events = [
        _event(1, 10, 'recommend'),
        _event(1, 30, 'plan'),
        _event(1, 50, 'plan', complete: true),
      ];
      final calls = <EvaluationRecord>[
        {'turn': 1, 'caseElapsedMs': 20, 'taskAtRequest': _task('recommend')},
        {'turn': 1, 'caseElapsedMs': 40, 'taskAtRequest': _task('plan')},
      ];
      expect(
        evaluationTurnTaskType(turn: 1, events: events.reversed, calls: calls),
        'plan',
      );
    },
  );

  test('request-size check remains active even for QA', () {
    expect(
      evaluationTurnBudgetFailures(
        turn: 1,
        elapsedMs: 1,
        calls: [
          {'turn': 1, 'caseElapsedMs': 1, 'requestBytes': 40961},
        ],
        events: [],
      ),
      ['turn 1 actual request exceeds 40KB'],
    );
  });
}
