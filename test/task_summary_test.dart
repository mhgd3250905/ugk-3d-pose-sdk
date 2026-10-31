import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _stageIds = [
  'understand',
  'parameters',
  'actions',
  'planning',
  'review',
  'output',
];

CoachTaskState _task(String current, {bool complete = false}) {
  final selected = _stageIds.indexOf(current);
  return CoachTaskState(
    type: 'plan',
    reused: false,
    nodes: [
      for (var index = 0; index < _stageIds.length; index++)
        CoachNodeState(
          id: _stageIds[index],
          status: complete || index < selected
              ? 'done'
              : index == selected
              ? 'current'
              : 'pending',
          stamp: 'INTERNAL STAMP MUST NOT LEAK',
        ),
    ],
  );
}

CoachParamValue _param(Object? value, {String source = 'user'}) =>
    CoachParamValue(value: value, source: source, turn: 1);

CoachTaskSummary _parameters(Map<String, CoachParamValue> params) =>
    CoachTaskSummary.fromState(CoachSessionState(params: params));

void main() {
  group('task summary progress', () {
    test(
      'null and empty snapshots remain the initial sourced waiting state',
      () {
        for (final state in [null, CoachSessionState()]) {
          final summary = CoachTaskSummary.fromState(state);
          expect(summary.stages.map((stage) => stage.id), _stageIds);
          expect(summary.stages.map((stage) => stage.label), [
            '理解需求',
            '确认参数',
            '挑选动作',
            '安排计划',
            '检查计划',
            '交付结果',
          ]);
          expect(
            summary.stages.map((stage) => stage.status),
            everyElement('pending'),
          );
          expect(summary.phase, 0);
          expect(summary.status, '读懂你的需求');
          expect(summary.complete, isFalse);
          expect(summary.parameters, isEmpty);
          expect(summary.picks, isEmpty);
          expect(summary.sceneLabel, isNull);
          expect(summary.goalLabel, isNull);
          expect(summary.title, '正在想怎么练');
        }
      },
    );

    for (final (id, phase, status) in [
      ('understand', 0, '读懂你的需求'),
      ('parameters', 0, '读懂你的需求'),
      ('actions', 1, '挑好了 2 个动作'),
      ('planning', 2, '安排顺序和时长'),
      ('review', 3, '最后检查一遍'),
      ('output', 4, '马上就好'),
    ]) {
      test('$id uses the accepted sentence and four-band progress', () {
        final state = CoachSessionState(
          task: _task(id),
          picks: ['h-catcow-quad', 'h-banana'],
        );
        final summary = CoachTaskSummary.fromState(state);
        final current = _stageIds.indexOf(id);
        expect(summary.phase, phase);
        expect(summary.status, status);
        expect(summary.complete, isFalse);
        expect(summary.stages.map((stage) => stage.status), [
          for (var index = 0; index < _stageIds.length; index++)
            index < current
                ? 'done'
                : index == current
                ? 'current'
                : 'pending',
        ]);
        expect(summary.picks, ['h-catcow-quad', 'h-banana']);
        expect(summary.stages.toString(), isNot(contains('STAMP')));
      });
    }

    test('actions with no picks falls back without inventing a count', () {
      final summary = CoachTaskSummary.fromState(
        CoachSessionState(task: _task('actions')),
      );
      expect(summary.phase, 1);
      expect(summary.status, '读懂你的需求');
      expect(summary.picks, isEmpty);
    });

    test('done and updated output are complete and normalize to done', () {
      for (final outputStatus in ['done', 'updated']) {
        final task = _task('output', complete: true);
        final state = CoachSessionState(
          task: task.copyWith(
            nodes: [
              ...task.nodes.take(5),
              CoachNodeState(id: 'output', status: outputStatus),
            ],
          ),
        );
        final summary = CoachTaskSummary.fromState(state);
        expect(summary.complete, isTrue);
        expect(summary.phase, 4);
        expect(summary.status, '马上就好');
        expect(
          summary.stages.map((stage) => stage.status),
          everyElement('done'),
        );
      }
    });

    test('first current node wins; otherwise last done source node wins', () {
      CoachTaskSummary fromNodes(List<CoachNodeState> nodes) =>
          CoachTaskSummary.fromState(
            CoachSessionState(
              task: CoachTaskState(type: 'plan', nodes: nodes, reused: false),
            ),
          );
      final summary = fromNodes(const [
        CoachNodeState(id: 'review', status: 'updated'),
        CoachNodeState(id: 'actions', status: 'current'),
        CoachNodeState(id: 'planning', status: 'current'),
        CoachNodeState(id: 'output', status: 'done'),
      ]);
      expect(summary.phase, 1);
      // Visual completion remains a separate data fact, just as in SmartFit.
      expect(summary.complete, isTrue);
      final reordered = fromNodes(const [
        CoachNodeState(id: 'review', status: 'done'),
        CoachNodeState(id: 'actions', status: 'updated'),
      ]);
      expect(reordered.phase, 1);
      expect(reordered.stages[2].status, 'done');
      expect(reordered.stages[4].status, 'done');
    });

    test(
      'task override wins while picks and parameters still use the session',
      () {
        final state = CoachSessionState(
          task: _task('review'),
          picks: ['a'],
          params: {'scene': _param('office')},
        );
        final summary = CoachTaskSummary.fromState(
          state,
          task: _task('actions'),
        );
        expect(summary.phase, 1);
        expect(summary.status, '挑好了 1 个动作');
        expect(summary.picks, ['a']);
        expect(summary.sceneLabel, '办公室');
        expect(state.task!.nodes[4].status, 'current');
        expect(
          CoachTaskSummary.fromState(null, task: _task('planning')).phase,
          2,
        );
      },
    );

    test('missing and unknown stages do not leak backend identifiers', () {
      final summary = CoachTaskSummary.fromState(
        CoachSessionState(
          task: CoachTaskState(
            type: 'plan',
            reused: false,
            nodes: const [
              CoachNodeState(id: 'planning', status: 'running-internal'),
              CoachNodeState(id: 'internal', status: 'done'),
            ],
          ),
        ),
      );
      expect(summary.phase, 0);
      expect(summary.status, '读懂你的需求');
      expect(
        summary.stages.map((stage) => stage.status),
        everyElement('pending'),
      );
      expect(summary.stages.map((stage) => stage.id), _stageIds);
      expect(summary.complete, isFalse);
    });
  });

  group('sourced parameter labels', () {
    test('labels retain accepted order, title and exact user highlighting', () {
      final summary = _parameters({
        'limits': _param(<String>[], source: 'default'),
        'level': _param(3, source: 'derived'),
        'equipment': _param(<String>[], source: 'default'),
        'goal': _param(['body.hip', 'purpose.stretch']),
        'scene': _param('home'),
        'minutes': _param(20),
      });
      expect(summary.parameters, [
        (field: 'scene', label: '居家', user: true),
        (field: 'goal', label: '拉伸', user: true),
        (field: 'equipment', label: '徒手', user: false),
        (field: 'level', label: '进阶', user: false),
        (field: 'limits', label: '无伤痛', user: false),
      ]);
      expect(summary.sceneLabel, '居家');
      expect(summary.goalLabel, '拉伸');
      expect(summary.title, '为你准备 · 居家拉伸');
    });

    test('only user source highlights, including confirmed defaults', () {
      for (final source in [
        'user',
        'default',
        'derived',
        'host',
        'preselect',
        'User',
      ]) {
        expect(
          _parameters({
            'level': _param(1, source: source),
          }).parameters.single.user,
          source == 'user',
          reason: source,
        );
      }
    });

    test('known scenes and purposes retain SmartFit Chinese labels', () {
      for (final (code, label) in [
        ('home', '居家'),
        ('office', '办公室'),
        ('gym', '健身房'),
        ('outdoor', '户外'),
      ]) {
        expect(_parameters({'scene': _param(code)}).sceneLabel, label);
      }
      for (final (code, label) in [
        ('strength', '力量'),
        ('core', '核心'),
        ('cardio', '有氧'),
        ('mobility', '灵活'),
        ('stretch', '拉伸'),
      ]) {
        expect(
          _parameters({
            'goal': _param(['purpose.$code']),
          }).goalLabel,
          label,
        );
      }
    });

    test(
      'first known purpose wins without surfacing body or unknown codes',
      () {
        final summary = _parameters({
          'goal': _param([
            'body.hip',
            'purpose.internal_unknown',
            'purpose.stretch',
            'purpose.strength',
          ]),
        });
        expect(summary.goalLabel, '拉伸');
        expect(summary.parameters.single.label, '拉伸');
      },
    );

    test('unknown scene, goal and equipment do not invent default tags', () {
      final summary = _parameters({
        'scene': _param('scene.internal_unknown'),
        'goal': _param(['purpose.internal_unknown']),
        'equipment': _param(['equip.internal_unknown']),
      });
      expect(summary.parameters, isEmpty);
      expect(summary.title, '正在想怎么练');
    });

    test(
      'equipment takes first string and strips namespace and parentheticals',
      () {
        for (final (value, label) in <(Object?, String)>[
          (<String>[], '徒手'),
          (['none', 'none'], '徒手'),
          (['equip.none'], '徒手'),
          (['equip.chair', 'equip.wall'], '椅子'),
          (['equip.foam_roller'], '泡沫轴'),
          ([null, 2, 'dumbbell'], '哑铃'),
          (['瑜伽垫（可选）'], '瑜伽垫'),
          (['椅子(稳固)'], '椅子'),
        ]) {
          expect(
            _parameters({'equipment': _param(value)}).parameters.single.label,
            label,
          );
        }
        // Do not select a later known item if the first string is unknown.
        expect(
          _parameters({
            'equipment': _param(['equip.internal_unknown', 'equip.wall']),
          }).parameters,
          isEmpty,
        );
      },
    );

    test(
      'non-ASCII equipment copy and all accepted equipment remain usable',
      () {
        for (final (code, label) in [
          ('mat', '瑜伽垫'),
          ('slider', '滑垫'),
          ('cable', '绳索器械'),
          ('dip-bars', '双杠'),
          ('ghd', 'GHD训练器'),
          ('hip-abductor-machine', '髋外展训练器'),
          ('landmine', '地雷架'),
          ('leg-extension-machine', '腿屈伸训练器'),
          ('parallettes', '小双杠'),
          ('pullup-bar', '单杠'),
          ('reverse-hyper', '反向挺身器'),
          ('rings', '吊环'),
          ('roman-chair', '罗马椅'),
          ('swiss-ball', '健身球'),
          ('宿主自有器械', '宿主自有器械'),
        ]) {
          expect(
            _parameters({
              'equipment': _param([code]),
            }).parameters.single.label,
            label,
          );
        }
      },
    );

    test(
      'limits preserve order and use one safe fallback for unknown values',
      () {
        for (final (value, label) in <(Object?, String)>[
          (<String>[], '无伤痛'),
          (['limit.knee', 'limit.waist'], '膝、腰'),
          (
            ['limit.shoulder', 'limit.wrist', 'limit.neck', 'limit.hip'],
            '肩、手腕、颈、髋',
          ),
          (['limit.inner_thigh'], '大腿内侧'),
          (['limit.knee', 'limit.internal_unknown'], '身体限制'),
          ([null], '身体限制'),
        ]) {
          expect(
            _parameters({'limits': _param(value)}).parameters.single.label,
            label,
          );
        }
      },
    );

    test('malformed parameter values are omitted without throwing', () {
      expect(
        _parameters({
          'scene': _param({'id': 'home'}),
          'goal': _param('purpose.stretch'),
          'equipment': _param('equip.mat'),
          'level': _param(1.0),
          'limits': _param('limit.knee'),
        }).parameters,
        isEmpty,
      );
      expect(
        _parameters({
          'equipment': _param([null, 1]),
        }).parameters,
        isEmpty,
      );
    });

    test(
      'title requires both scene and goal rather than invented conditions',
      () {
        for (final params in [
          {'scene': _param('home')},
          {
            'goal': _param(['purpose.stretch']),
          },
          {'scene': _param('home'), 'goal': _param(<String>[])},
        ]) {
          expect(_parameters(params).title, '正在想怎么练');
        }
      },
    );

    test('levelZh retains the accepted fallback for every other integer', () {
      expect(levelZh(1), '入门');
      expect(levelZh(2), '基础');
      for (final level in [-5, 0, 3, 4, 100]) {
        expect(levelZh(level), '进阶');
      }
    });
  });

  test(
    'summary collections are immutable snapshots and projection is read-only',
    () {
      final picks = ['b', 'a'];
      final task = _task('actions');
      final state = CoachSessionState(
        task: task,
        picks: picks,
        params: {'scene': _param('home')},
      );
      final before = state.toJson();
      final summary = CoachTaskSummary.fromState(state);
      picks.add('late');
      expect(summary.picks, ['b', 'a']);
      expect(state.toJson(), before);
      expect(() => summary.picks.add('c'), throwsUnsupportedError);
      expect(() => summary.parameters.clear(), throwsUnsupportedError);
      expect(() => summary.stages.removeLast(), throwsUnsupportedError);
      expect(summary.picks, ['b', 'a']);
      expect(summary.stages, hasLength(6));
    },
  );

  test(
    'copy callbacks localize sourced facts without changing session state',
    () {
      final state = CoachSessionState(
        task: _task('actions'),
        picks: ['b', 'a'],
        params: {
          'scene': _param('home'),
          'goal': _param(['body.hip', 'purpose.stretch']),
          'level': _param(2, source: 'derived'),
        },
      );
      final before = state.toJson();
      final calls = <String>[];
      final summary = CoachTaskSummary.fromState(
        state,
        copy: CoachTaskSummaryCopy(
          stageLabel: (id, fallback) {
            calls.add('stage:$id:$fallback');
            return 'Stage $id';
          },
          parameterLabel: (field, value, fallback) {
            calls.add('param:$field:$fallback');
            if (value is List<Object?>) {
              expect(() => value.add('internal'), throwsUnsupportedError);
            }
            return switch (field) {
              'scene' => 'Home',
              'goal' => 'Stretching',
              'level' => 'Level $value',
              _ => fallback,
            };
          },
          status: (phase, count, fallback) {
            expect((phase, count, fallback), (1, 2, '挑好了 2 个动作'));
            return '$count exercises selected';
          },
          title: (scene, goal, fallback) {
            expect(fallback, '为你准备 · HomeStretching');
            return 'Preparing $goal at $scene';
          },
        ),
      );
      expect(summary.status, '2 exercises selected');
      expect(summary.title, 'Preparing Stretching at Home');
      expect(summary.sceneLabel, 'Home');
      expect(summary.goalLabel, 'Stretching');
      expect(summary.parameters.last, (
        field: 'level',
        label: 'Level 2',
        user: false,
      ));
      expect(summary.stages.map((stage) => stage.label), [
        for (final id in _stageIds) 'Stage $id',
      ]);
      expect(summary.stages[2].status, 'current');
      expect(summary.phase, 1);
      expect(summary.picks, ['b', 'a']);
      expect(calls, hasLength(9));
      expect(state.toJson(), before);
    },
  );

  test(
    'copy sees only valid parameters and supports optional copy overrides',
    () {
      final calledFields = <String>[];
      final state = CoachSessionState(
        params: {
          'scene': _param('internal'),
          'goal': _param(['purpose.unknown']),
          'equipment': _param(['equip.unknown']),
          'level': _param(1),
          'limits': _param(<String>[]),
        },
      );
      final summary = CoachTaskSummary.fromState(
        state,
        copy: CoachTaskSummaryCopy(
          parameterLabel: (field, value, fallback) {
            calledFields.add(field);
            return field == 'level' ? '' : fallback;
          },
          title: (scene, goal, fallback) {
            expect((scene, goal, fallback), (null, null, '正在想怎么练'));
            return 'Thinking';
          },
        ),
      );
      expect(calledFields, ['level', 'limits']);
      expect(summary.parameters, [(field: 'limits', label: '无伤痛', user: true)]);
      expect(summary.title, 'Thinking');
      expect(summary.status, '读懂你的需求');
      expect(
        CoachTaskSummary.fromState(
          state,
        ).parameters.map((parameter) => parameter.label),
        ['入门', '无伤痛'],
      );
      final defaults = CoachTaskSummary.fromState(
        state,
        copy: const CoachTaskSummaryCopy(),
      );
      expect(defaults.parameters, CoachTaskSummary.fromState(state).parameters);
      expect(defaults.title, '正在想怎么练');
    },
  );
}
