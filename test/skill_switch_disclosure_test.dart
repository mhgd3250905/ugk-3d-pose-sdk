import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/skill_disclosure.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse _call(String id, String name, Object args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: id, name: name, arguments: jsonEncode(args))],
  finishReason: 'tool_calls',
  model: 'offline-fake',
);

Map<String, Object?> _object(Object? raw) =>
    (raw as Map).cast<String, Object?>();

int _copies(Object? value, String body) {
  if (value is String) return value == body ? 1 : 0;
  if (value is Map) {
    return value.values.fold(0, (n, item) => n + _copies(item, body));
  }
  if (value is List) {
    return value.fold(0, (n, item) => n + _copies(item, body));
  }
  return 0;
}

int _fullCopies(LlmRequest request, String body) =>
    request.messages.fold(0, (count, message) {
      if (message.content == body) return count + 1;
      try {
        return count + _copies(jsonDecode(message.content), body);
      } on FormatException {
        return count;
      }
    });

Map<String, Object?> _skills(LlmRequest request, String id) => _object(
  _object(
    jsonDecode(
      request.messages
          .singleWhere((message) => message.toolCallId == id)
          .content,
    ),
  )['skills'],
);

void _expectPairs(LlmRequest request) {
  final pending = <String>{};
  for (final message in request.messages) {
    if (message.role == LlmRole.assistant) {
      expect(pending, isEmpty);
      for (final call in message.toolCalls) {
        expect(pending.add(call.id), isTrue);
      }
    } else if (message.role == LlmRole.tool) {
      expect(pending.remove(message.toolCallId), isTrue);
    } else {
      expect(pending, isEmpty);
    }
  }
  expect(pending, isEmpty);
}

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final files = SkillFiles.build(profile, catalog, memory: false);
  final bodies = {
    for (final skill in ['ask', 'action-library', 'plan-training'])
      skill: files.read('$skill/SKILL.md')!,
  };

  for (final firstFromRead in [false, true]) {
    test(
      firstFromRead
          ? 'read plan skill -> recommend -> plan never revives the archived read'
          : 'plan -> recommend -> plan reuses the still-visible first task skill',
      () async {
        final client = FakeLlmClient([
          firstFromRead
              ? _call('first', AgentTools.read, {
                  'path': 'plan-training/SKILL.md',
                })
              : _call('first', AgentTools.startTask, {'type': 'plan'}),
          _call('recommend', AgentTools.startTask, {'type': 'recommend'}),
          _call('last-plan', AgentTools.startTask, {'type': 'plan'}),
          _call('question', AgentTools.askUser, {
            'question': 'Where will you train?',
            'mode': 'text',
          }),
        ], latency: Duration.zero);
        final coach = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        addTearDown(coach.dispose);
        final result = await coach.send('Please plan a workout');
        expect(result.status, TurnStatus.ok);
        expect(result.question, isNotNull);
        expect(client.requests, hasLength(4));
        final planCopies = [
          for (final request in client.requests)
            _fullCopies(request, bodies['plan-training']!),
        ];
        expect(planCopies, firstFromRead ? [0, 1, 0, 1] : [0, 1, 1, 1]);
        for (final request in client.requests) {
          _expectPairs(request);
          for (final body in bodies.values) {
            expect(_fullCopies(request, body), lessThanOrEqualTo(1));
          }
        }

        final afterRecommend = client.requests[2];
        final afterPlan = client.requests[3];
        final finalSkills = _skills(afterPlan, 'last-plan');
        if (firstFromRead) {
          // Both requests retain the old tool_call_id, but its archived body
          // must stay archived after a later task needs that skill again.
          for (final request in [afterRecommend, afterPlan]) {
            expect(
              request.messages
                  .singleWhere((m) => m.toolCallId == 'first')
                  .content,
              SkillDisclosures.unrelatedArchive,
            );
          }
          expect(finalSkills['plan-training'], bodies['plan-training']);
          final originalRecommend = _skills(afterPlan, 'recommend');
          for (final skill in ['ask', 'action-library']) {
            expect(finalSkills[skill], SkillDisclosures.startReference);
            expect(
              originalRecommend[skill],
              bodies[skill],
              reason: 'reference must target a still-visible full skill',
            );
          }
        } else {
          final originalPlan = _skills(afterPlan, 'first');
          for (final skill in bodies.keys) {
            expect(finalSkills[skill], SkillDisclosures.startReference);
            expect(
              originalPlan[skill],
              bodies[skill],
              reason: 'reference must target the first full start_task body',
            );
          }
        }
      },
    );
  }
}
