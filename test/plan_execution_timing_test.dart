import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _plan = TrainingPlan(
  id: 'timing-contract',
  source: 'ai',
  title: 'Timeline contract',
  goal: 'mobility',
  scene: 'home',
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(id: 'warmup', name: 'Warmup', type: BlockType.warmup, items: []),
    PlanBlock(id: 'main', name: 'Main', type: BlockType.main, items: []),
  ],
);

const _validBlocks = [
  PlanBlockExecutionTiming(blockId: 'warmup', seconds: 40),
  PlanBlockExecutionTiming(blockId: 'main', seconds: 245),
];

TypeMatcher<PlanExecutionTimingException> _timingError(
  String code,
  String reason,
) => isA<PlanExecutionTimingException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.reason, 'reason', reason);

void main() {
  test(
    'callback receives the candidate once and preserves manual estimate',
    () {
      var calls = 0;
      final result = evaluatePlanExecutionTiming(_plan, (candidate) {
        calls++;
        expect(identical(candidate, _plan), isTrue);
        return const PlanExecutionTiming(
          totalSeconds: 300,
          blocks: _validBlocks,
          containsManualCounting: true,
        );
      });
      expect(calls, 1);
      expect(result.totalSeconds, 300);
      expect(result.blocks.map((block) => block.blockId), ['warmup', 'main']);
      expect(result.blocks.map((block) => block.seconds), [40, 245]);
      expect(result.containsManualCounting, isTrue);
    },
  );

  test('zero-duration empty plan is a valid measurement', () {
    final result = evaluatePlanExecutionTiming(
      _plan.copyWith(blocks: []),
      (_) => const PlanExecutionTiming(totalSeconds: 0, blocks: []),
    );
    expect(result.totalSeconds, 0);
    expect(result.blocks, isEmpty);
    expect(result.containsManualCounting, isFalse);
  });

  test('validated block list is detached and immutable', () {
    final mutableBlocks = [..._validBlocks];
    final result = evaluatePlanExecutionTiming(
      _plan,
      (_) => PlanExecutionTiming(totalSeconds: 300, blocks: mutableBlocks),
    );
    mutableBlocks.clear();
    expect(result.blocks, hasLength(2));
    expect(() => result.blocks.clear(), throwsUnsupportedError);
  });

  for (final (name, value) in [
    ('NaN', double.nan),
    ('infinity', double.infinity),
    ('negative infinity', double.negativeInfinity),
    ('negative', -1.0),
  ]) {
    test('rejects $name total seconds', () {
      expect(
        () => evaluatePlanExecutionTiming(
          _plan,
          (_) => PlanExecutionTiming(totalSeconds: value, blocks: _validBlocks),
        ),
        throwsA(
          _timingError('invalid_execution_timing', 'invalid_total_seconds'),
        ),
      );
    });
    test('rejects $name block seconds', () {
      expect(
        () => evaluatePlanExecutionTiming(
          _plan,
          (_) => PlanExecutionTiming(
            totalSeconds: 300,
            blocks: [
              PlanBlockExecutionTiming(blockId: 'warmup', seconds: value),
              _validBlocks.last,
            ],
          ),
        ),
        throwsA(
          _timingError('invalid_execution_timing', 'invalid_block_seconds'),
        ),
      );
    });
  }

  for (final (name, blocks, reason)
      in <(String, List<PlanBlockExecutionTiming>, String)>[
        ('missing blocks', [], 'block_count_mismatch'),
        (
          'extra blocks',
          [
            ..._validBlocks,
            const PlanBlockExecutionTiming(blockId: 'extra', seconds: 0),
          ],
          'block_count_mismatch',
        ),
        (
          'reordered blocks',
          _validBlocks.reversed.toList(),
          'block_order_mismatch',
        ),
        (
          'unknown block',
          [
            _validBlocks.first,
            const PlanBlockExecutionTiming(blockId: 'unknown', seconds: 245),
          ],
          'block_order_mismatch',
        ),
        (
          'empty block id',
          [
            const PlanBlockExecutionTiming(blockId: ' ', seconds: 40),
            _validBlocks.last,
          ],
          'empty_block_id',
        ),
        (
          'duplicate block id',
          [_validBlocks.first, _validBlocks.first],
          'duplicate_block_id',
        ),
        (
          'block seconds greater than total',
          [
            const PlanBlockExecutionTiming(blockId: 'warmup', seconds: 100),
            _validBlocks.last,
          ],
          'block_seconds_exceed_total',
        ),
      ]) {
    test('rejects $name', () {
      expect(
        () => evaluatePlanExecutionTiming(
          _plan,
          (_) => PlanExecutionTiming(totalSeconds: 300, blocks: blocks),
        ),
        throwsA(_timingError('invalid_execution_timing', reason)),
      );
    });
  }

  test(
    'block sum allows floating-point rounding without permitting excess',
    () {
      final result = evaluatePlanExecutionTiming(
        _plan,
        (_) => const PlanExecutionTiming(
          totalSeconds: .3,
          blocks: [
            PlanBlockExecutionTiming(blockId: 'warmup', seconds: .1),
            PlanBlockExecutionTiming(blockId: 'main', seconds: .2),
          ],
        ),
      );
      expect(result.totalSeconds, .3);
      expect(
        () => evaluatePlanExecutionTiming(
          _plan,
          (_) => const PlanExecutionTiming(
            totalSeconds: .3,
            blocks: [
              PlanBlockExecutionTiming(blockId: 'warmup', seconds: .1),
              PlanBlockExecutionTiming(blockId: 'main', seconds: .200001),
            ],
          ),
        ),
        throwsA(
          _timingError(
            'invalid_execution_timing',
            'block_seconds_exceed_total',
          ),
        ),
      );
    },
  );

  for (final (name, error) in <(String, Object)>[
    ('Exception', Exception('private host configuration')),
    ('Error', StateError('private host configuration')),
    ('non-Exception object', 'private host configuration'),
  ]) {
    test('converts thrown $name to a safe callback diagnostic', () {
      expect(
        () => evaluatePlanExecutionTiming(_plan, (_) => throw error),
        throwsA(
          _timingError(
            'execution_timing_callback_failed',
            'callback_threw',
          ).having(
            (error) => error.toString(),
            'safe message',
            isNot(contains('private host configuration')),
          ),
        ),
      );
    });
  }
}
