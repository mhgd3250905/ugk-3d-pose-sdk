import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

LlmResponse _call(String name, Map<String, Object?> args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: name, name: name, arguments: jsonEncode(args))],
);

void main() {
  test(
    'confirmed shoulder red flags can decline low-stress push candidates',
    () async {
      final metaFile = File(
        'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
      );
      final descriptor = PoseHubAppTestCatalog.fromBytes(
        metaFile.readAsBytesSync(),
      );
      final catalog = PoseHubAppTestCatalog.fromBytes(
        metaFile.readAsBytesSync(),
        semanticCatalogBytes: File(
          '${metaFile.parent.path}/${descriptor.semanticCatalogFile.path}',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final profile = CoachProfile.fromJson(
        jsonDecode(File('profiles/smartfit.json').readAsStringSync()),
      );
      // Minimal copy of the unchanged 5d17c24 tag fields that admitted this move.
      // This fixture is not a safety approval or a replacement tag dataset.
      const tags = <String, Map<String, Object?>>{
        'h-incline-pushup': {
          'format': 'pose-hub-ai-tags@1',
          'scenes': ['home', 'office', 'gym', 'outdoor', 'hotel'],
          'requiredEquipment': ['chair'],
          'trainingType': ['strength'],
          'movementPattern': ['push-horizontal'],
          'primaryMuscles': ['chest', 'triceps'],
          'secondaryMuscles': ['deltoids'],
          'jointStress': {'shoulder': 'low', 'wrist': 'low'},
          'difficulty': 1,
          'sessionRole': ['main', 'warmup'],
        },
      };
      final client = FakeLlmClient([
        _call('set_conditions', {'avoid_joints': ['shoulder']}),
        _call('ask_user', {
          'step': 'safety',
          'question': '你的肩具体是怎样的痛？',
          'options': ['抬手或发力时刺痛、有卡住感', '平时酸胀，活动开就好一些'],
        }),
        _call('set_conditions', {'red_flag': true}),
        // 模型想附一个上斜俯卧撑：危险信号已确认，验收退回。
        _call('reply', {
          'text': '先停止会引起刺痛的训练。',
          'items': [
            {'id': 'h-incline-pushup', 'why': '负担低'},
          ],
          'chips': <String>[],
        }),
        _call('reply', {
          'text': '先停止会引起刺痛的训练，安排专业评估。',
          'items': <Object?>[],
          'chips': ['怎么安排专业评估'],
        }),
      ], latency: Duration.zero);
      final agent = CoachQaAgent(
        client: client,
        catalog: catalog,
        profile: profile,
        aiTags: tags,
      );
      final first = await agent.send('肩痛练胸');
      expect(first.askStep, QaAskStep.safety);
      final reply = await agent.send(first.question!.options.first);
      expect(agent.state.avoidJoints, contains('shoulder'));
      expect(agent.state.redFlag, isTrue);
      // The QA tag stays low; the shared core admission still rejects the
      // action because the App catalogue lists a shoulder caution.
      expect(
        agent.index['h-incline-pushup']!.jointStress['shoulder'],
        'low',
        reason: 'The original low-stress tag is intentionally unchanged',
      );
      expect(
        agent.finder.admission.problem(
          'h-incline-pushup',
          scene: 'home',
          equipment: const [],
          avoid: const ['shoulder'],
        ),
        isNotNull,
      );
      expect(
        agent.finder.passes(
          agent.index['h-incline-pushup']!,
          QaQuery(
            scene: 'home',
            equipment: const {},
            avoidJoints: const {'shoulder'},
          ),
        ),
        isFalse,
      );
      final last = client.requests.last;
      expect(last.tools.map((t) => t.name), contains('reply'));
      expect(last.messages.first.content, contains(coachQaSop));
      expect(last.messages.first.content, contains('low 不等于没有负担'));
      expect(last.messages.last.content, contains('items 必须为空'));
      expect(
        last.messages.firstWhere((m) => m.content.contains('[用户这句话]')).content,
        contains('抬手或发力时刺痛、有卡住感'),
      );
      expect(reply.kind, 'answer');
      expect(reply.cards, isEmpty);
      expect(reply.plan, isNull);
      expect(reply.llmCalls, 3);
    },
  );
}
