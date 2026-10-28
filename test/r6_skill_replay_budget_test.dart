import 'dart:convert';
import 'dart:io';

import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

typedef Json = Map<String, dynamic>;

Json _map(Object? value) => (value as Map).cast<String, dynamic>();
Json _function(Object? tool) => _map(_map(tool)['function']);
Json _arguments(Object? tool) =>
    _map(jsonDecode(_function(tool)['arguments'] as String));

/// Synthetic text preserves recorded byte occupancy without reconstructing or
/// storing private reasoning. JSON escaping overhead comes from newline bytes.
String _syntheticReasoning(Json counts) {
  final characters = counts['characters'] as int;
  final utf8Bytes = counts['utf8Bytes'] as int;
  final jsonBytes = counts['jsonValueBytes'] as int?;
  final nonAscii = (utf8Bytes - characters) ~/ 2;
  final escaped = jsonBytes == null ? 0 : jsonBytes - utf8Bytes - 2;
  final ascii = characters - nonAscii - escaped;
  if ((utf8Bytes - characters).isOdd || ascii < 0 || escaped < 0) {
    throw const FormatException('Unsupported public reasoning byte counts');
  }
  return [
    ...List.filled(nonAscii, '中'),
    ...List.filled(escaped, '\n'),
    ...List.filled(ascii, 'r'),
  ].join();
}

int _bodyOccurrences(Object? value, String body) {
  if (value is String) return value == body ? 1 : 0;
  if (value is Map) {
    return value.values.fold(0, (n, v) => n + _bodyOccurrences(v, body));
  }
  if (value is List) {
    return value.fold(0, (n, v) => n + _bodyOccurrences(v, body));
  }
  return 0;
}

int _fullSkillCopies(LlmRequest request, String body) =>
    request.messages.fold(0, (sum, message) {
      if (message.content == body) return sum + 1;
      try {
        return sum + _bodyOccurrences(jsonDecode(message.content), body);
      } on FormatException {
        return sum;
      }
    });

