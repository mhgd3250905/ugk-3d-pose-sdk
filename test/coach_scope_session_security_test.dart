import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support/coach_scope_fixture.dart';

void main() {
  late Catalog catalog;
  late CoachActionScopeManifest manifest;

  setUp(() {
    catalog = coachScopeFixtureCatalog();
    manifest = coachScopeFixtureManifest(catalog);
  });

  CoachConversationController controller({
    FakeLlmClient? client,
    Catalog Function()? provider,
    CoachActionScopeManifest? scopeManifest,
    PlanExecutionTimingCallback? executionTiming,
    int maxSteps = 5,
    bool scoped = true,
  }) {
    final value = CoachConversationController(
      agent: CoachAgent(
        client: client ?? FakeLlmClient(const [], latency: Duration.zero),
        catalog: provider ?? () => catalog,
        profile: coachScopeFixtureProfile,
        scopeManifest: scoped ? scopeManifest ?? manifest : null,
        scopePolicy: scoped ? coachScopeFixturePolicy : null,
        executionTiming: executionTiming,
        enableUserMemory: false,
        maxRequestRetries: 0,
        maxSteps: maxSteps,
      ),
    );
    addTearDown(value.dispose);
    return value;
  }

  TrainingPlan focus(CoachConversationController value) {
    final imported = value.focusExternalPlan(
      externalId: 'saved',
      plan: coachScopeFixturePlan(),
    );
    expect(imported.ok, isTrue, reason: '${imported.errors}');
    final versions = value.agent.sessionState.plans[imported.planId];
    expect(versions, isNotNull);
    expect(versions!, isNotEmpty);
    final decoded = const PlanCodec().decodeStrict(versions.last.plan);
    expect(decoded.ok, isTrue, reason: '${decoded.issues}');
    final plan = decoded.plan!;
    _expectWithin(plan, value.agent.actionScope!.plannableIds);
    return plan;
  }

  test('legal external focus is local, versioned and scope-bound', () {
    final client = FakeLlmClient(const [], latency: Duration.zero);
    final value = controller(client: client);
    var notifications = 0;
    value.addListener(() => notifications++);
    final plan = focus(value);
    expect(plan.id, 'ext:saved');
    expect(value.focus!.version, 1);
    expect(
      value.agent.sessionState.actionScopeIdentity,
      value.agent.actionScope!.identity,
    );
    expect(value.agent.sessionState.activePlanId, plan.id);
    expect(value.agent.sessionState.focusPlanId, plan.id);
    expect(value.agent.sessionState.savedRef!.externalId, 'saved');
    expect(notifications, 1);
    expect(client.requests, isEmpty);
    expect(value.prepareTraining(plan), isNotNull);
    expect(value.agent.canRestorePlan(plan), isTrue);
    expect(
      value.agent.canRestoreSessionSnapshot(value.exportSession()),
      isTrue,
    );
  });

  for (final id in ['outside-a', 'forged-id']) {
    for (final location in ['parent', 'segment', 'replacedFrom']) {
      test('focus rejects $id in $location without state or view mutation', () {
        final client = FakeLlmClient(const [], latency: Duration.zero);
        final value = controller(client: client);
        focus(value);
        final before = _fingerprint(value);
        final first = switch (location) {
          'parent' => coachScopeFixtureItem(id),
          'segment' => coachScopeFixtureItem('inside-a', segment: id),
          _ => coachScopeFixtureItem('inside-a', replacedFrom: id),
        };
        final rejected = value.focusExternalPlan(
          externalId: 'malicious',
          plan: coachScopeFixturePlan(first: first),
        );
        expect(rejected.ok, isFalse);
        expect(rejected.errors, isNotEmpty);
        expect(_fingerprint(value), before);
        expect(client.requests, isEmpty);
        expect(
          value.agent.sessionState.plans.containsKey('ext:malicious'),
          isFalse,
        );
        expect(
          value.prepareTraining(coachScopeFixturePlan(first: first)),
          isNull,
        );
        expect(
          value.agent.canRestorePlan(coachScopeFixturePlan(first: first)),
          isFalse,
        );
      });
    }
  }

  test('same IDs with a forged planning dose fail during initialization', () {
    final forged = coachScopeFixtureCatalog(insideSeconds: 91);
    expect(forged.ids.toSet(), catalog.ids.toSet());
    expect(
      () => controller(provider: () => forged),
      throwsA(
        isA<CoachActionScopeConfigurationException>().having(
          (error) => error.code,
          'code',
          'planning_catalog_changed',
        ),
      ),
    );
  });

  test(
    'provider semantic changes fail at runtime without changing session',
    () {
      var provided = catalog;
      final value = controller(provider: () => provided);
      final plan = focus(value);
      final before = jsonEncode(value.agent.sessionState.toJson());
      provided = coachScopeFixtureCatalog(insideSeconds: 91);
      expect(
        () => value.agent.actionScope,
        throwsA(isA<CoachActionScopeConfigurationException>()),
      );
      expect(
        () => value.prepareTraining(plan),
        throwsA(isA<CoachActionScopeConfigurationException>()),
      );
      expect(jsonEncode(value.agent.sessionState.toJson()), before);
      provided = catalog;
    },
  );

  test('export and restore retain focus, versions, provenance and scope', () {
    final source = controller();
    final plan = focus(source);
    final exported = CoachSessionSnapshot.fromJson(
      source.exportSession().toJson(),
    );
    expect(exported.isValid, isTrue);
    final target = controller();
    target.restoreSession(exported, source.state.messages);
    expect(target.focus!.toJson(), source.focus!.toJson());
    expect(
      target.agent.sessionState.actionScopeIdentity,
      source.agent.sessionState.actionScopeIdentity,
    );
    final versions = target.agent.sessionState.plans[plan.id];
    expect(versions, isNotNull);
    expect(versions!, isNotEmpty);
    expect(versions.single.version, 1);
    final restored = const PlanCodec().decodeStrict(versions.single.plan);
    expect(restored.ok, isTrue);
    _expectWithin(restored.plan!, target.agent.actionScope!.plannableIds);
    expect(target.prepareTraining(restored.plan!), isNotNull);
  });

  test('cross-scope snapshot cannot replace an existing focused session', () {
    final source = controller();
    focus(source);
    final snapshot = source.exportSession();
    final target = controller(
      scopeManifest: coachScopeFixtureManifest(
        catalog,
        ids: [...coachScopeFixtureIds, 'outside-a'],
      ),
    );
    focus(target);
    final before = _fingerprint(target);
    expect(target.agent.canRestoreSessionSnapshot(snapshot), isFalse);
    expect(target.agent.restoreSessionSnapshot(snapshot), isFalse);
    target.restoreSession(snapshot, const []);
    expect(_fingerprint(target), before);
  });

  for (final attack in [
    'pendingSearchIds',
    'candidateRows',
    'ledgerRows',
    'recommendations',
    'picks',
    'seenActionIds',
  ]) {
    test('snapshot rejects foreign $attack before replacing live state', () {
      final source = controller();
      focus(source);
      final snapshot = source.exportSession();
      var state = snapshot.sessionState;
      var ledger = snapshot.ledger;
      var candidates = snapshot.candidates;
      var recommendations = snapshot.recommendations;
      switch (attack) {
        case 'pendingSearchIds':
          state = state.copyWith(
            pendingSearchTurn: 1,
            pendingSearchIds: {'outside-a'},
          );
        case 'candidateRows':
          candidates = [
            ['outside-a', '外部动作'],
          ];
        case 'ledgerRows':
          ledger = ContextTurnLedger.fromJson({
            'turns': [
              {
                'turn': 1,
                'userText': '测试',
                'finalDeliveryText': '',
                'params': <String, Object?>{},
                'picks': <String>[],
                'candidates': [
                  ['outside-a', '外部动作'],
                ],
                'seenActionIds': <String>[],
                'loadedSkillNames': <String>[],
                'outcome': 'text',
              },
            ],
          });
          state = state.copyWith(completedContextLedger: ledger.toJson());
        case 'recommendations':
          recommendations = [
            CoachRecommendationSnapshot(
              messageId: 'foreign',
              actionIds: ['outside-a'],
              note: '伪造推荐',
            ),
          ];
        case 'picks':
          state = state.copyWith(picks: ['outside-a']);
        case 'seenActionIds':
          state = state.copyWith(seenActionIds: {'outside-a'});
      }
      final forged = _snapshot(
        snapshot,
        state: state,
        ledger: ledger,
        candidates: candidates,
        recommendations: recommendations,
      );
      final target = controller();
      focus(target);
      final before = _fingerprint(target);
      expect(target.agent.canRestoreSessionSnapshot(forged), isFalse);
      expect(target.agent.restoreSessionSnapshot(forged), isFalse);
      expect(_fingerprint(target), before);
    });
  }

  test(
    'restored substitution records bind literal source and actual adopted ID',
    () {
      final source = controller();
      final plan = focus(source);
      final snapshot = _withSubstitution(source, source.exportSession(), plan);
      expect(source.agent.canRestoreSessionSnapshot(snapshot), isTrue);
      final target = controller();
      expect(target.agent.restoreSessionSnapshot(snapshot), isTrue);
      expect(target.agent.scopeRecords, hasLength(1));
      final record = target.agent.scopeRecords.single;
      expect(record.originalText, '做外部内侧伸展，练五分钟');
      expect(record.sourceId, 'outside-a');
      expect(record.adoptedActionId, 'inside-a');
      expect(record.planId, plan.id);
      expect(record.planVersion, 1);
      _expectWithin(plan, target.agent.actionScope!.plannableIds);
    },
  );

  test(
    'host safety change invalidates assessment but retains restorable scope audit',
    () {
      catalog = coachScopeFixtureCatalog(cautions: ['膝']);
      manifest = coachScopeFixtureManifest(catalog);
      final value = controller();
      final plan = focus(value);
      final initial = _withSubstitution(value, value.exportSession(), plan);
      expect(value.agent.restoreSessionSnapshot(initial), isTrue);
      expect(value.agent.sessionState.scopeAssessmentTurn, 1);
      expect(value.agent.scopeRecords, hasLength(1));
      expect(
        value.agent.scopeRecords.single.kind,
        CoachScopeDecisionKind.substituted,
      );
      value.agent.replaceSafetyAvoid({'膝'});
      final updated = value.agent.sessionState;
      expect(updated.scopeAssessmentTurn, isNull);
      expect(value.agent.scopeRecords, isEmpty);
      expect(updated.scopeDecisionRecords, hasLength(1));
      final historical = updated.scopeDecisionRecords.single;
      expect(historical['superseded'], isTrue);
      expect(historical['sourceId'], 'outside-a');
      expect(historical['adoptedActionId'], 'inside-a');
      expect(historical['planId'], plan.id);
      expect(historical['planVersion'], 1);
      final exported = CoachSessionSnapshot.fromJson(
        value.exportSession().toJson(),
      );
      expect(exported.isValid, isTrue);
      expect(value.agent.canRestoreSessionSnapshot(exported), isTrue);
      final target = controller();
      expect(target.agent.restoreSessionSnapshot(exported), isTrue);
      expect(target.agent.sessionState.scopeAssessmentTurn, isNull);
      expect(target.agent.sessionState.scopeDecisionRecords.single, historical);
      expect(target.agent.scopeRecords, isEmpty);
      final versions = target.agent.sessionState.plans[plan.id];
      expect(versions, isNotNull);
      expect(versions!, isNotEmpty);
      final restored = const PlanCodec().decodeStrict(versions.last.plan);
      expect(restored.ok, isTrue);
      _expectWithin(restored.plan!, target.agent.actionScope!.plannableIds);
    },
  );

  for (final clearAssessment in [false, true]) {
    test(
      'removing scope records${clearAssessment ? ' and assessment' : ''} cannot erase disclosure',
      () {
        final value = controller();
        final plan = focus(value);
        final snapshot = _withSubstitution(value, value.exportSession(), plan);
        final forged = _snapshot(
          snapshot,
          state: snapshot.sessionState.copyWith(
            scopeDecisionRecords: const [],
            clearScopeAssessment: clearAssessment,
          ),
        );
        final before = _fingerprint(value);
        expect(value.agent.canRestoreSessionSnapshot(forged), isFalse);
        expect(value.agent.restoreSessionSnapshot(forged), isFalse);
        expect(_fingerprint(value), before);
      },
    );
  }

  test('forged inScope kind cannot suppress an outside source disclosure', () {
    final value = controller();
    final plan = focus(value);
    final snapshot = _withSubstitution(value, value.exportSession(), plan);
    final records = [
      for (final record in snapshot.sessionState.scopeDecisionRecords)
        {
          ...record,
          'kind': 'inScope',
          'adoptedActionId': null,
          'requiresReplan': false,
          'allowPlan': true,
        },
    ];
    final forged = _snapshot(
      snapshot,
      state: snapshot.sessionState.copyWith(scopeDecisionRecords: records),
    );
    expect(value.agent.canRestoreSessionSnapshot(forged), isFalse);
  });

  for (final binding in ['missingPlan', 'missingVersion', 'missingAdopted']) {
    test('scope record cannot restore with $binding binding', () {
      final value = controller();
      final plan = focus(value);
      final snapshot = _withSubstitution(value, value.exportSession(), plan);
      var state = snapshot.sessionState;
      if (binding == 'missingAdopted') {
        final versions = state.plans[plan.id]!;
        final changed = coachScopeFixturePlan(
          id: plan.id,
          first: coachScopeFixtureItem('inside-b'),
        );
        state = state.copyWith(
          plans: {
            ...state.plans,
            plan.id: [
              CoachPlanVersion(
                version: versions.single.version,
                plan: changed.toJson(),
                estimateSec: 310,
                fitLog: const [],
              ),
            ],
          },
        );
      } else {
        state = state.copyWith(
          scopeDecisionRecords: [
            for (final record in state.scopeDecisionRecords)
              {
                ...record,
                if (binding == 'missingPlan') 'planId': 'nonexistent-plan',
                if (binding == 'missingVersion') 'planVersion': 99,
              },
          ],
        );
      }
      final forged = _snapshot(snapshot, state: state);
      expect(value.agent.canRestoreSessionSnapshot(forged), isFalse);
      final before = _fingerprint(value);
      expect(value.agent.restoreSessionSnapshot(forged), isFalse);
      expect(_fingerprint(value), before);
    });
  }

  for (final attack in ['duplicate', 'descending', 'zero', 'mismatched-id']) {
    test(
      'non-focus model plan rejects $attack version history transactionally',
      () {
        final value = controller();
        final focused = focus(value);
        final original = _withSubstitution(
          value,
          value.exportSession(),
          focused,
        );
        final plan = coachScopeFixturePlan(
          id: 'model-plan',
        ).copyWith(source: 'ai');
        final withoutAdopted = coachScopeFixturePlan(
          id: plan.id,
          first: coachScopeFixtureItem('inside-b'),
        ).copyWith(source: 'ai');
        CoachPlanVersion version(int number, TrainingPlan contents) =>
            CoachPlanVersion(
              version: number,
              plan: contents.toJson(),
              estimateSec: const PlanDuration().estimateSeconds(
                contents,
                catalog,
              ),
              fitLog: const [],
              createdAtTurn: 1,
            );
        final versions = switch (attack) {
          'duplicate' => [version(1, plan), version(1, withoutAdopted)],
          'descending' => [version(2, plan), version(1, plan)],
          'zero' => [version(0, plan)],
          _ => [version(1, plan.copyWith(id: 'another-model-plan'))],
        };
        final state = original.sessionState.copyWith(
          clearPlanFocus: true,
          activePlanId: plan.id,
          plans: {plan.id: versions},
          scopeDecisionRecords: [
            for (final record in original.sessionState.scopeDecisionRecords)
              {
                ...record,
                'planId': plan.id,
                'planVersion': attack == 'zero' ? 0 : 1,
              },
          ],
        );
        final forged = _snapshot(original, state: state);
        expect(forged.sessionState.focusPlanId, isNull);
        expect(forged.sessionState.savedRef, isNull);
        expect(forged.sessionState.plans[plan.id], isNotEmpty);
        final before = _fingerprint(value);
        expect(value.agent.canRestoreSessionSnapshot(forged), isFalse);
        expect(value.agent.restoreSessionSnapshot(forged), isFalse);
        expect(_fingerprint(value), before);
      },
    );
  }

  test(
    'non-focus model history accepts distinct ascending immutable versions',
    () {
      final value = controller();
      final focused = focus(value);
      final original = _withSubstitution(value, value.exportSession(), focused);
      final first = coachScopeFixturePlan(
        id: 'model-plan',
      ).copyWith(source: 'ai');
      final second = coachScopeFixturePlan(
        id: first.id,
        first: coachScopeFixtureItem('inside-a', seconds: 81),
      ).copyWith(source: 'ai');
      final state = original.sessionState.copyWith(
        clearPlanFocus: true,
        activePlanId: first.id,
        plans: {
          first.id: [
            for (final entry in [first, second].indexed)
              CoachPlanVersion(
                version: entry.$1 + 1,
                plan: entry.$2.toJson(),
                estimateSec: const PlanDuration().estimateSeconds(
                  entry.$2,
                  catalog,
                ),
                fitLog: const [],
                createdAtTurn: 1,
              ),
          ],
        },
        scopeDecisionRecords: [
          for (final record in original.sessionState.scopeDecisionRecords)
            {...record, 'planId': first.id, 'planVersion': 1},
        ],
      );
      final snapshot = _snapshot(original, state: state);
      final target = controller();
      expect(target.agent.canRestoreSessionSnapshot(snapshot), isTrue);
      expect(target.agent.restoreSessionSnapshot(snapshot), isTrue);
      final versions = target.agent.sessionState.plans[first.id];
      expect(versions, isNotNull);
      expect(versions!, hasLength(2));
      final decoded = const PlanCodec().decodeStrict(versions.last.plan);
      expect(decoded.ok, isTrue);
      _expectWithin(decoded.plan!, target.agent.actionScope!.plannableIds);
      expect(target.agent.scopeRecords.single.planVersion, 1);
      expect(versions.last.version, 2);
    },
  );

  for (final restoration in const [
    (snapshot: false, outer: false),
    (snapshot: false, outer: true),
    (snapshot: true, outer: false),
  ]) {
    final viaSnapshot = restoration.snapshot;
    final outerState = restoration.outer;
    test(
      'confirmed mat context restores ${viaSnapshot ? 'snapshot' : 'history'} '
      'from ${outerState ? 'outer' : 'message'} plan state',
      () {
        catalog = coachScopeFixtureCatalog(equipment: ['mat']);
        manifest = coachScopeFixtureManifest(catalog);
        const context = CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 5,
          level: 1,
          goal: 'relax',
        );
        final plan = coachScopeFixturePlan(equipment: ['mat']);
        final source = controller();
        final imported = source.focusExternalPlan(
          externalId: 'mat-plan',
          plan: plan,
        );
        expect(imported.ok, isTrue, reason: '${imported.errors}');
        final focusedId = imported.planId!;
        final focused = plan.copyWith(id: focusedId);
        final admitted = source.prepareTraining(focused, context: context);
        expect(admitted, isNotNull);
        _expectWithin(admitted!.plan, source.agent.actionScope!.plannableIds);
        final stored = CoachPlanState(
          planId: focusedId,
          context: context,
          sessionState: source.agent.sessionState,
        );
        final message = CoachConversationMessage(
          id: 'mat-card',
          at: DateTime.utc(2026),
          plan: admitted,
          planState: outerState ? null : stored,
        );
        final target = controller();
        if (viaSnapshot) {
          // restoreSession does not have an outer planState argument.
          final withStored = CoachConversationMessage(
            id: message.id,
            at: message.at,
            plan: admitted,
            planState: stored,
          );
          target.restoreSession(source.exportSession(), [withStored]);
        } else {
          target.restoreHistory([
            message,
          ], planState: outerState ? stored : null);
        }
        expect(target.state.admittedPlans, isNotEmpty);
        final restored = target.state.admittedPlans.single.plan;
        _expectWithin(restored, target.agent.actionScope!.plannableIds);
        expect(restored.equipment, ['mat']);
        expect(target.prepareTraining(restored, context: context), isNotNull);
      },
    );
  }

  test(
    'restored confirmed equipment cannot clear newer safety before playback',
    () {
      final raw =
          jsonDecode(
                jsonEncode(
                  coachScopeFixtureCatalog(
                    equipment: ['mat'],
                    cautions: ['膝'],
                  ).toJson(),
                ),
              )
              as Map<String, dynamic>;
      ((raw['drills'] as List).first as Map<String, dynamic>)['cautions'] = [
        '膝',
      ];
      catalog = Catalog.fromJson(raw);
      manifest = coachScopeFixtureManifest(catalog);
      const confirmed = CoachContext(
        scene: 'home',
        equipment: {'mat'},
        minutes: 5,
        level: 1,
        goal: 'relax',
      );
      final plan = coachScopeFixturePlan(equipment: ['mat']);
      final source = controller();
      final admitted = source.prepareTraining(plan, context: confirmed);
      expect(admitted, isNotNull);
      _expectWithin(admitted!.plan, source.agent.actionScope!.plannableIds);
      final client = FakeLlmClient(const [], latency: Duration.zero);
      final target = controller(client: client);
      target.restoreHistory([
        CoachConversationMessage(
          id: 'mat-old-safety',
          at: DateTime.utc(2026),
          plan: admitted,
          planState: CoachPlanState(planId: plan.id, context: confirmed),
        ),
      ]);
      expect(target.state.admittedPlans, isNotEmpty);
      _expectWithin(
        target.state.admittedPlans.single.plan,
        target.agent.actionScope!.plannableIds,
      );
      target.agent.replaceSafetyAvoid({'膝'});
      final before = _fingerprint(target);
      expect(
        target.prepareTraining(plan, context: confirmed.copyWith(avoid: {})),
        isNull,
        reason:
            'saved equipment and empty caller avoid cannot erase current protection',
      );
      expect(_fingerprint(target), before);
      expect(client.requests, isEmpty);
    },
  );

  test('legacy history accepts a real nonempty scoped plan', () {
    final value = controller();
    final admitted = ToolGate(
      catalog: catalog,
      profile: coachScopeFixtureProfile,
    ).admitTemplate(coachScopeFixturePlan());
    expect(admitted, isNotNull);
    _expectWithin(admitted!.plan, coachScopeFixtureIds);
    value.restoreHistory([_planMessage(admitted)]);
    expect(value.state.admittedPlans, hasLength(1));
    final current = value.agent.sessionState.activePlanId;
    expect(current, admitted.plan.id);
    final versions = value.agent.sessionState.plans[current];
    expect(versions, isNotNull);
    expect(versions!, isNotEmpty);
    _expectWithin(
      const PlanCodec().decodeStrict(versions.last.plan).plan!,
      coachScopeFixtureIds,
    );
  });

  test(
    'full-catalog ValidatedPlan capability cannot bypass scoped history',
    () {
      final value = controller();
      focus(value);
      final admitted =
          ToolGate(
            catalog: catalog,
            profile: coachScopeFixtureProfile,
          ).admitTemplate(
            coachScopeFixturePlan(first: coachScopeFixtureItem('outside-a')),
          );
      expect(admitted, isNotNull);
      expect(admitted!.plan.items, isNotEmpty);
      expect(admitted.plan.exerciseIds, contains('outside-a'));
      final before = _fingerprint(value);
      expect(
        () => value.restoreHistory([_planMessage(admitted)]),
        throwsA(isA<FormatException>()),
      );
      expect(_fingerprint(value), before);
    },
  );

  test(
    'full-catalog ValidatedActions capability cannot bypass scoped history',
    () {
      final value = controller();
      focus(value);
      final result =
          ToolGate(catalog: catalog, profile: coachScopeFixtureProfile).check(
            '',
            [
              LlmToolCall(
                id: 'full-catalog',
                name: CoachTools.showActions,
                arguments: jsonEncode({
                  'items': [
                    {'actionId': 'outside-a'},
                  ],
                }),
              ),
            ],
          );
      expect(result.ok, isTrue, reason: '${result.errors}');
      expect(result.actions, isNotNull);
      expect(result.actions!.items, isNotEmpty);
      expect(result.actions!.items.single.id, 'outside-a');
      final before = _fingerprint(value);
      expect(
        () => value.restoreHistory([
          CoachConversationMessage(
            id: 'foreign-actions',
            at: DateTime.utc(2026),
            actions: result.actions,
          ),
        ]),
        throwsA(isA<FormatException>()),
      );
      expect(_fingerprint(value), before);
    },
  );

  test(
    'history accepts nonempty recommendations from the current scoped catalog',
    () {
      final value = controller();
      final result =
          ToolGate(
            catalog: value.agent.actionScope!.catalog,
            profile: value.agent.profile,
          ).check('', [
            _call('current-actions', CoachTools.showActions, {
              'items': [
                {'actionId': 'inside-a'},
              ],
            }),
          ]);
      expect(result.ok, isTrue, reason: '${result.errors}');
      expect(result.actions, isNotNull);
      expect(result.actions!.items, isNotEmpty);
      expect(
        result.actions!.items
            .map((item) => item.id)
            .toSet()
            .difference(coachScopeFixtureIds),
        isEmpty,
      );
      value.restoreHistory([
        CoachConversationMessage(
          id: 'current-actions',
          at: DateTime.utc(2026),
          actions: result.actions,
        ),
      ]);
      expect(value.state.messages, hasLength(1));
      final restored = value.state.messages.single.actions;
      expect(restored, isNotNull);
      expect(restored!.items, isNotEmpty);
      expect(restored.items.single.drill.name.of('zh'), '内侧放松');
    },
  );

  test(
    'legacy plan state cannot import foreign search IDs behind a legal card',
    () {
      final value = controller();
      final plan = focus(value);
      final admitted = value.prepareTraining(plan);
      expect(admitted, isNotNull);
      _expectWithin(admitted!.plan, coachScopeFixtureIds);
      final state = CoachPlanState(
        planId: plan.id,
        sessionState: value.agent.sessionState.copyWith(
          pendingSearchTurn: 1,
          pendingSearchIds: {'outside-a'},
        ),
      );
      expect(value.agent.canRestorePlan(plan, planState: state), isFalse);
      final before = _fingerprint(value);
      expect(
        () => value.restoreHistory([_planMessage(admitted)], planState: state),
        throwsA(isA<FormatException>()),
      );
      expect(_fingerprint(value), before);
    },
  );

  test(
    'validated in-scope ID cannot carry foreign action metadata into history',
    () {
      final raw =
          jsonDecode(jsonEncode(catalog.toJson())) as Map<String, dynamic>;
      final rows = raw['drills'] as List;
      final first = rows.first as Map<String, dynamic>;
      first['relatedActionIds'] = ['outside-a'];
      first['name'] = {'zh': '伪造的目录动作名称'};
      final fullCatalog = Catalog.fromJson(raw);
      final result =
          ToolGate(
            catalog: fullCatalog,
            profile: coachScopeFixtureProfile,
          ).check('', [
            _call('forged-metadata', CoachTools.showActions, {
              'items': [
                {'actionId': 'inside-a'},
              ],
            }),
          ]);
      expect(result.ok, isTrue, reason: '${result.errors}');
      expect(result.actions, isNotNull);
      expect(result.actions!.items, isNotEmpty);
      expect(result.actions!.items.single.drill.raw['relatedActionIds'], [
        'outside-a',
      ]);
      final value = controller();
      focus(value);
      final before = _fingerprint(value);
      expect(
        () => value.restoreHistory([
          CoachConversationMessage(
            id: 'forged-metadata',
            at: DateTime.utc(2026),
            actions: result.actions,
          ),
        ]),
        throwsA(isA<FormatException>()),
      );
      expect(_fingerprint(value), before);
    },
  );

  test('history normalizes forged names to current scoped action metadata', () {
    final raw =
        jsonDecode(jsonEncode(catalog.toJson())) as Map<String, dynamic>;
    final first = (raw['drills'] as List).first as Map<String, dynamic>;
    first['name'] = {'zh': '伪造的目录动作名称'};
    final result =
        ToolGate(
          catalog: Catalog.fromJson(raw),
          profile: coachScopeFixtureProfile,
        ).check('', [
          _call('forged-name', CoachTools.showActions, {
            'items': [
              {'actionId': 'inside-a'},
            ],
          }),
        ]);
    expect(result.ok, isTrue, reason: '${result.errors}');
    expect(result.actions, isNotNull);
    expect(result.actions!.items, isNotEmpty);
    expect(result.actions!.items.single.drill.name.of('zh'), '伪造的目录动作名称');
    final client = FakeLlmClient(const [], latency: Duration.zero);
    final value = controller(client: client);
    value.restoreHistory([
      CoachConversationMessage(
        id: 'forged-name',
        at: DateTime.utc(2026),
        actions: result.actions,
      ),
    ]);
    expect(value.state.messages, hasLength(1));
    final actions = value.state.messages.single.actions;
    expect(actions, isNotNull);
    expect(actions!.items, isNotEmpty);
    expect(
      actions.items
          .map((item) => item.id)
          .toSet()
          .difference(value.agent.actionScope!.plannableIds),
      isEmpty,
    );
    expect(actions.items.single.drill.name.of('zh'), '内侧放松');
    expect(result.actions!.items.single.drill.name.of('zh'), '伪造的目录动作名称');
    expect(client.requests, isEmpty);
  });

  test(
    'scoped gate cannot turn a caller-supplied full catalogue into authority',
    () {
      final value = controller();
      final gate = value.agent.gateFor(catalog);
      expect(
        gate.admitTemplate(
          coachScopeFixturePlan(first: coachScopeFixtureItem('outside-a')),
        ),
        isNull,
      );
      final legal = gate.admitTemplate(coachScopeFixturePlan());
      expect(legal, isNotNull);
      _expectWithin(legal!.plan, value.agent.actionScope!.plannableIds);
    },
  );

  test(
    'prepareTraining rejects card 326 / executed 335 without fitting or mutation',
    () {
      final client = FakeLlmClient(const [], latency: Duration.zero);
      final value = controller(
        client: client,
        executionTiming: (plan) => coachScopeFixtureTiming(plan, seconds: 335),
      );
      final plan = coachScopeFixturePlan(
        first: coachScopeFixtureItem('inside-a', seconds: 106),
      );
      _expectWithin(plan, value.agent.actionScope!.plannableIds);
      expect(const PlanDuration().estimateSeconds(plan, catalog), 326);
      final before = _fingerprint(value);
      expect(value.prepareTraining(plan), isNull);
      expect(_fingerprint(value), before);
      expect(client.requests, isEmpty);
    },
  );

  test(
    'manual counting remains an estimate and never bypasses execution gate',
    () {
      var seconds = 335.0;
      final value = controller(
        executionTiming: (plan) =>
            coachScopeFixtureTiming(plan, seconds: seconds, manual: true),
      );
      final plan = coachScopeFixturePlan();
      expect(const PlanDuration().estimateSeconds(plan, catalog), 300);
      expect(value.prepareTraining(plan), isNull);
      seconds = 300;
      final accepted = value.prepareTraining(plan);
      expect(accepted, isNotNull);
      _expectWithin(accepted!.plan, value.agent.actionScope!.plannableIds);
    },
  );

  for (final seconds in [270.0, 330.0]) {
    test(
      'prepareTraining accepts actual timeline at inclusive $seconds boundary',
      () {
        final value = controller(
          executionTiming: (plan) =>
              coachScopeFixtureTiming(plan, seconds: seconds),
        );
        final accepted = value.prepareTraining(coachScopeFixturePlan());
        expect(accepted, isNotNull);
        _expectWithin(accepted!.plan, value.agent.actionScope!.plannableIds);
      },
    );
  }

  test(
    'prepareTraining rejects card outside tolerance despite valid execution',
    () {
      final value = controller(
        executionTiming: (plan) => coachScopeFixtureTiming(plan),
      );
      final plan = coachScopeFixturePlan(
        first: coachScopeFixtureItem('inside-a', seconds: 49),
      );
      expect(const PlanDuration().estimateSeconds(plan, catalog), 269);
      expect(value.prepareTraining(plan), isNull);
    },
  );

  test(
    'prepareTraining fails closed when execution callback throws or is invalid',
    () {
      var throws = true;
      final value = controller(
        executionTiming: (plan) {
          if (throws) throw StateError('host secret');
          return coachScopeFixtureTiming(plan, seconds: double.nan);
        },
      );
      expect(value.prepareTraining(coachScopeFixturePlan()), isNull);
      throws = false;
      expect(value.prepareTraining(coachScopeFixturePlan()), isNull);
    },
  );

  test(
    'show refit commits scope record to delivered v2 while preserving 10-minute v1',
    () async {
      const input = '在家徒手拉伸10分钟，改成5分钟';
      late CoachConversationController value;
      late String planId;
      late Map<String, Object?> originalVersion;
      Map<String, Object?> withoutCheck(CoachPlanVersion version) =>
          {...version.toJson()}..remove('check');
      final client = FakeLlmClient([
        _calls([
          _call('start', AgentTools.startTask, {'type': 'plan'}),
          _call('ten-minutes', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
              'goal': {
                'value': ['purpose.stretch'],
                'source': 'user',
                'quote': '拉伸',
              },
              'minutes': {'value': 10, 'source': 'user', 'quote': '10分钟'},
            },
            'scope_request': {'quote': input, 'targetBodyCodes': <String>[]},
          }),
          _call('search', AgentTools.searchActions, {
            'tags': <String>[],
            'limit': 20,
          }),
          _call('ten-minute-draft', AgentTools.draftPlan, {
            'title': '髋臀放松',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  for (final id in coachScopeFixtureIds) {'id': id},
                ],
              },
            ],
          }),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'ten-minutes')['ok'], isTrue);
          final draft = _receipt(request, 'ten-minute-draft');
          expect(draft['ok'], isTrue, reason: '$draft');
          planId = draft['plan_id']! as String;
          final versions = value.agent.sessionState.plans[planId];
          expect(versions, isNotNull);
          expect(versions!, hasLength(1));
          expect(versions.single.version, 1);
          final decoded = const PlanCodec().decodeStrict(versions.single.plan);
          expect(decoded.ok, isTrue);
          _expectWithin(decoded.plan!, value.agent.actionScope!.plannableIds);
          expect(decoded.plan!.targetMinutes, 10);
          expect(versions.single.estimateSec, inInclusiveRange(540, 660));
          originalVersion = withoutCheck(versions.single);
          expect(value.agent.scopeRecords, isNotEmpty);
          expect(
            value.agent.scopeRecords.single.kind,
            CoachScopeDecisionKind.inScope,
          );
          expect(value.agent.scopeRecords.single.planVersion, 1);
          return _calls([
            _call('five-minutes', AgentTools.setParams, {
              'fields': {
                'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
              },
            }),
          ]);
        },
        (LlmRequest request) {
          expect(_receipt(request, 'five-minutes')['ok'], isTrue);
          final versions = value.agent.sessionState.plans[planId];
          expect(versions, isNotNull);
          expect(versions!, hasLength(1));
          expect(withoutCheck(versions.single), originalVersion);
          expect(value.agent.sessionState.params['minutes']!.value, 5);
          return _calls([
            _call('refit-show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '按五分钟安排，量力而行。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      value = controller(client: client);
      final result = await value.send(input);
      expect(result, isNotNull);
      expect(result!.status, TurnStatus.ok);
      expect(result.plan, isNotNull);
      final delivered = result.plan!;
      _expectWithin(delivered.plan, value.agent.actionScope!.plannableIds);
      expect(delivered.plan.id, planId);
      expect(delivered.plan.targetMinutes, 5);
      expect(delivered.version, 2);
      final versions = value.agent.sessionState.plans[planId];
      expect(versions, isNotNull);
      expect(versions!, hasLength(2));
      expect(withoutCheck(versions.first), originalVersion);
      expect(versions.last.version, delivered.version);
      expect(versions.last.plan, delivered.plan.toJson());
      expect(value.agent.scopeRecords, isNotEmpty);
      for (final record in value.agent.scopeRecords) {
        expect(record.planId, planId);
        expect(record.planVersion, delivered.version);
      }
      final snapshot = CoachSessionSnapshot.fromJson(
        value.exportSession().toJson(),
      );
      expect(snapshot.isValid, isTrue);
      expect(value.agent.canRestoreSessionSnapshot(snapshot), isTrue);
      final target = controller();
      expect(target.agent.restoreSessionSnapshot(snapshot), isTrue);
      final restoredVersions = target.agent.sessionState.plans[planId];
      expect(restoredVersions, isNotNull);
      expect(restoredVersions!, hasLength(2));
      expect(withoutCheck(restoredVersions.first), originalVersion);
      final restored = const PlanCodec().decodeStrict(
        restoredVersions.last.plan,
      );
      expect(restored.ok, isTrue);
      _expectWithin(restored.plan!, target.agent.actionScope!.plannableIds);
      expect(restoredVersions.last.version, 2);
      expect(
        target.agent.scopeRecords.every((record) => record.planVersion == 2),
        isTrue,
      );
      expect(client.requests, hasLength(3));
    },
  );

  for (final attack in ['outside-id', 'forged-id', 'segment', 'replacedFrom']) {
    test('illegal $attack draft never enters plans or card output', () async {
      const userText = '在家徒手安排五分钟髋部放松';
      late CoachConversationController value;
      final item = <String, Object?>{
        'id': attack == 'outside-id'
            ? 'outside-a'
            : attack == 'forged-id'
            ? 'forged-id'
            : 'inside-a',
        if (attack == 'segment')
          'segments': [
            {
              'exerciseId': 'outside-a',
              'id': 'foreign-part',
              'mode': 'time',
              'workSeconds': 80,
            },
          ],
        if (attack == 'replacedFrom') 'replacedFrom': 'outside-a',
      };
      final client = FakeLlmClient([
        _calls([
          _call('start', AgentTools.startTask, {'type': 'plan'}),
          _call('assess', AgentTools.setParams, {
            'fields': <String, Object?>{},
            'scope_request': {'quote': userText, 'targetBodyCodes': <String>[]},
          }),
          _call('malicious-draft', AgentTools.draftPlan, {
            'title': '恶意草稿',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  item,
                  {'id': 'inside-b'},
                  {'id': 'inside-c'},
                ],
              },
            ],
          }),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'assess')['ok'], isTrue);
          expect(value.agent.scopeRecords, isNotEmpty);
          final receipt = _receipt(request, 'malicious-draft');
          expect(receipt['ok'], isFalse);
          expect(receipt['code'], 'action_scope_violation');
          expect(value.agent.sessionState.plans, isEmpty);
          expect(value.state.admittedPlans, isEmpty);
          return LlmResponse(content: '只使用本 App 范围内的动作。', model: 'fake');
        },
      ], latency: Duration.zero);
      value = controller(client: client);
      final result = await value.send(
        userText,
        context: const CoachContext(
          scene: 'home',
          equipment: {},
          minutes: 5,
          level: 1,
          goal: 'relax',
        ),
      );
      expect(client.requests, hasLength(2));
      expect(result, isNotNull);
      expect(result!.plan, isNull);
      expect(value.agent.sessionState.plans, isEmpty);
      expect(value.state.admittedPlans, isEmpty);
    });
  }

  for (final kind in [
    CoachScopeDecisionKind.safetyBlocked,
    CoachScopeDecisionKind.insistedUnavailable,
    CoachScopeDecisionKind.lockedConflict,
  ]) {
    test(
      'preset cannot bypass current ${kind.name} refusal after a failed turn',
      () async {
        final input = switch (kind) {
          CoachScopeDecisionKind.safetyBlocked => '髋部疼痛，安排五分钟训练',
          CoachScopeDecisionKind.insistedUnavailable => '我坚持做外部内侧伸展，练五分钟',
          _ => '锁定外部内侧伸展不要替换，练五分钟',
        };
        final extra = switch (kind) {
          CoachScopeDecisionKind.safetyBlocked => <String, Object?>{
            'safetyBlocked': true,
            'safetyReason': '髋部疼痛',
          },
          CoachScopeDecisionKind.insistedUnavailable => <String, Object?>{
            'sourceActionId': 'outside-a',
            'sourceActionName': '外部内侧伸展',
            'sourceQuote': '外部内侧伸展',
            'insists': true,
          },
          _ => <String, Object?>{
            'sourceActionId': 'outside-a',
            'sourceActionName': '外部内侧伸展',
            'sourceQuote': '外部内侧伸展',
            'locked': true,
          },
        };
        final client = FakeLlmClient([
          _calls([
            _call('start', AgentTools.startTask, {
              'type': 'plan',
              'reuse': true,
            }),
            _call('scope', AgentTools.setParams, {
              'fields': <String, Object?>{},
              'scope_request': {
                'quote': input,
                'targetBodyCodes': <String>[],
                ...extra,
              },
            }),
            _call('blocked-draft', AgentTools.draftPlan, {
              'title': '不应交付',
              'blocks': [
                {
                  'kind': 'main',
                  'items': [
                    for (final id in coachScopeFixtureIds) {'id': id},
                  ],
                },
              ],
            }),
          ]),
        ], latency: Duration.zero);
        final value = controller(client: client, maxSteps: 1);
        final preset = focus(value);
        final failed = await value.send(input);
        expect(failed, isNotNull);
        expect(failed!.status, TurnStatus.error);
        expect(failed.isPlanningFailure, isTrue);
        expect(value.agent.scopeRecords, isNotEmpty);
        expect(
          value.agent.scopeRecords.any(
            (record) => record.kind == kind && !record.allowPlan,
          ),
          isTrue,
        );
        final before = _fingerprint(value);
        expect(value.canOfferPreset(preset), isFalse);
        expect(value.agent.canOfferPreset(preset), isFalse);
        expect(value.requestPreset(preset), isNull);
        expect(value.agent.requestPreset(preset), isNull);
        expect(value.prepareTraining(preset), isNull);
        expect(_fingerprint(value), before);
        expect(client.requests, hasLength(1));
      },
    );
  }

  test(
    'clearing host avoid cannot erase a current safety refusal or allow playback',
    () async {
      catalog = coachScopeFixtureCatalog(cautions: ['膝']);
      manifest = coachScopeFixtureManifest(catalog);
      const input = '髋部疼痛，安排五分钟训练';
      final client = FakeLlmClient([
        _calls([
          _call('start', AgentTools.startTask, {'type': 'plan', 'reuse': true}),
          _call('safety', AgentTools.setParams, {
            'fields': <String, Object?>{},
            'scope_request': {
              'quote': input,
              'targetBodyCodes': <String>[],
              'safetyBlocked': true,
              'safetyReason': '髋部疼痛',
            },
          }),
          _call('blocked', AgentTools.draftPlan, {
            'title': '不应开练',
            'blocks': [
              {
                'kind': 'main',
                'items': [
                  for (final id in coachScopeFixtureIds) {'id': id},
                ],
              },
            ],
          }),
        ]),
      ], latency: Duration.zero);
      final value = controller(client: client, maxSteps: 1);
      final preset = focus(value);
      final failed = await value.send(
        input,
        context: const CoachContext(avoid: {'膝'}),
      );
      expect(failed, isNotNull);
      expect(failed!.status, TurnStatus.error);
      expect(failed.isPlanningFailure, isTrue);
      expect(value.agent.sessionState.scopeAssessmentTurn, 1);
      expect(
        value.agent.scopeRecords.any(
          (record) =>
              record.kind == CoachScopeDecisionKind.safetyBlocked &&
              !record.allowPlan,
        ),
        isTrue,
      );
      value.agent.replaceSafetyAvoid({});
      expect(value.agent.sessionState.scopeAssessmentTurn, isNull);
      expect(value.agent.sessionState.params['limits']!.value, isEmpty);
      expect(value.agent.scopeRecords, isNotEmpty);
      expect(
        value.agent.scopeRecords.any(
          (record) =>
              record.kind == CoachScopeDecisionKind.safetyBlocked &&
              !record.allowPlan,
        ),
        isTrue,
      );
      expect(
        value.agent.sessionState.scopeDecisionRecords.any(
          (record) =>
              record['kind'] == 'safetyBlocked' && record['superseded'] != true,
        ),
        isTrue,
      );
      final before = _fingerprint(value);
      expect(value.canOfferPreset(preset), isFalse);
      expect(value.agent.canOfferPreset(preset), isFalse);
      expect(value.requestPreset(preset), isNull);
      expect(value.agent.requestPreset(preset), isNull);
      expect(
        value.prepareTraining(preset, context: const CoachContext(avoid: {})),
        isNull,
      );
      expect(_fingerprint(value), before);
      expect(client.requests, hasLength(1));
      final exported = value.exportSession();
      final target = controller();
      expect(target.agent.restoreSessionSnapshot(exported), isTrue);
      expect(
        target.agent.scopeRecords.any(
          (record) =>
              record.kind == CoachScopeDecisionKind.safetyBlocked &&
              !record.allowPlan,
        ),
        isTrue,
      );
      expect(
        target.prepareTraining(preset, context: const CoachContext(avoid: {})),
        isNull,
      );
    },
  );

  for (final evidence in [
    (quote: '膝盖有不适，做动作会痛，请避免加重疼痛', blocked: true),
    (quote: '膝盖疼痛，做动作会痛', blocked: true),
    (quote: '保护膝盖，目前无不适', blocked: false),
    (quote: '保护膝盖，目前无痛', blocked: false),
    (quote: '保护膝盖，如果疼就停止', blocked: false),
  ]) {
    test(
      'typed user limits pain evidence ${evidence.quote} blocks=${evidence.blocked}',
      () async {
        catalog = coachScopeFixtureCatalog(cautions: ['膝']);
        manifest = coachScopeFixtureManifest(catalog);
        final input = '${evidence.quote}，想练五分钟';
        final client = FakeLlmClient([
          _calls([
            _call('limits', AgentTools.setParams, {
              'fields': {
                'limits': {
                  'value': ['limit.knee'],
                  'source': 'user',
                  'quote': evidence.quote,
                },
              },
              'scope_request': {'quote': input, 'targetBodyCodes': <String>[]},
            }),
          ]),
          (LlmRequest request) {
            expect(_receipt(request, 'limits')['ok'], isTrue);
            return LlmResponse(content: '量力而行。', model: 'fake');
          },
        ], latency: Duration.zero);
        final value = controller(client: client);
        final result = await value.send(input);
        expect(result, isNotNull);
        expect(result!.status, TurnStatus.ok);
        expect(value.agent.sessionState.params['limits']!.source, 'user');
        expect(
          value.agent.sessionState.params['limits']!.quote,
          evidence.quote,
        );
        expect(value.agent.scopeRecords, isNotEmpty);
        expect(
          value.agent.scopeRecords.any(
            (record) => record.kind == CoachScopeDecisionKind.safetyBlocked,
          ),
          evidence.blocked,
        );
        expect(
          value.agent.scopeRecords.every((record) => record.allowPlan),
          !evidence.blocked,
        );
        expect(result.plan, isNull);
        expect(result.actions, isNull);
        expect(client.requests, hasLength(2));
      },
    );
  }

  test(
    'host avoid alone does not invent current user pain or pause scope',
    () async {
      catalog = coachScopeFixtureCatalog(cautions: ['膝']);
      manifest = coachScopeFixtureManifest(catalog);
      const input = '在家徒手安排五分钟';
      final client = FakeLlmClient([
        _calls([
          _call('scope', AgentTools.setParams, {
            'fields': <String, Object?>{},
            'scope_request': {'quote': input, 'targetBodyCodes': <String>[]},
          }),
        ]),
        '量力而行。',
      ], latency: Duration.zero);
      final value = controller(client: client);
      final result = await value.send(
        input,
        context: const CoachContext(avoid: {'膝'}),
      );
      expect(result, isNotNull);
      expect(result!.status, TurnStatus.ok);
      expect(value.agent.sessionState.params['limits']!.value, isNotEmpty);
      expect(value.agent.scopeRecords, isNotEmpty);
      expect(
        value.agent.scopeRecords.every((record) => record.allowPlan),
        isTrue,
      );
      expect(
        value.agent.scopeRecords.any(
          (record) => record.kind == CoachScopeDecisionKind.safetyBlocked,
        ),
        isFalse,
      );
    },
  );

  test(
    'null-scope path retains legacy handling of typed pain limits',
    () async {
      catalog = coachScopeFixtureCatalog(cautions: ['膝']);
      manifest = coachScopeFixtureManifest(catalog);
      const quote = '膝盖有不适，做动作会痛，请避免加重疼痛';
      const input = '$quote，想练五分钟';
      final client = FakeLlmClient([
        _calls([
          _call('limits', AgentTools.setParams, {
            'fields': {
              'limits': {
                'value': ['limit.knee'],
                'source': 'user',
                'quote': quote,
              },
            },
          }),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'limits')['ok'], isTrue);
          return LlmResponse(content: '旧接入方的原有回复。', model: 'fake');
        },
      ], latency: Duration.zero);
      final value = controller(client: client, scoped: false);
      final result = await value.send(input);
      expect(result, isNotNull);
      expect(result!.status, TurnStatus.ok);
      expect(result.text, '旧接入方的原有回复。');
      expect(value.agent.actionScope, isNull);
      expect(value.agent.scopeRecords, isEmpty);
      expect(value.agent.sessionState.params['limits']!.value, ['limit.knee']);
      expect(client.requests, hasLength(2));
    },
  );
}

