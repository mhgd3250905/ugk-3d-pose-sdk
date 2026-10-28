import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _fields(Map<String, Object?> fields) => {'fields': fields};
Map<String, Object?> _user(Object? value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};
Map<String, Object?> _other(Object? value, String source) => {
  'value': value,
  'source': source,
};

void main() {
  final catalog = loadCatalog();
  final tags = ActionTags(loadProfile('smartfit'), catalog);
  final params = SessionParams(tags);

  test('R2 blocks equipment additions from the same message atomically', () {
    var state = CoachSessionState().appendUserTurn('在家，有瑜伽垫，练大腿内侧。');
    final initial = params.set(
      state,
      _fields({
        'scene': _user('home', '在家'),
        'equipment': _user(['equip.mat'], '有瑜伽垫'),
      }),
    );
    expect(initial.ok, isTrue, reason: '${initial.error}');
    state = initial.state;
    final before = state.toJson();
    final rejected = params.set(
      state,
      _fields({
        'scene': _user('office', '在家'),
        'equipment': _user(['equip.mat', 'equip.wall', 'equip.block'], '有瑜伽垫'),
      }),
    );
    expect(rejected.error!['code'], 'equipment_not_newly_confirmed');
    expect(rejected.state.toJson(), before);
    expect(state.toJson(), before);
    for (final key in ['ok', 'code', 'field', 'expected', 'actual', 'fix']) {
      expect(rejected.error!.containsKey(key), isTrue, reason: key);
    }
  });

  test('new user turn permits an equipment addition; old quotes cannot', () {
    var state = CoachSessionState().appendUserTurn('我有瑜伽垫');
    state = params
        .set(
          state,
          _fields({
            'equipment': _user(['equip.mat'], '瑜伽垫'),
          }),
        )
        .state;
    state = state.appendUserTurn('现在还有墙');
    final oldQuote = params.set(
      state,
      _fields({
        'equipment': _user(['equip.mat', 'equip.wall'], '瑜伽垫'),
      }),
    );
    expect(oldQuote.error!['code'], 'equipment_not_newly_confirmed');
    final update = params.set(
      state,
      _fields({
        'equipment': _user(['equip.mat', 'equip.wall'], '还有墙'),
      }),
    );
    expect(update.ok, isTrue, reason: '${update.error}');
    expect(update.state.params['equipment']!.turn, 2);
  });

  test('quotes normalize punctuation, whitespace and case, but must exist', () {
    final state = CoachSessionState().appendUserTurn('  Hello，WORLD!  在家。');
    final accepted = params.set(
      state,
      _fields({'scene': _user('home', 'hello WORLD')}),
    );
    expect(accepted.ok, isTrue, reason: '${accepted.error}');
    expect(
      params
          .set(state, _fields({'scene': _user('home', '办公室')}))
          .error!['code'],
      'quote_not_found',
    );
    expect(
      params
          .set(state, _fields({'scene': _user('home', '，。 !')}))
          .error!['code'],
      'invalid_quote',
    );
    expect(
      params
          .set(state, _fields({'scene': _user('home', 'x' * 31)}))
          .error!['code'],
      'invalid_quote',
    );
  });

  test(
    'model cannot claim host, overwrite confirmed values or invent defaults',
    () {
      final host = params.applyHost(
        CoachSessionState(),
        const CoachContext(minutes: 20),
      );
      final state = host.state.appendUserTurn('改为十五分钟');
      expect(
        params
            .set(state, _fields({'minutes': _other(15, 'host')}))
            .error!['code'],
        'invalid_source',
      );
      final keptHost = params.set(
        state,
        _fields({'minutes': _other(15, 'default')}),
      );
      expect(keptHost.ok, isTrue);
      expect(keptHost.kept, {'minutes'});
      expect(keptHost.state.params['minutes']!.value, 20);
      expect(
        params
            .set(
              state,
              _fields({
                'equipment': _other(['equip.mat'], 'default'),
              }),
            )
            .error!['code'],
        'default_equipment',
      );
      final user = params.set(state, _fields({'minutes': _user(15, '十五分钟')}));
      expect(user.ok, isTrue);
      expect(user.state.params['minutes']!.source, 'user');
      expect(user.state.params['minutes']!.value, 15);
      final keptUser = params.set(
        user.state,
        _fields({'minutes': _other(10, 'default')}),
      );
      expect(keptUser.ok, isTrue);
      expect(keptUser.kept, {'minutes'});
      expect(keptUser.state.params['minutes']!.value, 15);
    },
  );

  test('preselect needs an encoded value or a literal memory quote', () {
    final natural = [
      MemoryEntry(MemoryKind.equipment, '家里有瑜伽垫', at: DateTime.utc(2026)),
    ];
    final encoded = [
      MemoryEntry(MemoryKind.equipment, 'equip.mat', at: DateTime.utc(2026)),
    ];
    final request = _fields({
      'equipment': _other(['equip.mat'], 'preselect'),
    });
    expect(
      params.set(CoachSessionState(), request, memory: natural).error!['code'],
      'preselect_not_in_memory',
    );
    expect(
      params.set(CoachSessionState(), request, memory: encoded).error!['code'],
      'equipment_not_newly_confirmed',
    );
    final sceneMemory = [
      MemoryEntry(MemoryKind.scene, 'home', at: DateTime.utc(2026)),
    ];
    expect(
      params
          .set(
            CoachSessionState(),
            _fields({'scene': _other('home', 'preselect')}),
            memory: sceneMemory,
          )
          .ok,
      isTrue,
    );
    final naturalScene = [
      MemoryEntry(MemoryKind.scene, '常在家练', at: DateTime.utc(2026)),
    ];
    final fromQuote = params.set(
      CoachSessionState(),
      _fields({
        'scene': {'value': 'home', 'source': 'preselect', 'quote': '在家'},
      }),
      memory: naturalScene,
    );
    expect(fromQuote.ok, isTrue, reason: '${fromQuote.error}');
    final wrongQuote = params.set(
      CoachSessionState(),
      _fields({
        'scene': {'value': 'home', 'source': 'preselect', 'quote': '办公室'},
      }),
      memory: naturalScene,
    );
    expect(wrongQuote.error!['code'], 'preselect_not_in_memory');
    final user = CoachSessionState().appendUserTurn('我有瑜伽垫');
    expect(
      params
          .set(
            user,
            _fields({
              'equipment': _user(['equip.mat'], '瑜伽垫'),
            }),
          )
          .ok,
      isTrue,
    );
    expect(
      params
          .applyHost(
            CoachSessionState(),
            const CoachContext(equipment: {'mat'}),
          )
          .state
          .params['equipment']!
          .value,
      ['equip.mat'],
    );
  });

  test(
    'host and user protections only grow until host explicitly replaces them',
    () {
      var state = params
          .applyHost(CoachSessionState(), const CoachContext(avoid: {'knee'}))
          .state;
      expect(state.params['limits']!.value, ['limit.knee']);
      state = state.appendUserTurn('我的肩也疼');
      final narrowed = params.set(
        state,
        _fields({
          'limits': _user(['limit.shoulder'], '肩也疼'),
        }),
      );
      expect(narrowed.error!['code'], 'limits_cannot_relax');
      final extended = params.set(
        state,
        _fields({
          'limits': _user(['limit.knee', 'limit.shoulder'], '肩也疼'),
        }),
      );
      expect(extended.ok, isTrue, reason: '${extended.error}');
      expect(
        params
            .applyHost(extended.state, const CoachContext())
            .state
            .params['limits']!
            .value,
        ['limit.knee', 'limit.shoulder'],
      );
      final cleared = params.applyHost(
        extended.state,
        const CoachContext(avoid: {}),
      );
      expect(cleared.state.params['limits']!.source, 'host');
      expect(cleared.state.params['limits']!.value, isEmpty);
    },
  );

  test(
    'unmapped host protection survives user extension and only host can clear it',
    () {
      var state = params
          .applyHost(CoachSessionState(), const CoachContext(avoid: {'特殊限制'}))
          .state;
      final opaque =
          (state.hostValues['limitsOpaque']! as List<Object?>).single as String;
      expect(tags.limitValue(opaque), '特殊限制');
      expect(tags.limitCodes, isNot(contains(opaque)));
      state = state.appendUserTurn('我的肩也疼');
      final extended = params.set(
        state,
        _fields({
          'limits': _user(['limit.shoulder'], '肩也疼'),
        }),
      );
      expect(extended.ok, isTrue, reason: '${extended.error}');
      expect(
        extended.state.params['limits']!.value,
        containsAll(['limit.shoulder', opaque]),
      );
      final restored = CoachSessionState.fromJson(extended.state.toJson());
      expect(restored.hostValues['limitsRaw'], ['特殊限制']);
      expect(restored.params['limits']!.value, contains(opaque));
      final cleared = params.applyHost(restored, const CoachContext(avoid: {}));
      expect(cleared.state.params['limits']!.value, isEmpty);
      expect(cleared.state.hostValues['limitsOpaque'], isEmpty);
    },
  );

  test(
    'a repeated explicit host context is a new write before the next user turn',
    () {
      var state = params
          .applyHost(
            CoachSessionState(),
            const CoachContext(minutes: 20, equipment: {'mat'}),
          )
          .state;
      state = state.appendUserTurn('改为15分钟，我有墙');
      state = params
          .set(
            state,
            _fields({
              'minutes': _user(15, '15分钟'),
              'equipment': _user(['equip.mat', 'equip.wall'], '有墙'),
            }),
          )
          .state;
      expect(state.params['equipment']!.turn, 1);
      final repeatedHost = params.applyHost(
        state,
        const CoachContext(minutes: 20, equipment: {'mat'}),
      );
      expect(repeatedHost.state.params['minutes']!.value, 20);
      expect(repeatedHost.state.params['minutes']!.source, 'host');
      expect(repeatedHost.state.params['equipment']!.value, ['equip.mat']);
      final changedHost = params.applyHost(
        repeatedHost.state,
        const CoachContext(minutes: 25),
      );
      expect(changedHost.state.params['minutes']!.source, 'host');
      expect(changedHost.state.params['minutes']!.value, 25);
    },
  );
  test('an older user quote cannot undo a newer host change', () {
    var state = CoachSessionState().appendUserTurn('先设置15分钟');
    state = params.set(state, _fields({'minutes': _user(15, '15分钟')})).state;
    state = params.applyHost(state, const CoachContext(minutes: 20)).state;
    state = state.appendUserTurn('好的');
    final old = params.set(state, _fields({'minutes': _user(15, '15分钟')}));
    expect(old.error!['code'], 'quote_not_newer_than_host');
    expect(old.state.params['minutes']!.value, 20);
    state = state.appendUserTurn('现在改为15分钟');
    final recent = params.set(state, _fields({'minutes': _user(15, '15分钟')}));
    expect(recent.ok, isTrue, reason: '${recent.error}');
    expect(recent.state.params['minutes']!.value, 15);
  });

  test('an older user quote cannot undo a newer user condition', () {
    var state = CoachSessionState().appendUserTurn('10分钟');
    state = params.set(state, _fields({'minutes': _user(10, '10分钟')})).state;
    state = state.appendUserTurn('20分钟');
    state = params.set(state, _fields({'minutes': _user(20, '20分钟')})).state;
    state = state.appendUserTurn('好的');
    final stale = params.set(state, _fields({'minutes': _user(10, '10分钟')}));
    expect(stale.error!['code'], 'stale_user_quote');
    expect(stale.state.params['minutes']!.value, 20);
  });

  test(
    'existing opaque host equipment may be retained or removed, but not invented',
    () {
      var state = params
          .applyHost(
            CoachSessionState(),
            const CoachContext(equipment: {'特殊器材'}),
          )
          .state;
      final opaque =
          (state.params['equipment']!.value! as List<Object?>).single as String;
      expect(tags.equipmentId(opaque), '特殊器材');
      expect(params.equipmentCodes(state), contains(opaque));
      state = state.appendUserTurn('我还有哑铃');
      final added = params.set(
        state,
        _fields({
          'equipment': _user([opaque, 'equip.dumbbell'], '有哑铃'),
        }),
      );
      expect(added.ok, isTrue, reason: '${added.error}');
      state = added.state.appendUserTurn('不用特殊器材了');
      final removed = params.set(
        state,
        _fields({
          'equipment': _user(['equip.dumbbell'], '不用特殊器材'),
        }),
      );
      expect(removed.ok, isTrue, reason: '${removed.error}');
      expect(params.equipmentCodes(removed.state), isNot(contains(opaque)));
      state = removed.state.appendUserTurn('还有器材');
      final invented = params.set(
        state,
        _fields({
          'equipment': _user(['equip.dumbbell', opaque], '还有器材'),
        }),
      );
      expect(invented.error!['code'], 'invalid_value');
    },
  );
}
