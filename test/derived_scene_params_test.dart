import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'support.dart';

void main() {
  final params = SessionParams(
    ActionTags(loadProfile('smartfit'), loadCatalog()),
  );
  Map<String, Object?> scene(
    String value,
    String source, {
    String? quote,
    String? direction,
  }) => {
    'fields': {
      'scene': {
        'value': value,
        'source': source,
        'quote': ?quote,
        'direction': ?direction,
      },
    },
  };
  CoachSessionState inferred() {
    final result = params.set(
      CoachSessionState().appendUserTurn('坐了挺久'),
      scene('office', 'derived', quote: '坐了挺久'),
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    return result.state;
  }

  test(
    'inferred scene stamp and field schema do not claim a user location',
    () {
      final gate = NodeGates(
        loadProfile('smartfit'),
        loadCatalog(),
        minPicks: 3,
      );
      final state = inferred().copyWith(
        task: CoachTaskState(
          type: 'recommend',
          reused: false,
          nodes: const [
            CoachNodeState(id: 'understand', status: 'done'),
            CoachNodeState(id: 'parameters', status: 'current'),
            CoachNodeState(id: 'actions', status: 'pending'),
            CoachNodeState(id: 'output', status: 'pending'),
          ],
        ),
        params: {
          ...inferred().params,
          'goal': CoachParamValue(
            value: ['purpose.stretch'],
            source: 'default',
            turn: 1,
          ),
        },
      );
      expect(
        gate.check(state, 'parameters').state.task!.nodes[1].stamp,
        contains('办公室（推测）'),
      );
      expect(
        gate
            .check(state, 'parameters', language: 'en')
            .state
            .task!
            .nodes[1]
            .stamp,
        contains('Office (inferred)'),
      );
      final schema = AgentTools.build(
        loadProfile('smartfit'),
        loadCatalog(),
        memory: false,
      ).singleWhere((tool) => tool.name == 'set_params').parameters;
      final field =
          (((schema['properties'] as Map)['fields'] as Map)['properties']
                  as Map)['scene']
              as Map;
      final properties = field['properties'] as Map;
      expect((properties['source'] as Map)['enum'], contains('derived'));
      expect(properties.containsKey('direction'), isFalse);
    },
  );

  test(
    'derived scene keeps fresh quote without minutes direction or basedOn',
    () {
      final current = inferred();
      final value = current.params['scene']!;
      expect(
        (value.value, value.source, value.quote),
        ('office', 'derived', '坐了挺久'),
      );
      expect(value.direction, isNull);
      expect(value.basedOn, isNull);
      expect(
        CoachSessionState.fromJson(current.toJson()).toJson(),
        current.toJson(),
      );
    },
  );

  test('derived scene needs current quote and rejects direction', () {
    final current = CoachSessionState().appendUserTurn('坐了挺久');
    expect(
      params.set(current, scene('office', 'derived')).error!['code'],
      'invalid_quote',
    );
    expect(
      params
          .set(
            current.appendUserTurn('继续'),
            scene('office', 'derived', quote: '坐了挺久'),
          )
          .error!['code'],
      'derived_quote_not_new',
    );
    expect(
      params
          .set(
            current,
            scene('office', 'derived', quote: '坐了挺久', direction: 'shorter'),
          )
          .error!['code'],
      'invalid_direction',
    );
  });

  test('explicit user and host settings override inferred scene', () {
    final current = inferred().appendUserTurn('我现在在家');
    final user = params.set(current, scene('home', 'user', quote: '在家'));
    expect(user.ok, isTrue, reason: '${user.error}');
    expect(user.state.params['scene']!.source, 'user');
    final host = params.applyHost(inferred(), const CoachContext(scene: 'gym'));
    expect(host.ok, isTrue);
    expect(host.state.params['scene']!.source, 'host');
  });

  test('defaults and preselection cannot override derived scene', () {
    for (final source in ['default', 'preselect']) {
      expect(
        params.set(inferred(), scene('home', source)).error!['code'],
        'source_conflict',
      );
    }
  });

  test(
    'inference does not override explicit scene; can improve same-turn default',
    () {
      final user = params
          .set(
            CoachSessionState().appendUserTurn('在家'),
            scene('home', 'user', quote: '在家'),
          )
          .state
          .appendUserTurn('坐了挺久');
      expect(
        params
            .set(user, scene('office', 'derived', quote: '坐了挺久'))
            .error!['code'],
        'source_conflict',
      );
      final current = CoachSessionState().appendUserTurn('坐了挺久');
      final defaulted = params.set(current, scene('home', 'default')).state;
      expect(
        params.set(defaulted, scene('office', 'derived', quote: '坐了挺久')).ok,
        isTrue,
      );
    },
  );
}