void _expectPairedTools(LlmRequest request) {
  final pending = <String>{};
  for (final message in request.messages) {
    if (message.role == LlmRole.assistant) {
      expect(pending, isEmpty, reason: 'the previous batch must be complete');
      for (final call in message.toolCalls) {
        expect(pending.add(call.id), isTrue);
      }
    } else if (message.role == LlmRole.tool) {
      expect(
        pending.remove(message.toolCallId),
        isTrue,
        reason: 'tool result must retain its exact tool_call_id',
      );
      try {
        final result = jsonDecode(message.content);
        if (result is Map) {
          expect(
            result['ok'],
            isNot(false),
            reason: '${message.toolCallId}: $result',
          );
        }
      } on FormatException {
        // Skill bodies and archive rows are intentionally plain text.
      }
    } else {
      expect(pending, isEmpty);
    }
  }
  expect(pending, isEmpty);
}

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/r6_skill_replay.json').readAsStringSync())
          as Json;
  final records = (fixture['responses'] as List).cast<Json>();
  final synthetic = [
    for (final record in records)
      _syntheticReasoning(record['reasoning'] as Json),
  ];
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile(fixture['profile'] as String);
  final memory = fixture['enableUserMemory'] as bool;
  final files = SkillFiles.build(profile, catalog, memory: memory);
  final skills = {
    for (final skill in ['action-library', 'plan-training', 'ask'])
      skill: files.read('$skill/SKILL.md')!,
  };
  late CoachAgent coach;
  late FakeLlmClient fake;
  late CoachTurnResult result;
  late OpenAiCompatibleClient serializer;
  late List<Map<String, Object?>> bodies;

  setUpAll(() async {
    fake = FakeLlmClient([
      for (var i = 0; i < records.length; i++)
        LlmResponse(
          content: records[i]['content'] as String? ?? '',
          model: records[i]['model'] as String,
          finishReason: records[i]['finishReason'] as String,
          reasoning: synthetic[i],
          toolCalls: [
            for (var j = 0; j < (records[i]['toolCalls'] as List).length; j++)
              LlmToolCall.fromOpenAi((records[i]['toolCalls'] as List)[j], j),
          ],
        ),
    ], latency: Duration.zero);
    coach = CoachAgent(
      client: fake,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: memory,
      maxSteps: fixture['stopAfterRecordedResponses'] as int,
      maxRequestRetries: 0,
    );
    serializer = OpenAiCompatibleClient(
      config: LlmConfig.ugkWorker.copyWith(
        model: fixture['requestedModel'] as String,
        maxTokens: fixture['maxTokens'] as int,
        extraBody: {
          'thinking': {'type': fixture['thinking']},
        },
      ),
      httpClient: MockClient(
        (_) => throw StateError('Offline replay: HTTP forbidden'),
      ),
    );
    result = await coach.send(
      fixture['user'] as String,
      context: CoachContext(language: fixture['contextLanguage'] as String),
    );
    bodies = [
      for (final request in fake.requests) serializer.buildBody(request),
    ];
  });
  tearDownAll(() async {
    serializer.close();
    await coach.dispose();
  });

  test(
    'fixture is public tool history with explicit synthetic reasoning counts',
    () {
      expect(fixture['mode'], 'offline-public-tools-with-synthetic-reasoning');
      expect(fixture['sourceCaseValidity'], 'invalid-model-mismatch');
      expect(records, hasLength(6));
      expect(
        (records[0]['toolCalls'] as List).map((raw) => _arguments(raw)['path']),
        ['action-library/SKILL.md', 'plan-training/SKILL.md'],
      );
      expect(
        _arguments((records[1]['toolCalls'] as List).single)['path'],
        'ask/SKILL.md',
      );
      expect(
        _function((records[2]['toolCalls'] as List).first)['name'],
        'start_task',
      );
      for (var i = 0; i < records.length; i++) {
        final counts = records[i]['reasoning'] as Json;
        expect(counts['synthetic'], isTrue);
        expect(counts['originalTextAvailable'], isFalse);
        expect(synthetic[i].length, counts['characters']);
        expect(utf8.encode(synthetic[i]).length, counts['utf8Bytes']);
        if (counts['jsonValueBytes'] != null) {
          expect(
            utf8.encode(jsonEncode(synthetic[i])).length,
            counts['jsonValueBytes'],
          );
        }
      }
      // Response six has no later recorded request, so its JSON-byte occupancy
      // is unknown rather than invented. It is not replayed in these six bodies.
      expect((records.last['reasoning'] as Json)['jsonValueBytes'], isNull);
      expect(result.error, isA<AgentStepLimitExceeded>());
      expect(fake.requests, hasLength(6));
    },
  );

  test(
    'all six real SDK request bodies fit 40 KB with recorded reasoning occupancy',
    () {
      final sizes = [
        for (final body in bodies) utf8.encode(jsonEncode(body)).length,
      ];
      print('R6 public tools + SYNTHETIC reasoning request bytes: $sizes');
      for (var i = 0; i < bodies.length; i++) {
        final messages = (bodies[i]['messages'] as List)
            .cast<Map<String, Object?>>();
        final utf8Bytes = messages.fold<int>(
          0,
          (n, m) =>
              n +
              (m['reasoning_content'] is String
                  ? utf8.encode(m['reasoning_content'] as String).length
                  : 0),
        );
        final expectedUtf8 = records
            .take(i)
            .fold<int>(
              0,
              (n, r) => n + ((r['reasoning'] as Json)['utf8Bytes'] as int),
            );
        final jsonValueBytes = messages.fold<int>(
          0,
          (n, m) =>
              n +
              (m['reasoning_content'] is String
                  ? utf8.encode(jsonEncode(m['reasoning_content'])).length
                  : 0),
        );
        final expectedJson = records
            .take(i)
            .fold<int>(
              0,
              (n, r) => n + ((r['reasoning'] as Json)['jsonValueBytes'] as int),
            );
        print(
          'R6 request ${i + 1}: body=${sizes[i]}, synthetic reasoning '
          'UTF8=$utf8Bytes, JSON-values=$jsonValueBytes bytes',
        );
        expect(
          utf8Bytes,
          expectedUtf8,
          reason: 'current-turn reasoning remains intact',
        );
        expect(jsonValueBytes, expectedJson);
        expect(
          sizes[i],
          lessThanOrEqualTo(fixture['requestLimitBytes'] as int),
          reason: 'R6 request ${i + 1}: ${sizes[i]} bytes',
        );
      }
    },
  );

  test('each explicitly read skill is fully visible before start_task', () {
    for (final name in ['action-library', 'plan-training']) {
      expect(_fullSkillCopies(fake.requests[1], skills[name]!), 1);
    }
    expect(_fullSkillCopies(fake.requests[1], skills['ask']!), 0);
    for (final body in skills.values) {
      expect(_fullSkillCopies(fake.requests[2], body), 1);
    }
  });

  test(
    'recommend task retains exactly one required skill body and archives unrelated read',
    () {
      final planRead =
          _map((records[0]['toolCalls'] as List).last)['id'] as String;
      final libraryRead =
          _map((records[0]['toolCalls'] as List).first)['id'] as String;
      final askRead =
          _map((records[1]['toolCalls'] as List).single)['id'] as String;
      final startId =
          _map((records[2]['toolCalls'] as List).first)['id'] as String;
      for (final request in fake.requests.skip(3)) {
        for (final name in ['ask', 'action-library']) {
          expect(
            _fullSkillCopies(request, skills[name]!),
            1,
            reason: '$name must have a single complete current version',
          );
        }
        expect(_fullSkillCopies(request, skills['plan-training']!), 0);
        final start = _map(
          jsonDecode(
            request.messages
                .singleWhere((m) => m.toolCallId == startId)
                .content,
          ),
        );
        for (final name in ['ask', 'action-library']) {
          expect(_map(start['skills'])[name], '[已在前文 read 中]');
        }
        expect(
          request.messages
              .singleWhere((m) => m.toolCallId == libraryRead)
              .content,
          skills['action-library'],
        );
        expect(
          request.messages.singleWhere((m) => m.toolCallId == askRead).content,
          skills['ask'],
        );
        final archived = request.messages.singleWhere(
          (m) => m.toolCallId == planRead,
        );
        expect(archived.content, startsWith('[已归档'));
      }
    },
  );

  test('every replayed request retains all assistant/tool ID pairings', () {
    for (final request in fake.requests) {
      _expectPairedTools(request);
    }
  });
}
