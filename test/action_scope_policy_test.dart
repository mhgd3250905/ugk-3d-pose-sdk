import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/scope/action_scope.dart';

import 'action_scope_manifest_test.dart'
    show
        actionScopeCatalog,
        actionScopeDrill,
        actionScopeManifest,
        actionScopePlan,
        actionScopeProfile;

void main() {
  late CoachActionScope scope;
  late CoachScopeConversationPolicy policy;
  setUp(() {
    final catalog = actionScopeCatalog();
    scope = actionScopeManifest(
      catalog,
    ).restrict(catalog: catalog, profile: actionScopeProfile());
    policy = CoachScopeConversationPolicy(
      specialty: '本 App 专注髋部、臀部和温和拉伸。',
      suggestions: ['温和髋部拉伸', '臀部激活'],
    );
  });

  CoachScopeRequest sourceRequest(
    String id, {
    String? text,
    bool partial = false,
    bool insists = false,
    bool safety = false,
    bool locked = false,
    Set<String>? equipment = const {'mat'},
    Set<String> avoid = const {},
    String scene = 'home',
    CoachSessionState? state,
  }) => CoachScopeRequest(
    originalText: text ?? '我想练$id，5分钟。',
    sourceActionId: id,
    sourceQuote: id,
    scene: scene,
    equipment: equipment,
    avoid: avoid,
    hasInScopeContent: partial,
    insists: insists,
    safetyBlocked: safety,
    locked: locked,
    state: state,
    turn: 3,
  );

  test(
    'R1 partial unavailable action adopts nearest same-body same-scene same-equipment action',
    () {
      final record = scope.evaluateRequest(
        sourceRequest('outside-a', partial: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.substituted);
      expect(record.allowPlan, isTrue);
      expect(record.requiresReplan, isTrue);
      expect(record.sourceId, 'outside-a');
      expect(record.adoptedActionId, 'hip-a');
      expect(record.message, contains('本 App 没有名单外内侧伸展'));
      expect(record.message, contains('用温和内侧伸展练同一部位'));
      final plan = actionScopePlan(record.adoptedActionId!);
      final items = plan.blocks.expand((block) => block.items).toList();
      expect(items, isNotEmpty);
      expect(items.every((item) => scope.contains(item.exerciseId)), isTrue);
      expect(items.any((item) => item.exerciseId == 'outside-a'), isFalse);
      final text = scope.disclosureFor(
        [record],
        plan,
        '计划已准备好。',
        policy: policy,
      );
      expect(text, contains(record.message));
    },
  );

  test('replacement matching does not use display-name keywords', () {
    final catalog = actionScopeCatalog(
      rows: [
        actionScopeDrill('hip-a', name: '看起来像练背的名字'),
        actionScopeDrill('hip-b', name: '名字很像名单外内侧伸展', body: 'hip-flexors'),
        actionScopeDrill('outside-a', name: '名字像脚踝动作'),
      ],
    );
    scope = actionScopeManifest(
      catalog,
      ids: ['hip-a', 'hip-b'],
    ).restrict(catalog: catalog, profile: actionScopeProfile());
    final record = scope.evaluateRequest(sourceRequest('outside-a'), policy);
    expect(record.kind, CoachScopeDecisionKind.substituted);
    expect(record.adoptedActionId, 'hip-a');
    expect(record.candidateIds, isNot(contains('hip-b')));
  });

  test(
    'R2 no compatible substitute removes only the unsupported partial content with disclosure',
    () {
      final record = scope.evaluateRequest(
        sourceRequest('outside-back', partial: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.removed);
      expect(record.adoptedActionId, isNull);
      final plan = actionScopePlan('hip-a');
      expect(plan.blocks.expand((block) => block.items), isNotEmpty);
      expect(
        plan.blocks
            .expand((block) => block.items)
            .every((item) => scope.contains(item.exerciseId)),
        isTrue,
      );
      final text = scope.disclosureFor([record], plan, '', policy: policy);
      expect(text, contains('去掉'));
      expect(text, contains('未覆盖这部分目标'));
      expect(text, contains('名单外背部训练'));
    },
  );

  test(
    'R3 whole request outside app scope refuses a plan and shows specialty plus in-scope suggestions',
    () {
      final record = scope.evaluateRequest(
        sourceRequest('outside-back'),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.outOfScope);
      expect(record.allowPlan, isFalse);
      expect(record.adoptedActionId, isNull);
      final text = scope.disclosureFor(
        [record],
        null,
        '已交付背部计划。',
        policy: policy,
      );
      expect(text, contains(policy.specialty));
      expect(text, contains('温和髋部拉伸'));
      expect(text, isNot(contains('已交付背部计划')));
      expect(
        () => scope.disclosureFor(
          [record],
          actionScopePlan('hip-a'),
          '',
          policy: policy,
        ),
        throwsA(isA<CoachScopeDisclosureException>()),
      );
    },
  );

  test('R4 insistence refuses even when a legitimate substitute exists', () {
    final record = scope.evaluateRequest(
      sourceRequest('outside-a', insists: true),
      policy,
    );
    expect(record.kind, CoachScopeDecisionKind.insistedUnavailable);
    expect(record.allowPlan, isFalse);
    expect(record.adoptedActionId, isNull);
    final text = scope.disclosureFor([record], null, '', policy: policy);
    expect(text, contains('不能把它安排进计划'));
    expect(text, contains(policy.specialty));
    expect(text, contains('可以选择'));
  });

  test(
    'R5 absent outOfScopeGuidance cannot be enabled by a model or restored record',
    () {
      final record = scope.evaluateRequest(
        sourceRequest('outside-back'),
        policy,
      );
      expect(policy.guidanceEnabled, isFalse);
      final tampered = CoachScopeDecisionRecord.fromJson({
        ...record.toJson(),
        'message': '已安排练背，请去其他App。',
        'guidance': '去其他App',
        'suggestions': ['其他App的背部计划'],
      });
      final text = scope.disclosureFor(
        [tampered],
        null,
        '去其他App。',
        policy: policy,
      );
      expect(text, isNot(contains('其他App')));
      expect(text, contains(policy.specialty));
      expect(text, contains('温和髋部拉伸'));
    },
  );

  test('R6 explicitly enabled guidance uses only current configured copy', () {
    final enabled = CoachScopeConversationPolicy(
      specialty: policy.specialty,
      suggestions: policy.suggestions,
      outOfScopeGuidance: '如有需要，可查看已配置的范围外说明。',
    );
    final record = scope.evaluateRequest(
      sourceRequest('outside-back'),
      enabled,
    );
    final text = scope.disclosureFor([record], null, '', policy: enabled);
    expect(text, contains(enabled.outOfScopeGuidance!));
    final disabledText = scope.disclosureFor(
      [record],
      null,
      '',
      policy: policy,
    );
    expect(disabledText, isNot(contains(enabled.outOfScopeGuidance!)));
  });

  test('safety is evaluated before insistence, locks or substitution', () {
    final record = scope.evaluateRequest(
      sourceRequest(
        'outside-a',
        partial: true,
        insists: true,
        safety: true,
        locked: true,
      ),
      policy,
    );
    expect(record.kind, CoachScopeDecisionKind.safetyBlocked);
    expect(record.allowPlan, isFalse);
    expect(record.adoptedActionId, isNull);
    final text = scope.disclosureFor([record], null, '', policy: policy);
    expect(text, contains(policy.safetyMessage));
    expect(text, contains(policy.specialty));
    expect(text, contains('可以选择'));
  });

  test('explicitly locked actions or dose are not silently replaced', () {
    final record = scope.evaluateRequest(
      sourceRequest('outside-a', locked: true),
      policy,
    );
    expect(record.kind, CoachScopeDecisionKind.lockedConflict);
    expect(record.adoptedActionId, isNull);
    expect(record.allowPlan, isFalse);
    expect(record.message, contains('已锁定'));
  });

  test('unknown equipment and incompatible scenes do not get a substitute', () {
    expect(
      scope
          .evaluateRequest(
            sourceRequest('outside-a', equipment: const {}),
            policy,
          )
          .kind,
      CoachScopeDecisionKind.outOfScope,
    );
    expect(
      scope
          .evaluateRequest(sourceRequest('outside-a', scene: 'office'), policy)
          .kind,
      CoachScopeDecisionKind.outOfScope,
    );
  });

  test(
    'same body with different requested source equipment cannot be called equivalent',
    () {
      final catalog = actionScopeCatalog(
        rows: [
          actionScopeDrill('hip-a', equipment: const []),
          actionScopeDrill('outside-a', equipment: const ['mat']),
        ],
      );
      scope = actionScopeManifest(
        catalog,
        ids: ['hip-a'],
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final record = scope.evaluateRequest(sourceRequest('outside-a'), policy);
      expect(record.adoptedActionId, isNull);
      expect(record.kind, CoachScopeDecisionKind.outOfScope);
    },
  );

  test('catalog safety filters are reused for replacement candidates', () {
    final record = scope.evaluateRequest(
      sourceRequest('outside-a', avoid: const {'髋'}),
      policy,
    );
    expect(record.adoptedActionId, 'hip-a');
    expect(record.candidateIds, isNot(contains('unsafe-hip')));
    final state = CoachSessionState(
      params: {
        'scene': CoachParamValue(value: 'home', source: 'host', turn: 0),
        'equipment': CoachParamValue(
          value: ['equip.mat'],
          source: 'host',
          turn: 0,
        ),
      },
    );
    final withState = scope.evaluateRequest(
      sourceRequest('outside-a', avoid: const {'髋'}, state: state),
      policy,
    );
    expect(withState.candidateIds, isNot(contains('unsafe-hip')));
  });

  test('canonical body-code check reveals no master action index', () {
    expect(scope.isKnownBodyCode('body.inner_thigh'), isTrue);
    expect(scope.isKnownBodyCode('body.lats'), isTrue);
    expect(scope.isKnownBodyCode('body.forged'), isFalse);
    expect(scope.isKnownBodyCode('outside-a'), isFalse);
    final bodyOnly = scope.evaluateRequest(
      CoachScopeRequest(
        originalText: '给我背部训练',
        targetBodyCodes: const {'body.lats'},
        scene: 'home',
        equipment: const {'mat'},
      ),
      policy,
    );
    expect(bodyOnly.kind, CoachScopeDecisionKind.outOfScope);
    final within = scope.evaluateRequest(
      CoachScopeRequest(
        originalText: '给我内侧训练',
        targetBodyCodes: const {'body.inner_thigh'},
        scene: 'home',
        equipment: const {'mat'},
      ),
      policy,
    );
    expect(within.kind, CoachScopeDecisionKind.inScope);
    expect(within.candidateIds, isNotEmpty);
    expect(within.candidateIds.every(scope.contains), isTrue);
  });

  test('duration-only or ordinary assessment is not turned into a removal', () {
    for (final hasInScope in [false, true]) {
      final record = scope.evaluateRequest(
        CoachScopeRequest(originalText: '5分钟', hasInScopeContent: hasInScope),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.inScope);
      expect(record.allowPlan, isTrue);
      expect(record.requiresReplan, isFalse);
    }
  });

  test(
    'exact full-name and ID detection does not use name keywords or ID prefixes',
    () {
      expect(
        scope
            .mentionedUnavailableActions('想练outside-a')
            .map((request) => request.sourceActionId),
        contains('outside-a'),
      );
      expect(
        scope
            .mentionedUnavailableActions('想练名单外内侧伸展')
            .map((request) => request.sourceActionId),
        contains('outside-a'),
      );
      expect(scope.mentionedUnavailableActions('想练outside-a-variant'), isEmpty);
      expect(scope.mentionedUnavailableActions('想练内侧'), isEmpty);
      expect(scope.matchesRequestedAction('outside-a', '想练髋部'), isFalse);
    },
  );

  test(
    'unquoted source ID and unknown fabricated ID cannot be accepted as user intent',
    () {
      expect(
        () => scope.evaluateRequest(
          sourceRequest('outside-a', text: '只练髋部'),
          policy,
        ),
        throwsFormatException,
      );
      expect(
        () => scope.evaluateRequest(
          sourceRequest('forged-id', text: '只练髋部'),
          policy,
        ),
        throwsFormatException,
      );
      final unknownButLiteral = scope.evaluateRequest(
        sourceRequest('forged-id', partial: true),
        policy,
      );
      expect(unknownButLiteral.kind, CoachScopeDecisionKind.removed);
      expect(unknownButLiteral.adoptedActionId, isNull);
    },
  );

  test(
    'final disclosure refuses a different adopted action or an empty plan',
    () {
      final record = scope.evaluateRequest(sourceRequest('outside-a'), policy);
      expect(
        () => scope.disclosureFor(
          [record],
          actionScopePlan('hip-b'),
          '',
          policy: policy,
        ),
        throwsA(
          isA<CoachScopeDisclosureException>().having(
            (error) => error.code,
            'code',
            'adopted_action_missing',
          ),
        ),
      );
      final raw = actionScopePlan('hip-a');
      final empty = raw.copyWith(blocks: []);
      expect(
        () => scope.disclosureFor([record], empty, '', policy: policy),
        throwsA(isA<CoachScopeDisclosureException>()),
      );
    },
  );

  test(
    'tampered adopted ID from a different body group is rejected even inside the allowlist',
    () {
      final record = scope.evaluateRequest(sourceRequest('outside-a'), policy);
      final tampered = CoachScopeDecisionRecord.fromJson({
        ...record.toJson(),
        'adoptedActionId': 'hip-b',
      });
      expect(scope.validateRecord(tampered), isNotEmpty);
      expect(
        () => scope.disclosureFor(
          [tampered],
          actionScopePlan('hip-b'),
          '',
          policy: policy,
        ),
        throwsA(isA<CoachScopeDisclosureException>()),
      );
    },
  );

  test(
    'scope identity and false allowPlan flags cannot be forged on restore',
    () {
      final record = scope.evaluateRequest(
        sourceRequest('outside-back'),
        policy,
      );
      final wrongScope = CoachScopeDecisionRecord.fromJson({
        ...record.toJson(),
        'scopeIdentity': '0' * 64,
      });
      expect(scope.validateRecord(wrongScope), isNotEmpty);
      final wrongDecision = CoachScopeDecisionRecord.fromJson({
        ...record.toJson(),
        'allowPlan': true,
      });
      expect(scope.validateRecord(wrongDecision), isNotEmpty);
    },
  );

  test('decision JSON preserves exact user wording and plan association', () {
    final record = scope
        .evaluateRequest(
          CoachScopeRequest(
            originalText: '  我要 outside-a  ',
            sourceActionId: 'outside-a',
            sourceQuote: 'outside-a',
            scene: 'home',
            equipment: const {'mat'},
            turn: 3,
          ),
          policy,
        )
        .bindToPlan('plan-one', 2);
    final restored = CoachScopeDecisionRecord.fromJson(
      jsonDecode(jsonEncode(record.toJson())),
    );
    expect(restored.toJson(), record.toJson());
    expect(restored.originalText, '  我要 outside-a  ');
    expect(restored.planId, 'plan-one');
    expect(restored.planVersion, 2);
    expect(scope.validateRecord(restored), isEmpty);
  });

  test(
    'authorized but incomplete actions are not claimed to be absent from the App',
    () {
      final record = scope.evaluateRequest(sourceRequest('incomplete'), policy);
      expect(record.allowPlan, isFalse);
      final text = scope.disclosureFor([record], null, '', policy: policy);
      expect(text, contains('暂不能'));
      expect(text, isNot(contains('本 App 没有')));
    },
  );
  test(
    'forged kind, replan flag and unknown substitute source cannot suppress disclosure',
    () {
      final record = scope.evaluateRequest(sourceRequest('outside-a'), policy);
      for (final changes in [
        {'kind': 'inScope', 'requiresReplan': false, 'adoptedActionId': null},
        {'requiresReplan': false},
        {'sourceId': 'forged-id', 'sourceName': '伪造来源', 'sourceQuote': null},
        {'sourceQuote': ''},
      ]) {
        final forged = CoachScopeDecisionRecord.fromJson({
          ...record.toJson(),
          ...changes,
        });
        expect(scope.validateRecord(forged), isNotEmpty);
      }
    },
  );
  test(
    'whole-specialty declaration only denies without requiring hidden body codes',
    () {
      final beforeIds = scope.plannableIds.toSet();
      final record = scope.evaluateRequest(
        CoachScopeRequest(originalText: '只练胸背，5分钟', outsideSpecialty: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.outOfScope);
      expect(record.allowPlan, isFalse);
      expect(record.adoptedActionId, isNull);
      expect(record.candidateIds, isEmpty);
      expect(scope.plannableIds, beforeIds);
      final text = scope.disclosureFor([record], null, '', policy: policy);
      expect(text, contains(policy.specialty));
      expect(text, contains('可以选择'));
      final safety = scope.evaluateRequest(
        CoachScopeRequest(
          originalText: '疼痛时只练胸背',
          outsideSpecialty: true,
          safetyBlocked: true,
        ),
        policy,
      );
      expect(safety.kind, CoachScopeDecisionKind.safetyBlocked);
    },
  );
}