void _expectWithin(TrainingPlan plan, Set<String> allowed) {
  expect(plan.items, isNotEmpty);
  expect(plan.exerciseIds, isNotEmpty);
  expect(plan.exerciseIds.difference(allowed), isEmpty);
}

String _fingerprint(CoachConversationController value) => jsonEncode({
  'snapshot': value.exportSession().toJson(),
  'focus': value.focus?.toJson(),
  'messages': [
    for (final message in value.state.messages)
      {
        'id': message.id,
        'text': message.text,
        'isUser': message.isUser,
        'plan': message.plan?.plan.toJson(),
        'actions': message.actions?.items.map((item) => item.id).toList(),
      },
  ],
  'history': [
    for (final message in value.agent.history)
      [message.role.name, message.content],
  ],
});

CoachConversationMessage _planMessage(ValidatedPlan plan) =>
    CoachConversationMessage(
      id: 'plan-card',
      at: DateTime.utc(2026),
      plan: plan,
    );

CoachSessionSnapshot _snapshot(
  CoachSessionSnapshot source, {
  CoachSessionState? state,
  ContextTurnLedger? ledger,
  List<Object?>? candidates,
  List<CoachRecommendationSnapshot>? recommendations,
}) => CoachSessionSnapshot(
  sessionState: state ?? source.sessionState,
  ledger: ledger ?? source.ledger,
  pendingQuestion: source.pendingQuestion,
  pendingQuestionMessageId: source.pendingQuestionMessageId,
  candidates: candidates ?? source.candidates,
  recommendations: recommendations ?? source.recommendations,
  loadedSkillNames: source.loadedSkillNames,
  agentState: source.agentState,
);

