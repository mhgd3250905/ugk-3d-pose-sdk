import 'dart:convert';
import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'support.dart';

void main() {
  final writer = SessionParams(
    ActionTags(loadProfile('smartfit'), loadCatalog()),
  );
  Map<String, Object?> fields(
    Object value, {
    String source = 'user',
    String quote = '深蹲3组',
  }) => {
    'fields': {
      'dose': {'value': value, 'source': source, 'quote': quote},
    },
  };
  final constraints = [
    {'field': 'sets', 'value': 3, 'actionId': 'h-squat'},
  ];
  test(
    'explicit scoped dose retains literal user source and restores losslessly',
    () {
      final before = CoachSessionState().appendUserTurn('深蹲3组');
      final result = writer.set(before, fields(constraints));
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.params['dose']!.value, constraints);
      expect(result.state.params['dose']!.source, 'user');
      expect(result.state.params['dose']!.quote, '深蹲3组');
      expect(
        CoachSessionState.fromJson(
          jsonDecode(jsonEncode(result.state.toJson())) as Map<String, Object?>,
        ).toJson(),
        result.state.toJson(),
      );
    },
  );
  test('dose cannot forge host, default or user quotation', () {
    final state = CoachSessionState().appendUserTurn('随便安排');
    for (final source in ['host', 'default', 'derived', 'preselect']) {
      expect(
        writer.set(state, fields(constraints, source: source)).ok,
        isFalse,
      );
    }
    expect(
      writer.set(state, fields(constraints)).error!['code'],
      'quote_not_found',
    );
  });
  test(
    'dose only references real in-scope actions and unambiguous constraints',
    () {
      final state = CoachSessionState().appendUserTurn('深蹲3组');
      expect(
        writer
            .set(
              state,
              fields([
                {'field': 'sets', 'value': 3, 'actionId': 'invented'},
              ]),
            )
            .ok,
        isFalse,
      );
      expect(
        writer
            .set(
              state,
              fields([
                {'field': 'sets', 'value': 3},
                {'field': 'sets', 'value': 4},
              ]),
            )
            .ok,
        isFalse,
      );
      final normalized = writer.set(
        state,
        fields([
          {'field': 'sets', 'value': '3'},
        ]),
      );
      expect(normalized.ok, isTrue);
      expect((normalized.state.params['dose']!.value as List).single, {
        'field': 'sets',
        'value': 3,
      });
    },
  );
  test(
    'normalization never weakens literal source; long genuine quote is shortened only after validation',
    () {
      const quote =
          'Please make the squat exactly three sets and keep the same goal.';
      final result = writer.set(
        CoachSessionState().appendUserTurn(quote),
        fields(constraints, quote: quote),
      );
      expect(result.ok, isTrue);
      expect(result.state.params['dose']!.quote!.runes.length, 30);
      expect(result.notes, isNotEmpty);
      final fake = writer.set(
        CoachSessionState().appendUserTurn(quote.substring(0, 30)),
        fields(constraints, quote: quote),
      );
      expect(fake.error!['code'], 'quote_not_found');
    },
  );
  test(
    'low priority invalid unused values and empty updates are harmless noops',
    () {
      final state = CoachSessionState(
        params: {
          'minutes': CoachParamValue(value: 20, source: 'host', turn: 0),
        },
      );
      final kept = writer.set(state, {
        'fields': {
          'minutes': {'source': 'default', 'value': 'not a minute'},
        },
      });
      expect(kept.ok, isTrue);
      expect(kept.kept, {'minutes'});
      expect(kept.state.params['minutes'], same(state.params['minutes']));
      expect(writer.set(state, {'fields': {}}).ok, isTrue);
    },
  );
  test(
    'derived minutes are calculated and repeated trial uses the same baseline',
    () {
      final state = CoachSessionState(
        params: {
          'minutes': CoachParamValue(
            value: 20,
            source: 'user',
            turn: 0,
            quote: '20分钟',
          ),
        },
      ).appendUserTurn('短一点');
      final args = {
        'fields': {
          'minutes': {
            'source': 'derived',
            'direction': 'shorter',
            'quote': '短一点',
          },
        },
      };
      final first = writer.set(state, args);
      expect(first.ok, isTrue);
      expect(first.state.params['minutes']!.value, 15);
      final again = writer.set(first.state, args);
      expect(again.ok, isTrue, reason: '${again.error}');
      expect(again.state.params['minutes']!.value, 15);
      expect(again.state.params['minutes']!.basedOn!.value, 20);
    },
  );
  test(
    'empty derived feasible range returns a choice, not a model rejection',
    () {
      final state = CoachSessionState(
        params: {'minutes': CoachParamValue(value: 5, source: 'user', turn: 0)},
      ).appendUserTurn('短一点');
      final result = writer.set(state, {
        'fields': {
          'minutes': {
            'source': 'derived',
            'direction': 'shorter',
            'quote': '短一点',
          },
        },
      });
      expect(result.ok, isTrue);
      expect(result.toJson()['needsUserChoice'], isTrue);
      expect(result.state.params['minutes']!.value, 5);
    },
  );
  test(
    'warning dedup and structured/legacy timing logs restore without mutation leaks',
    () {
      final state = CoachSessionState(
        emittedWarningCodes: {'plan_block_purpose'},
        pendingSearchTurn: 2,
        plans: {
          'p': [
            CoachPlanVersion(
              version: 1,
              plan: {},
              estimateSec: 0,
              fitLog: [
                'legacy',
                {'blockId': 'b1', 'field': 'rounds', 'before': 2, 'after': 1},
              ],
            ),
          ],
        },
      );
      final saved = state.toJson();
      expect(CoachSessionState.fromJson(saved).toJson(), saved);
      final log = ((saved['plans'] as Map)['p'] as List).single as Map;
      ((log['fitLog'] as List).last as Map)['after'] = 99;
      expect((state.plans['p']!.single.fitLog.last as Map)['after'], 1);
    },
  );
}
