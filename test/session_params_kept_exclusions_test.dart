import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'support.dart';

void main() {
  final profile = loadProfile('smartfit');
  final params = SessionParams(ActionTags(profile, loadCatalog()));
  Map<String, Object?> value(Object value, String source, {String? quote}) => {
    'value': value,
    'source': source,
    'quote': ?quote,
  };
  Map<String, Object?> exclude(List<String> codes, String quote) => {
    'equipment_exclude': value(codes, 'user', quote: quote),
  };
  CoachSessionState home(String text) => params
      .applyHost(CoachSessionState(), const CoachContext(scene: 'home'))
      .state
      .appendUserTurn(text);

  test(
    'unknown scene explicitly configures wall and mat for every profile',
    () {
      for (final id in ['smartfit', 'hiplab', 'flarelab']) {
        expect(loadProfile(id).ambientEquipmentFor(null), {
          'equip.wall',
          'equip.mat',
        });
      }
    },
  );

  test(
    'lower-priority writes are kept while unrelated writes still commit',
    () {
      final state = CoachSessionState(
        params: {
          'scene': CoachParamValue(
            value: 'office',
            source: 'derived',
            turn: 1,
            quote: '坐久了',
          ),
          'goal': CoachParamValue(
            value: ['purpose.stretch'],
            source: 'user',
            turn: 1,
          ),
          'level': CoachParamValue(value: 2, source: 'host', turn: 1),
        },
      );
      final result = params.set(state, {
        'fields': {
          'scene': value('home', 'default'),
          'goal': value(['purpose.core'], 'preselect'),
          'level': value(1, 'default'),
          'minutes': value(15, 'default'),
        },
      });
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.kept, {'scene', 'goal', 'level'});
      expect(result.toJson()['kept'], containsAll(['scene', 'goal', 'level']));
      for (final key in result.kept) {
        expect(result.state.params[key], same(state.params[key]));
      }
      expect(result.state.params['minutes']!.value, 15);
      expect(result.changedFields, {'minutes'});
      expect(result.valueChangedFields, {'minutes'});
    },
  );

  test(
    'kept preselection does not need memory, but malformed values still fail atomically',
    () {
      final state = params
          .applyHost(CoachSessionState(), const CoachContext(minutes: 20))
          .state;
      final kept = params.set(state, {
        'fields': {'minutes': value(15, 'preselect')},
      });
      expect(kept.ok, isTrue);
      expect(kept.kept, {'minutes'});
      final invalid = params.set(state, {
        'fields': {
          'level': value(1, 'default'),
          'minutes': value('twenty', 'default'),
        },
      });
      expect(invalid.error!['code'], 'invalid_value');
      expect(invalid.state.toJson(), state.toJson());
    },
  );

  test('ambient exclusion ignores real nonambient catalogue equipment', () {
    final result = params.set(home('不用垫子和哑铃'), {
      'fields': exclude(['equip.mat', 'equip.dumbbell'], '不用垫子和哑铃'),
    });
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.state.params['equipment_exclude']!.value, ['equip.mat']);
    expect(result.ignoredEquipmentExclude, ['equip.dumbbell']);
    expect(result.toJson()['note'], contains('已忽略'));
    final ignored = params.set(home('不用哑铃'), {
      'fields': exclude(['equip.dumbbell'], '不用哑铃'),
    });
    expect(ignored.ok, isTrue);
    expect(ignored.state.params.containsKey('equipment_exclude'), isFalse);
    expect(ignored.changedFields, isEmpty);
  });

  test(
    'scene is applied before exclusions even when JSON fields use opposite order',
    () {
      final office = params
          .applyHost(CoachSessionState(), const CoachContext(scene: 'office'))
          .state
          .appendUserTurn('改成在家，不用垫子');
      final result = params.set(office, {
        'fields': {
          ...exclude(['equip.mat'], '不用垫子'),
          'scene': value('home', 'user', quote: '在家'),
        },
      });
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.params['equipment_exclude']!.value, ['equip.mat']);
      final stillOffice = params.set(office, {
        'fields': {
          ...exclude(['equip.mat'], '不用垫子'),
          'scene': value('home', 'default'),
        },
      });
      expect(stillOffice.ok, isTrue);
      expect(stillOffice.kept, {'scene'});
      expect(stillOffice.ignoredEquipmentExclude, ['equip.mat']);
      expect(
        stillOffice.state.params.containsKey('equipment_exclude'),
        isFalse,
      );
    },
  );

  test(
    'pure ignored proposal preserves old exclusions; active reductions still fail',
    () {
      final initial = params.set(home('不用垫子'), {
        'fields': exclude(['equip.mat'], '不用垫子'),
      });
      final state = initial.state.appendUserTurn('也不用哑铃或墙');
      final ignored = params.set(state, {
        'fields': exclude(['equip.dumbbell'], '不用哑铃'),
      });
      expect(ignored.ok, isTrue);
      expect(
        ignored.state.params['equipment_exclude'],
        same(state.params['equipment_exclude']),
      );
      final reduced = params.set(state, {
        'fields': exclude(['equip.wall', 'equip.dumbbell'], '不用哑铃或墙'),
      });
      expect(reduced.error!['code'], 'equipment_exclude_cannot_relax');
      final appended = params.set(state, {
        'fields': exclude([
          'equip.mat',
          'equip.wall',
          'equip.dumbbell',
        ], '不用哑铃或墙'),
      });
      expect(appended.ok, isTrue);
      expect(
        appended.state.params['equipment_exclude']!.value,
        containsAll(['equip.mat', 'equip.wall']),
      );
      expect(
        appended.state.params['equipment_exclude']!.value,
        isNot(contains('equip.dumbbell')),
      );
    },
  );

  test(
    'ignored exclusions still validate source, literal quote, and catalogue codes',
    () {
      final state = home('不用哑铃');
      expect(
        params.set(state, {
          'fields': {
            'equipment_exclude': value(['equip.dumbbell'], 'default'),
          },
        }).error!['code'],
        'invalid_source',
      );
      expect(
        params.set(state, {
          'fields': {
            'equipment_exclude': value(['equip.dumbbell'], 'user'),
          },
        }).error!['code'],
        'invalid_quote',
      );
      expect(
        params.set(state, {
          'fields': exclude(['equip.dumbbell'], '用户没说过'),
        }).error!['code'],
        'quote_not_found',
      );
      final unlisted = params.set(state, {
        'fields': exclude(['equip.rowing_machine'], '不用哑铃'),
      });
      expect(unlisted.ok, isTrue);
      expect(unlisted.ignoredEquipmentExclude, ['equip.rowing_machine']);
      expect(unlisted.state.params.containsKey('equipment_exclude'), isFalse);
      for (final invalid in ['body.abs', 'equip.', 'equip.bad code']) {
        expect(
          params.set(state, {
            'fields': exclude([invalid], '不用哑铃'),
          }).error!['code'],
          'invalid_value',
        );
      }
    },
  );
}
