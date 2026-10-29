import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _object(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

List<Object?> _versions(Map<String, Object?> state) =>
    _object(state['plans'])['ext:host-plan']! as List<Object?>;

Map<String, Object?> _plan(Map<String, Object?> state, {int version = 1}) =>
    _object(_object(_versions(state)[version])['plan']);

Map<String, Object?> _firstBlock(Map<String, Object?> state) =>
    _object((_plan(state)['blocks']! as List<Object?>).first);

Map<String, Object?> _firstItem(Map<String, Object?> state) =>
    _object((_firstBlock(state)['items']! as List<Object?>).first);

TrainingPlan _completePlan(int version) => const PlanCodec().decode({
  ...planOf(okEnvelope()),
  'id': 'ext:host-plan',
  'title': 'Plan v$version',
});

CoachSessionState _focusedState() => CoachSessionState(
  activePlanId: 'ext:host-plan',
  focusPlanId: 'ext:host-plan',
  savedRef: const CoachSavedPlanRef(externalId: 'host-plan', baseVersion: 1),
  plans: {
    'ext:host-plan': [
      for (var version = 1; version <= 2; version++)
        CoachPlanVersion(
          version: version,
          plan: _completePlan(version).toJson(),
          estimateSec: version * 60,
          fitLog: const [],
        ),
    ],
  },
);

Map<String, Object?> _snapshotJson() => CoachSessionSnapshot(
  sessionState: _focusedState(),
  ledger: ContextTurnLedger(const []),
).toJson();

void main() {
  test(
    'saved reference is an immutable value with independent exported JSON',
    () {
      const ref = CoachSavedPlanRef(externalId: 'host-plan', baseVersion: 1);
      final restored = CoachSavedPlanRef.fromJson(ref.toJson());
      expect(restored, ref);
      expect(restored.hashCode, ref.hashCode);
      expect(
        restored,
        isNot(const CoachSavedPlanRef(externalId: 'other', baseVersion: 1)),
      );
      final wire = ref.toJson()..['baseVersion'] = 99;
      expect(wire['baseVersion'], 99);
      expect(ref.baseVersion, 1);
    },
  );

  test(
    'session roundtrip retains focus and original saved base across edits',
    () {
      final original = _focusedState();
      final restored = CoachSessionState.fromJson(
        _object(jsonDecode(jsonEncode(original.toJson()))),
      );
      expect(restored.toJson(), original.toJson());
      expect(restored.focusPlanId, 'ext:host-plan');
      expect(restored.savedRef!.baseVersion, 1);
      expect(restored.plans[restored.focusPlanId]!.last.version, 2);
    },
  );

  test('clearing focus preserves active plan and all retained versions', () {
    final original = _focusedState();
    final cleared = original.copyWith(clearPlanFocus: true);
    expect(cleared.focusPlanId, isNull);
    expect(cleared.savedRef, isNull);
    expect(cleared.activePlanId, original.activePlanId);
    expect(cleared.plans, original.plans);
    expect(cleared.toJson().containsKey('focusPlanId'), isFalse);
    expect(cleared.toJson().containsKey('savedRef'), isFalse);
    expect(original.focusPlanId, 'ext:host-plan');
  });

  test('ordinary copyWith preserves focus and allows explicit replacement', () {
    final original = _focusedState();
    expect(original.copyWith(picks: ['a']).savedRef, original.savedRef);
    final replacement = original.copyWith(
      focusPlanId: 'ext:other',
      savedRef: const CoachSavedPlanRef(externalId: 'other', baseVersion: 3),
    );
    expect(replacement.focusPlanId, 'ext:other');
    expect(replacement.savedRef!.baseVersion, 3);
  });

  test('portable snapshot roundtrip keeps focused version and saved base', () {
    final wire = _snapshotJson();
    final restored = CoachSessionSnapshot.fromJson(
      jsonDecode(jsonEncode(wire)),
    );
    expect(restored.isValid, isTrue);
    expect(restored.toJson(), wire);
    expect(restored.sessionState.savedRef!.baseVersion, 1);
    expect(restored.sessionState.plans['ext:host-plan']!.last.version, 2);
  });

  test(
    'old state and portable snapshots omit focus without changing shape',
    () {
      final oldState = _focusedState().copyWith(clearPlanFocus: true);
      final state = CoachSessionState.fromJson(oldState.toJson());
      expect(state.focusPlanId, isNull);
      expect(state.savedRef, isNull);
      expect(state.toJson(), oldState.toJson());
      final snapshot = CoachSessionSnapshot(
        sessionState: oldState,
        ledger: ContextTurnLedger(const []),
      );
      final restored = CoachSessionSnapshot.fromJson(snapshot.toJson());
      expect(restored.isValid, isTrue);
      expect(restored.toJson(), snapshot.toJson());
    },
  );

  final corruptions = <String, void Function(Map<String, Object?>)>{
    'missing referenced plan': (state) => state['plans'] = <String, Object?>{},
    'missing saved reference': (state) => state.remove('savedRef'),
    'saved reference without focus': (state) => state.remove('focusPlanId'),
    'different saved external identity': (state) =>
        _object(state['savedRef'])['externalId'] = 'other',
    'blank external identity': (state) =>
        _object(state['savedRef'])['externalId'] = '  ',
    'nonpositive saved base': (state) =>
        _object(state['savedRef'])['baseVersion'] = 0,
    'nonexistent saved base': (state) =>
        _object(state['savedRef'])['baseVersion'] = 3,
    'invalid saved base type': (state) =>
        _object(state['savedRef'])['baseVersion'] = '1',
    'invalid focus type': (state) => state['focusPlanId'] = 1,
    'mismatched focused plan identity': (state) =>
        _plan(state)['id'] = 'other-plan',
    'missing focused plan identity': (state) => _plan(state).remove('id'),
    'invalid focused title type': (state) => _plan(state)['title'] = 12,
    'blank focused title': (state) => _plan(state)['title'] = ' ',
    'invalid focused blocks type': (state) => _plan(state)['blocks'] = 'bad',
    'empty focused blocks': (state) => _plan(state)['blocks'] = <Object?>[],
    'invalid focused items type': (state) =>
        _firstBlock(state)['items'] = 'bad',
    'empty focused items': (state) => _firstBlock(state)['items'] = <Object?>[],
    'invalid focused dose type': (state) => _firstItem(state)['reps'] = '8',
    'invalid focused mode': (state) => _firstItem(state)['mode'] = 'bad',
    'missing focused dose': (state) => _firstItem(state).remove('reps'),
    'nonpositive focused version': (state) =>
        _object(_versions(state).first)['version'] = 0,
    'duplicate focused version': (state) =>
        _object(_versions(state).last)['version'] = 1,
    'descending focused versions': (state) {
      _object(_versions(state).first)['version'] = 2;
      _object(_versions(state).last)['version'] = 1;
    },
    'invalid retained focused title': (state) =>
        _plan(state, version: 0)['title'] = 12,
  };
  for (final entry in corruptions.entries) {
    test('snapshot rejects ${entry.key}', () {
      final wire = _snapshotJson();
      entry.value(_object(wire['sessionState']));
      final restored = CoachSessionSnapshot.fromJson(wire);
      expect(restored.isValid, isFalse);
      expect(restored.invalidReason, 'invalid_snapshot');
      expect(restored.sessionState.focusPlanId, isNull);
    });
  }

  test('focus snapshot validation does not require a live action catalog', () {
    final wire = _snapshotJson();
    _firstItem(_object(wire['sessionState']))['exerciseId'] = 'not-loaded-here';
    final restored = CoachSessionSnapshot.fromJson(wire);
    expect(restored.isValid, isTrue);
    expect(restored.sessionState.savedRef!.baseVersion, 1);
  });
}
