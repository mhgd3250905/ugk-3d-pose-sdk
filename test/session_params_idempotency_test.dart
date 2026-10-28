import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final params = SessionParams(
    ActionTags(loadProfile('smartfit'), loadCatalog()),
  );
  Map<String, Object?> field(
    String name,
    Object value,
    String source, {
    String? quote,
    String? direction,
  }) => {
    'fields': {
      name: {
        'value': value,
        'source': source,
        'quote': ?quote,
        'direction': ?direction,
      },
    },
  };
  CoachSessionState inferred() => params
      .set(
        CoachSessionState().appendUserTurn('坐了挺久，我想拉伸一下'),
        field('scene', 'office', 'derived', quote: '坐了挺久'),
      )
      .state;

  test(
    'R1 recommend to plan replay retains the original derived scene proof',
    () {
      final completed = inferred().copyWith(
        task: CoachTaskState(
          type: 'recommend',
          reused: false,
          nodes: [
            for (final id in ['understand', 'parameters', 'actions', 'output'])
              CoachNodeState(
                id: id,
                status: 'done',
                stamp: '已完成',
                doneAtTurn: 1,
              ),
          ],
        ),
      );
      final nextTurn = completed.appendUserTurn('你帮我安排一个计划吧');
      final started = AgentTask.start(nextTurn, 'plan');
      expect(started.ok, isTrue);
      expect(started.state.task!.reused, isTrue);
      final old = completed.params['scene']!;
      final repeated = params.set(started.state, {
        'fields': {
          'scene': {'value': 'office', 'source': 'derived', 'quote': '坐了挺久'},
          'minutes': {'value': 10, 'source': 'default'},
        },
      });
      expect(repeated.ok, isTrue, reason: '${repeated.error}');
      expect(repeated.kept, {'scene'});
      expect(repeated.changedFields, {'minutes'});
      expect(repeated.valueChangedFields, {'minutes'});
      expect(repeated.state.params['scene'], same(old));
      expect(repeated.state.params['scene']!.quote, '坐了挺久');
      expect(repeated.state.params['scene']!.turn, 1);
    },
  );

  test(
    'same-value new quotes never drift confirmed or inferred provenance',
    () {
      for (final source in ['user', 'derived']) {
        final first = params.set(
          CoachSessionState().appendUserTurn('在办公室坐了挺久'),
          field('scene', 'office', source, quote: '在办公室'),
        );
        expect(first.ok, isTrue);
        final old = first.state.params['scene']!;
        final state = first.state.appendUserTurn('今天仍在办公室');
        final replay = params.set(
          state,
          field('scene', 'office', source, quote: '今天仍在办公室'),
        );
        expect(replay.ok, isTrue);
        expect(replay.kept, {'scene'});
        expect(replay.changedFields, isEmpty);
        expect(replay.state.params['scene'], same(old));
      }
      final host = params
          .applyHost(CoachSessionState(), const CoachContext(scene: 'office'))
          .state;
      final repeated = params.set(
        host.appendUserTurn('我在办公室'),
        field('scene', 'office', 'user', quote: '办公室'),
      );
      expect(repeated.ok, isTrue);
      expect(repeated.kept, {'scene'});
      expect(repeated.state.params['scene'], same(host.params['scene']));
    },
  );

  test(
    'derived minute replay preserves basedOn without reapplying the adjustment',
    () {
      final initial = params
          .set(
            CoachSessionState().appendUserTurn('20分钟'),
            field('minutes', 20, 'user', quote: '20分钟'),
          )
          .state;
      final short = params.set(
        initial.appendUserTurn('短一点'),
        field('minutes', 15, 'derived', quote: '短一点', direction: 'shorter'),
      );
      expect(short.ok, isTrue);
      final old = short.state.params['minutes']!;
      final repeated = params.set(
        short.state.appendUserTurn('排成计划吧'),
        field('minutes', 15, 'derived', quote: '短一点', direction: 'shorter'),
      );
      expect(repeated.ok, isTrue, reason: '${repeated.error}');
      expect(repeated.kept, {'minutes'});
      expect(repeated.changedFields, isEmpty);
      expect(repeated.state.params['minutes'], same(old));
      expect(old.basedOn!.quote, '20分钟');
      final freshSameValue = params.set(
        short.state.appendUserTurn('还是短一点'),
        field('minutes', 15, 'derived', quote: '还是短一点', direction: 'shorter'),
      );
      expect(freshSameValue.ok, isTrue);
      expect(freshSameValue.state.params['minutes'], same(old));
    },
  );

  test(
    'same-value source promotion requires a real quote while lower sources keep proof',
    () {
      final current = inferred().appendUserTurn('我就在办公室');
      final forged = params.set(
        current,
        field('scene', 'office', 'user', quote: '我在健身房'),
      );
      expect(forged.error!['code'], 'quote_not_found');
      final confirmed = params.set(
        current,
        field('scene', 'office', 'user', quote: '办公室'),
      );
      expect(confirmed.ok, isTrue);
      expect(confirmed.state.params['scene']!.source, 'user');
      expect(confirmed.state.params['scene']!.quote, '办公室');
      expect(confirmed.state.params['scene']!.turn, 2);
      for (final source in ['derived', 'default', 'preselect']) {
        final kept = params.set(
          confirmed.state.appendUserTurn('继续'),
          field('scene', 'office', source, quote: '坐了挺久'),
        );
        expect(kept.ok, isTrue, reason: '${kept.error}');
        expect(kept.kept, {'scene'});
        expect(
          kept.state.params['scene'],
          same(confirmed.state.params['scene']),
        );
      }
      expect(
        params.set(current, field('scene', 'office', 'host')).error!['code'],
        'invalid_source',
      );
    },
  );

  test(
    'actual value changes still require fresh provenance and preserve injury and equipment gates',
    () {
      final old = inferred().appendUserTurn('我现在在家');
      final stale = params.set(
        old,
        field('scene', 'home', 'derived', quote: '坐了挺久'),
      );
      expect(stale.error!['code'], 'derived_quote_not_new');
      final fresh = params.set(
        old,
        field('scene', 'home', 'derived', quote: '现在在家'),
      );
      expect(fresh.ok, isTrue);
      expect(fresh.state.params['scene']!.value, 'home');
      expect(fresh.state.params['scene']!.turn, 2);
      var gear = params
          .set(
            CoachSessionState().appendUserTurn('有瑜伽垫'),
            field('equipment', ['equip.mat'], 'user', quote: '瑜伽垫'),
          )
          .state;
      gear = gear.appendUserTurn('还是瑜伽垫');
      final replay = params.set(
        gear,
        field('equipment', ['equip.mat'], 'user', quote: '还是瑜伽垫'),
      );
      expect(replay.state.params['equipment']!.turn, 1);
      final oldGear = params.set(
        replay.state,
        field('equipment', ['equip.mat', 'equip.wall'], 'user', quote: '有瑜伽垫'),
      );
      expect(oldGear.error!['code'], 'equipment_not_newly_confirmed');
      final updated = params.set(
        replay.state.appendUserTurn('还有墙'),
        field('equipment', ['equip.mat', 'equip.wall'], 'user', quote: '还有墙'),
      );
      expect(updated.ok, isTrue);
      final protected = params
          .applyHost(updated.state, const CoachContext(avoid: {'wrist'}))
          .state;
      final relaxed = params.set(
        protected.appendUserTurn('没有限制'),
        field('limits', <String>[], 'user', quote: '没有限制'),
      );
      expect(relaxed.error!['code'], 'limits_cannot_relax');
    },
  );

  test(
    'operation execution can advance while same-value proof remains unchanged',
    () {
      final first = params
          .set(
            CoachSessionState().appendUserTurn('换一套'),
            field('operation', 'replace_all', 'user', quote: '换一套'),
          )
          .state;
      expect(first.lastOperationRequestTurn, 1);
      final proof = first.params['operation']!;
      final handler = StructuredToolHandler(
        loadProfile('smartfit'),
        loadCatalog(),
        newPlanId: () => 'unused',
      );
      for (final quote in ['换一套', '重新安排']) {
        final replay = handler.setParams(
          first.appendUserTurn(quote),
          field('operation', 'replace_all', 'user', quote: quote),
          'zh',
          const [],
        );
        expect(replay.fresh, isTrue);
        expect(replay.changes, isEmpty);
        expect(replay.state.lastOperationRequestTurn, 2);
        expect(replay.state.params['operation'], same(proof));
        expect(replay.state.params['operation']!.quote, '换一套');
        expect(replay.state.params['operation']!.turn, 1);
        final restored = CoachSessionState.fromJson(replay.state.toJson());
        expect(restored.lastOperationRequestTurn, 2);
        expect(restored.params['operation']!.toJson(), proof.toJson());
      }
    },
  );

  test(
    'unrelated old operation quote is kept without new execution authorization',
    () {
      final first = params
          .set(
            CoachSessionState().appendUserTurn('换一套'),
            field('operation', 'replace_all', 'user', quote: '换一套'),
          )
          .state;
      final handler = StructuredToolHandler(
        loadProfile('smartfit'),
        loadCatalog(),
        newPlanId: () => 'unused',
      );
      final replay = handler.setParams(
        first.appendUserTurn('谢谢'),
        field('operation', 'replace_all', 'user', quote: '换一套'),
        'zh',
        const [],
      );
      expect(replay.fresh, isFalse);
      expect(replay.state.lastOperationRequestTurn, 1);
      expect(replay.state.params['operation'], same(first.params['operation']));
      final latest = params
          .set(
            first.appendUserTurn('重新安排'),
            field('operation', 'replace_all', 'user', quote: '重新安排'),
          )
          .state;
      final oldValueChange = params.set(
        latest,
        field('operation', 'edit', 'user', quote: '换一套'),
      );
      expect(oldValueChange.ok, isTrue);
      expect(
        oldValueChange.state.lastOperationRequestTurn,
        1,
        reason:
            'a changed intent cannot inherit a prior current-turn authorization',
      );
    },
  );
}
