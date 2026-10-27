import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  test(
    'a failed action explanation cannot offer the previous plan preset',
    () async {
      final catalog = loadCatalog();
      final profile = loadProfile('hiplab');
      final planJson = planOf(okEnvelope())..remove('source');
      final oldPlan = const PlanCodec().decode(planJson);
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          toolCalls: [
            LlmToolCall(
              id: 'old-plan',
              name: AgentTools.showPlan,
              arguments: jsonEncode(planJson),
            ),
          ],
          finishReason: 'tool_calls',
        ),
        const LlmException(
          LlmErrorKind.network,
          'planning network unavailable',
        ),
        const LlmException(LlmErrorKind.network, 'network unavailable'),
      ]);
      final conversation = CoachConversationController(
        agent: CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        ),
      );
      addTearDown(conversation.dispose);

      final first = await conversation.send('在家有瑜伽垫，10分钟安排一个臀部训练计划');
      expect(
        first!.plan,
        isNotNull,
        reason: 'the fixture is an admitted prior plan',
      );
      final failedPlanning = await conversation.send('重试');
      expect(failedPlanning!.status, TurnStatus.error);
      expect(
        conversation.canOfferPreset(oldPlan),
        isTrue,
        reason: 'the old preset is available for the failed old planning task',
      );

      final failed = await conversation.send('肩膀动作怎么做');
      expect(failed!.status, TurnStatus.error);
      expect(conversation.state.messages.last.isFailure, isTrue);
      expect(conversation.canOfferPreset(oldPlan), isFalse);
      expect(conversation.requestPreset(oldPlan), isNull);
      expect(conversation.state.messages.last.isFailure, isTrue);
    },
  );

  test(
    'a failed current planning turn can offer a verified matching preset',
    () async {
      final catalog = loadCatalog();
      final profile = loadProfile('hiplab');
      final plan = const PlanCodec().decode(planOf(okEnvelope()));
      final client = FakeLlmClient([
        const LlmException(LlmErrorKind.network, 'network unavailable'),
      ]);
      final conversation = CoachConversationController(
        agent: CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        ),
      );
      addTearDown(conversation.dispose);

      final failed = await conversation.send('在家有瑜伽垫，10分钟安排一个臀部训练计划');
      expect(failed!.status, TurnStatus.error);
      expect(failed.plan, isNull);
      expect(conversation.state.messages.last.isFailure, isTrue);
      expect(conversation.canOfferPreset(plan), isTrue);
      final accepted = conversation.requestPreset(plan);
      expect(accepted?.plan, isNotNull);
      expect(conversation.state.messages.last.plan, isNotNull);
    },
  );
}
