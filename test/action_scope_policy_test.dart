import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/catalog/pose_hub_app_test_pack.dart';
import 'package:ugk_coach/src/scope/action_scope.dart';

import 'action_scope_manifest_test.dart'
    show
        actionScopeCatalog,
        actionScopeDrill,
        actionScopeManifest,
        actionScopePlan,
        actionScopeProfile;

void main() {
  test(
    'English scope wording preserves substitution and refusal decisions',
    () {
      final catalog = actionScopeCatalog(
        rows: [
          actionScopeDrill('hip-a', name: 'Gentle inner-thigh stretch'),
          actionScopeDrill(
            'outside-a',
            name: 'Unavailable inner-thigh stretch',
          ),
        ],
      );
      final scope = actionScopeManifest(
        catalog,
        ids: ['hip-a'],
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final english = CoachScopeConversationPolicy(
        languageTag: 'en',
        specialty: 'This app focuses on gentle hip mobility.',
        suggestions: ['Gentle hip stretch', 'Glute activation'],
      );
      final chinese = CoachScopeConversationPolicy(specialty: '本 App 专注髋部训练。');
      final request = CoachScopeRequest(
        originalText: 'Try outside-a',
        sourceActionId: 'outside-a',
        scene: 'home',
        equipment: {'mat'},
      );
      final before = scope.evaluateRequest(request, chinese);
      final after = scope.evaluateRequest(request, english);
      expect(after.kind, before.kind);
      expect(after.adoptedActionId, before.adoptedActionId);
      expect(after.allowPlan, before.allowPlan);
      final refusal = scope.evaluateRequest(
      CoachScopeRequest(
          originalText: 'Something unrelated',
          outsideSpecialty: true,
        ),
        english,
      );
      final disclosure = scope.disclosureFor(
        [refusal],
        null,
        '',
        policy: english,
      );
      expect(disclosure, contains('outside this app’s training scope'));
      expect(
        disclosure,
        contains('You can choose: Gentle hip stretch; Glute activation.'),
      );
      expect(RegExp(r'[\u3400-\u9fff]').hasMatch(disclosure), isFalse);
      final safety = scope.evaluateRequest(
      CoachScopeRequest(originalText: 'Stop', safetyBlocked: true),
        english,
      );
      expect(safety.message, startsWith('Pause this training plan'));
      expect(safety.allowPlan, isFalse);
    },
  );

  late CoachActionScope scope;
  final policy = CoachScopeConversationPolicy(
    specialty: '本 App 专注髋部、臀部和温和拉伸。',
    suggestions: ['温和髋部拉伸', '臀部激活'],
    safetyMessage: '先暂停训练并处理疼痛。',
  );
  setUp(() {
    final catalog = actionScopeCatalog();
    scope = actionScopeManifest(
      catalog,
    ).restrict(catalog: catalog, profile: actionScopeProfile());
  });

  CoachScopeRequest request(
    String id, {
    bool partial = false,
    bool insists = false,
    bool safety = false,
    bool locked = false,
  }) => CoachScopeRequest(
    originalText: '我想练$id',
    sourceActionId: id,
    scene: 'home',
    equipment: {'mat'},
    hasInScopeContent: partial,
    insists: insists,
    safetyBlocked: safety,
    locked: locked,
    turn: 1,
  );

  test(
    'an unavailable action uses the closest compatible scoped substitute',
    () {
      final record = scope.evaluateRequest(request('outside-a'), policy);
      expect(record.kind, CoachScopeDecisionKind.substituted);
      expect(record.adoptedActionId, 'hip-a');
      final plan = actionScopePlan(record.adoptedActionId!);
      expect(plan.items, isNotEmpty);
      expect(plan.exerciseIds, isNotEmpty);
      expect(plan.exerciseIds.difference(scope.plannableIds), isEmpty);
      expect(
        scope.disclosureFor([record], plan, '', policy: policy),
        contains('本 App 没有名单外内侧伸展，用温和内侧伸展练同一部位'),
      );
    },
  );

  test(
    'replacement selection uses body, scene and equipment rather than display names',
    () {
      final catalog = actionScopeCatalog(
        rows: [
          actionScopeDrill('hip-a', name: '名字完全不同'),
          actionScopeDrill('wrong-body', name: '名单外内侧伸展', body: 'hip-flexors'),
          actionScopeDrill('wrong-scene', scenes: ['office']),
          actionScopeDrill('wrong-equipment', equipment: ['chair']),
          actionScopeDrill('outside-a', name: '名单外内侧伸展'),
        ],
      );
      scope = actionScopeManifest(
        catalog,
        ids: ['hip-a', 'wrong-body', 'wrong-scene', 'wrong-equipment'],
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final record = scope.evaluateRequest(request('outside-a'), policy);
      expect(record.adoptedActionId, 'hip-a');
      expect(record.candidateIds, ['hip-a']);
    },
  );

  test('an unmatched partial request is removed with an explanation', () {
    final record = scope.evaluateRequest(
      request('outside-back', partial: true),
      policy,
    );
    expect(record.kind, CoachScopeDecisionKind.removed);
    expect(record.allowPlan, isTrue);
    expect(record.requiresReplan, isTrue);
    expect(record.adoptedActionId, isNull);
    expect(
      scope.disclosureFor(
        [record],
        actionScopePlan('hip-a'),
        '',
        policy: policy,
      ),
      contains('本次去掉它，未覆盖这部分目标'),
    );
  });

  test(
    'a whole request beyond the specialty gives in-scope suggestions without a plan',
    () {
      final record = scope.evaluateRequest(
        CoachScopeRequest(originalText: '我要练胸背', outsideSpecialty: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.outOfScope);
      expect(record.allowPlan, isFalse);
      final text = scope.disclosureFor([record], null, '', policy: policy);
      expect(text, contains(policy.specialty));
      expect(text, contains('温和髋部拉伸'));
    },
  );

  test(
    'insistence on an unavailable action is answered honestly without substitution',
    () {
      final record = scope.evaluateRequest(
        request('outside-a', insists: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.insistedUnavailable);
      expect(record.allowPlan, isFalse);
      expect(record.adoptedActionId, isNull);
      expect(record.message, contains('不能把它安排进计划'));
    },
  );

  test(
    'a locked unavailable action asks for a choice rather than replacing it',
    () {
      final record = scope.evaluateRequest(
        request('outside-a', locked: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.lockedConflict);
      expect(record.allowPlan, isFalse);
      expect(record.adoptedActionId, isNull);
    },
  );

  test(
    'safety takes priority over an unavailable action and user insistence',
    () {
      final record = scope.evaluateRequest(
        request('outside-a', insists: true, safety: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.safetyBlocked);
      expect(record.allowPlan, isFalse);
      expect(record.adoptedActionId, isNull);
      expect(
        scope.disclosureFor([record], null, '', policy: policy),
        contains(policy.safetyMessage),
      );
    },
  );

  test(
    'cross-App guidance is absent by default and present only when configured',
    () {
      final record = scope.evaluateRequest(request('outside-back'), policy);
      final enabled = CoachScopeConversationPolicy(
        specialty: policy.specialty,
        suggestions: policy.suggestions,
        outOfScopeGuidance: '可查看宿主提供的训练建议。',
      );
      expect(policy.guidanceEnabled, isFalse);
      expect(
        scope.disclosureFor([record], null, '', policy: policy),
        isNot(contains(enabled.outOfScopeGuidance!)),
      );
      expect(
        scope.disclosureFor([record], null, '', policy: enabled),
        contains(enabled.outOfScopeGuidance!),
      );
    },
  );

  test(
    'a duration-only request stays in scope without inventing a removed action',
    () {
      final record = scope.evaluateRequest(
        CoachScopeRequest(originalText: '练五分钟'),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.inScope);
      expect(record.allowPlan, isTrue);
      expect(record.sourceId, isNull);
    },
  );

  test(
    'a canonical available name resolves to its ID and is not called missing',
    () {
      final record = scope.evaluateRequest(
        CoachScopeRequest(
          originalText: '做温和内侧伸展',
          sourceActionName: '温和内侧伸展',
          sourceQuote: '普通宿主说明',
        ),
        policy,
      );
      expect(record.sourceId, 'hip-a');
      expect(record.kind, CoachScopeDecisionKind.inScope);
      expect(record.requiresReplan, isFalse);
      expect(record.message, isNot(contains('没有')));
    },
  );

  test('an unavailable full name resolves before choosing its substitute', () {
    final record = scope.evaluateRequest(
      CoachScopeRequest(
        originalText: '做名单外内侧伸展',
        sourceActionName: '名单外内侧伸展',
        scene: 'home',
        equipment: {'mat'},
      ),
      policy,
    );
    expect(record.sourceId, 'outside-a');
    expect(record.kind, CoachScopeDecisionKind.substituted);
    expect(record.adoptedActionId, 'hip-a');
  });

  test(
    'public Hip candidate butterfly name resolves without granting a seen action',
    () {
      const pack = 'test/fixtures/pose_hub/r1-v3';
      final bytes = File('$pack/catalog.json').readAsBytesSync();
      final catalog = PoseHubAppTestCatalog.fromBytes(
        bytes,
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/action-scope/hiplab-candidate-45.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(fixture['approvalStatus'], 'candidate-not-user-approved');
      scope = CoachActionScopeManifest.fromCatalogBytes(
        appId: 'hiplab',
        catalogBytes: bytes,
        allowedActionIds: (fixture['allowedActionIds'] as List).cast<String>(),
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final name = scope.catalog['s-butterfly']!.name.of('zh');
      expect(name, '蝴蝶式');
      final record = scope.evaluateRequest(
        CoachScopeRequest(originalText: '做$name', sourceActionName: name),
        policy,
      );
      expect(record.sourceId, 's-butterfly');
      expect(record.kind, CoachScopeDecisionKind.inScope);
      expect(record.candidateIds, isEmpty);
    },
  );

  test(
    'an allowed action with incomplete training data is described as temporarily unavailable',
    () {
      final record = scope.evaluateRequest(
        request('incomplete', partial: true),
        policy,
      );
      expect(record.kind, CoachScopeDecisionKind.removed);
      expect(record.message, contains('暂不能'));
      expect(record.message, isNot(contains('本 App 没有')));
    },
  );

  test('a delivered replacement plan must contain the selected substitute', () {
    final record = scope.evaluateRequest(request('outside-a'), policy);
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
  });

  test('workflow records round-trip their ordinary user and decision data', () {
    final record = scope.evaluateRequest(request('outside-a'), policy);
    final restored = CoachScopeDecisionRecord.fromJson(
      jsonDecode(jsonEncode(record.toJson())),
    );
    expect(restored.toJson(), record.toJson());
    expect(restored.originalText, '我想练outside-a');
    expect(restored.turn, 1);
    expect(restored.allowPlan, isTrue);
  });
}