CoachSessionSnapshot _withSubstitution(
  CoachConversationController controller,
  CoachSessionSnapshot snapshot,
  TrainingPlan plan,
) {
  const text = '做外部内侧伸展，练五分钟';
  final scope = controller.agent.actionScope!;
  final record = scope
      .evaluateRequest(
        CoachScopeRequest(
          originalText: text,
          sourceActionId: 'outside-a',
          sourceActionName: '外部内侧伸展',
          sourceQuote: '外部内侧伸展',
          scene: 'home',
          equipment: {},
          turn: 1,
        ),
        coachScopeFixturePolicy,
      )
      .bindToPlan(plan.id, 1);
  expect(record.kind, CoachScopeDecisionKind.substituted);
  expect(record.adoptedActionId, 'inside-a');
  return _snapshot(
    snapshot,
    state: snapshot.sessionState.copyWith(
      userTurns: const [CoachUserTurn(turn: 1, text: text)],
      scopeAssessmentTurn: 1,
      scopeDecisionRecords: [record.toJson()],
    ),
  );
}

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, Object?> _receipt(LlmRequest request, String id) =>
    (jsonDecode(
              request.messages
                  .lastWhere((message) => message.toolCallId == id)
                  .content,
            )
            as Map)
        .cast<String, Object?>();
