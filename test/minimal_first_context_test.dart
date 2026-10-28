import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse call(String id, String name, Object args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: id, name: name, arguments: jsonEncode(args))],
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, dynamic> feedback(LlmRequest request, String id) =>
    jsonDecode(
          request.messages
              .singleWhere((message) => message.toolCallId == id)
              .content,
        )
        as Map<String, dynamic>;

void main() {
  const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$root/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$root/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();

  for (final name in ['smartfit', 'hiplab', 'flarelab']) {
    test(
      '$name first request includes complete tools but no catalogue or skill body',
      () async {
        final client = FakeLlmClient(['你好。'], latency: Duration.zero);
        final coach = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: loadProfile(name),
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        addTearDown(coach.dispose);
        await coach.send('深蹲怎么做？');
        final request = client.requests.single;
        final serializer = OpenAiCompatibleClient(
          config: LlmConfig.ugkWorker.copyWith(
            extraBody: {
              'thinking': {'type': 'enabled'},
            },
          ),
        );
        final payload = jsonEncode(serializer.buildBody(request));
        final size = utf8.encode(payload).length;
        expect(
          size,
          lessThanOrEqualTo(12 * 1024),
          reason: '$name payload=$size bytes',
        );
        expect(payload, isNot(contains('h-squat')));
        expect(payload, isNot(contains('<action-index-data>')));
        expect(payload, isNot(contains('<action-details-data>')));
        final system = request.messages.first.content;
        expect(system, contains('ask/SKILL.md'));
        expect(system, contains('action-library/SKILL.md'));
        expect(system, isNot(contains('按已知场景、器械和训练目标搜索适合的动作\n---')));
        expect(system, isNot(contains('未知的安全数据不代表已验证安全')));
      },
    );
  }

  test(
    'first request keeps the user words and memory as a preselection',
    () async {
      final client = FakeLlmClient(['你好。'], latency: Duration.zero);
      final store = InMemoryUserMemoryStore([
        MemoryEntry(MemoryKind.scene, '平时在家练', at: DateTime.utc(2026)),
      ]);
      final coach = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('flarelab'),
        enableUserMemory: true,
        memoryStore: store,
        maxRequestRetries: 0,
      );
      addTearDown(coach.dispose);
      await coach.send('今天在家练多久合适？');
      final request = client.requests.single;
      final serializer = OpenAiCompatibleClient(
        config: LlmConfig.ugkWorker.copyWith(
          extraBody: {
            'thinking': {'type': 'enabled'},
          },
        ),
      );
      final payload = jsonEncode(serializer.buildBody(request));
      final size = utf8.encode(payload).length;
      expect(
        size,
        lessThanOrEqualTo(12 * 1024),
        reason: 'memory-enabled=$size bytes',
      );
      expect(payload, contains('今天在家练多久合适？'));
      expect(payload, contains('平时在家练'));
      expect(request.messages.first.content, contains('习惯只作预选'));
    },
  );

  for (final type in ['recommend', 'plan']) {
    test(
      '$type start_task returns only required skills and retains them across calls',
      () async {
        final profile = loadProfile('smartfit');
        final fs = SkillFiles.build(profile, catalog, memory: false);
        final client = FakeLlmClient([
          call('start', 'start_task', {'type': type}),
          call('check', 'check', {'node': 'understand'}),
          call('ask', 'ask_user', {'question': '你想练什么？', 'mode': 'text'}),
        ], latency: Duration.zero);
        final coach = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        addTearDown(coach.dispose);
        final result = await coach.send('帮我训练');
        expect(
          result.question,
          isNotNull,
          reason: '${result.error} ${result.issues}',
        );
        final data = feedback(client.requests.last, 'start');
        expect(data['ok'], isTrue);
        final skills = (data['skills'] as Map).cast<String, dynamic>();
        expect(skills.keys.toSet(), {
          'ask',
          'action-library',
          if (type == 'recommend') 'action-coaching',
          if (type == 'plan') 'plan-training',
        });
        for (final entry in skills.entries) {
          expect(entry.value, fs.read('${entry.key}/SKILL.md'));
        }
        expect(data['profile'], {
          'focus': profile.focus,
          'rules': profile.rules,
        });
        expect(data['task'], isNotNull);
        if (type == 'plan') expect(data['plan_id'], isA<String>());
      },
    );
  }
}
