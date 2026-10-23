// Real model evaluation through the public CoachAgent API. No synthetic model.
// Run `dart run tool/eval_ask_user.dart --help` for setup and replay commands.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/io_client.dart';
import 'package:ugk_coach/ugk_coach.dart';

typedef Json = Map<String, dynamic>;

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln('''
dart run tool/eval_ask_user.dart --dry [--out DIRECTORY]
dart run tool/eval_ask_user.dart [--cases core_ready,bboy_free_text] [--out DIRECTORY]

--dry validates fixtures without a network call; it does not measure model quality.
Default endpoint/model: UGK Worker / deepseek-v4-flash-0731.
Environment: UGK_BASE_URL, UGK_MODEL; UGK_API_KEY for bearer auth, or
UGK_APP_KEY / UGK_APP_KEY_FILE plus UGK_DEVICE_ID / UGK_DEVICE_FILE for Worker.
The device file must already exist. This script never creates or rotates identity.
SSL_CERT_FILE adds a trusted CA. Optional UGK_EVAL_GAP_SECONDS spaces cases.
For official DeepSeek set UGK_BASE_URL=https://api.deepseek.com/v1,
UGK_MODEL=deepseek-flash and inject a valid UGK_API_KEY.
Evidence excludes keys, headers, device IDs, raw prompts and reasoning.
''');
    return;
  }
  String? arg(String flag) {
    final at = args.indexOf(flag);
    if (at < 0) return null;
    if (at + 1 == args.length || args[at + 1].startsWith('--')) {
      throw ArgumentError('Missing value for $flag');
    }
    return args[at + 1];
  }

  final fixtureFile = File('eval/cases/ask_user.json');
  final fixture = jsonDecode(await fixtureFile.readAsString()) as Json;
  final selected = arg('--cases')?.split(',').toSet();
  final cases = (fixture['cases'] as List).cast<Json>();
  final ids = {for (final c in cases) c['id'] as String};
  if (selected != null && !ids.containsAll(selected)) {
    throw ArgumentError('Unknown case ID');
  }
  for (final c in cases) {
    if (c['message'] is! String ||
        c['first'] is! String ||
        c['expect'] is! Map ||
        !['choice', 'text'].contains(c['response'])) {
      throw FormatException('Invalid fixture ${c['id']}');
    }
  }
  final chosen = cases
      .where((c) => selected == null || selected.contains(c['id']))
      .toList();
  final output = Directory(
    arg('--out') ??
        'eval/results/ask-user/${args.contains('--dry') ? 'dry-' : ''}${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}',
  );
  if (args.contains('--dry')) {
    final evidence = {
      'schemaVersion': 1,
      'mode': 'fixture-validation-only',
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'fixtureSha256': sha256
          .convert(await fixtureFile.readAsBytes())
          .toString(),
      'cases': chosen.map((c) => c['id']).toList(),
      'fixtureValidationPassed': true,
      'modelQualityPassed': null,
      'modelCalls': 0,
    };
    await output.create(recursive: true);
    await _json(File('${output.path}/summary.json'), evidence);
    stdout.writeln(jsonEncode(evidence));
    stdout.writeln('Evidence: ${output.absolute.path}/summary.json');
    return;
  }
  final env = Platform.environment;
  final config = LlmConfig.ugkWorker.copyWith(
    baseUrl: env['UGK_BASE_URL'],
    model: env['UGK_MODEL'],
    temperature: 0.3,
    maxRetries: 0,
  );
  final auth = await _auth(env);
  final security = SecurityContext(withTrustedRoots: true);
  if (env['SSL_CERT_FILE'] case final String ca when ca.isNotEmpty) {
    security.setTrustedCertificates(ca);
  }
  final raw = OpenAiCompatibleClient(
    config: config,
    auth: auth,
    httpClient: IOClient(HttpClient(context: security)),
  );
  await output.create(recursive: true);
  final catalogFile = File('test/fixtures/pose-hub-catalog.json');
  final catalog = Catalog.fromJson(
    jsonDecode(await catalogFile.readAsString()),
  );
  final results = <Json>[];
  final started = DateTime.now().toUtc();
  final sourceStart = await _sourceFingerprint();
  try {
    for (final c in chosen) {
      stdout.writeln('Running ${c['id']} (${config.model})');
      final caseSourceStart = await _sourceFingerprint();
      final result = await _runCase(c, raw, catalog);
      final caseSourceEnd = await _sourceFingerprint();
      result['sourceSha256'] = caseSourceStart;
      result['sourceUnchangedDuringCase'] = caseSourceStart == caseSourceEnd;
      if (caseSourceStart != caseSourceEnd) {
        (result['failures'] as List<String>).add('source changed during case');
        result['passed'] = false;
      }
      results.add(result);
      await _json(File('${output.path}/${c['id']}.json'), result);
      stdout.writeln(
        '${c['id']}: ${result['passed'] == true ? 'PASS' : 'FAIL'}; questions=${result['questions']}; ${result['failures']}',
      );
      final gap = int.tryParse(env['UGK_EVAL_GAP_SECONDS'] ?? '') ?? 0;
      if (gap > 0 && c != chosen.last) {
        await Future<void>.delayed(Duration(seconds: gap));
      }
    }
  } finally {
    raw.close();
  }
  final report = <String, Object?>{
    'schemaVersion': 1,
    'mode': 'real-CoachAgent',
    'startedAt': started.toIso8601String(),
    'finishedAt': DateTime.now().toUtc().toIso8601String(),
    'sourceSha256': sourceStart,
    'sourceUnchangedDuringRun': sourceStart == await _sourceFingerprint(),
    'sdkVersion': RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(await File('pubspec.yaml').readAsString())?.group(1),
    'requestedModel': config.model,
    'endpoint':
        '${Uri.parse(config.baseUrl).scheme}://${Uri.parse(config.baseUrl).host}${Uri.parse(config.baseUrl).path}',
    'authType': auth.runtimeType.toString(),
    'fixtureSha256': sha256.convert(await fixtureFile.readAsBytes()).toString(),
    'catalogVersion': catalog.version,
    'catalogSha256': sha256.convert(await catalogFile.readAsBytes()).toString(),
    'agentOverrides': {
      'enableUserMemoryByCase': {
        for (final c in chosen)
          c['id'] as String: c['enableUserMemory'] == true,
      },
      'maxHistoryChars': 200000,
      'maxTurns': 20,
    },
    'passed': results.every((r) => r['passed'] == true),
    'passedCases': results.where((r) => r['passed'] == true).length,
    'totalCases': results.length,
    'cases': results,
    'limitations': [
      '每例单次运行，不代表稳定成功率或延迟保证。',
      'SDK 真实模型路径；未经过 App UI 或 App 额外计划校验。',
      '三问上限的恶意重复调用另由离线门禁测试验证；本评测记录模型实际是否耗尽预算。',
    ],
  };
  await _json(File('${output.path}/summary.json'), report);
  stdout.writeln('Evidence: ${output.absolute.path}/summary.json');
  if (report['passed'] != true) exitCode = 1;
}

Future<AuthProvider> _auth(Map<String, String> env) async {
  if (env['UGK_API_KEY'] case final String key when key.isNotEmpty) {
    return ApiKeyAuth(key);
  }
  var appKey = env['UGK_APP_KEY'] ?? '';
  if (env['UGK_APP_KEY_FILE'] case final String path when appKey.isEmpty) {
    final source = await _readAuthFile(path, 'Worker App Key');
    final matches = RegExp(
      r'''X-App-Key['"`]?\s*[:=：]\s*['"`]?([^\s'"`]+)''',
      caseSensitive: false,
    ).allMatches(source).toList();
    if (matches.length == 1) {
      appKey = matches.single.group(1)!;
    } else if (matches.isEmpty && !source.contains(RegExp(r'\s'))) {
      appKey = source;
    } else {
      throw StateError('Worker key file must contain exactly one App Key.');
    }
  }
  if (appKey.isNotEmpty) {
    var device = env['UGK_DEVICE_ID'] ?? '';
    if (env['UGK_DEVICE_FILE'] case final String path when device.isEmpty) {
      device = await _readAuthFile(path, 'Worker device ID');
    }
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    ).hasMatch(device)) {
      throw StateError('An existing UUIDv4 Worker device ID is required.');
    }
    return UgkWorkerAuth(appKey: appKey, deviceId: () async => device);
  }
  throw StateError(
    'Inject UGK_API_KEY or the existing Worker App Key and device ID.',
  );
}

Future<String> _readAuthFile(String path, String label) async {
  try {
    return (await File(path).readAsString()).trim();
  } on FileSystemException {
    // FileSystemException.toString() includes the original local path.
    throw StateError(
      'Could not read $label file; check the environment setting.',
    );
  }
}

Future<String> _sourceFingerprint() async {
  final paths = [
    for (final file in Directory('lib').listSync(recursive: true))
      if (file is File && file.path.endsWith('.dart')) file.path,
    for (final file in Directory('profiles').listSync())
      if (file is File && file.path.endsWith('.json')) file.path,
    'pubspec.yaml',
    'tool/eval_ask_user.dart',
    'eval/cases/ask_user.json',
  ]..sort();
  final bytes = BytesBuilder(copy: false);
  for (final path in paths) {
    bytes.add(utf8.encode(path.replaceAll('\\', '/')));
    bytes.addByte(0);
    bytes.add(await File(path).readAsBytes());
    bytes.addByte(0);
  }
  return sha256.convert(bytes.takeBytes()).toString();
}

Future<Json> _runCase(Json c, LlmClient raw, Catalog catalog) async {
  final profile = CoachProfile.fromJson(
    jsonDecode(await File('profiles/${c['profile']}.json').readAsString()),
  );
  final client = _ObservedClient(raw);
  // Multi-turn plans retain prior tool payloads. Raising only the conversation
  // storage ceiling prevents an unrelated 40k-char limit from hiding turn 4.
  final agent = CoachAgent(
    client: client,
    catalog: () => catalog,
    profile: profile,
    enableUserMemory: c['enableUserMemory'] == true,
    maxHistoryChars: 200000,
  );
  final context = _context((c['context'] as Json?) ?? {});
  final events = <AgentEvent>[];
  final subscription = agent.events.listen(events.add);
  final failures = <String>[];
  final turns = <Json>[];
  final expected = Map<String, dynamic>.from(c['expect'] as Map);
  final known = <String>{
    if (context.scene != null) 'scene',
    if (context.minutes != null) 'duration',
    if (context.level != null) 'level',
    if (context.avoid.isNotEmpty) 'pain',
  };
  var text = c['message'] as String;
  var questions = 0, clickedAnswers = 0;
  TrainingPlan? finalPlan;
  String finalText = '';
  final watch = Stopwatch()..start();
  try {
    for (var turn = 0; turn < 5; turn++) {
      events.clear();
      final before = client.calls.length;
      final result = await agent.send(text, context: context);
      final question = result.question;
      final plan = result.plan?.plan;
      final calls = client.calls.sublist(before);
      final questionEvents = events
          .where((e) => e.kind == AgentEventKind.askUser)
          .toList();
      turns.add({
        'user': text,
        'status': result.status.name,
        'text': result.text,
        'question': question?.toJson(),
        'plan': plan?.toJson(),
        'steps': result.steps,
        'reads': result.reads,
        'questionsAsked': agent.questionsAsked,
        'events': [
          for (final e in events)
            {
              'kind': e.kind.name,
              'step': e.step,
              if (e.question != null) 'question': e.question!.toJson(),
            },
        ],
        'calls': calls,
        'usage': result.usage.toJson(),
        'issues': result.issues.map((i) => i.code).toList(),
      });
      if (result.status != TurnStatus.ok) {
        failures.add('turn ${turn + 1}: status=${result.status.name}');
      }
      if (turn == 0 &&
          (c['first'] == 'question' ? question == null : plan == null)) {
        failures.add('first result must be ${c['first']}');
      }
      if (question != null) {
        questions++;
        if (plan != null || result.actions != null) {
          failures.add('question and cards in one turn');
        }
        if (questionEvents.length != 1 ||
            jsonEncode(questionEvents.single.question?.toJson()) !=
                jsonEncode(question.toJson())) {
          failures.add('typed askUser event missing or mismatched');
        }
        if (events.isEmpty || events.last.kind != AgentEventKind.done) {
          failures.add('askUser must finish with done');
        }
        if (agent.isBusy) failures.add('agent still busy after question');
        if (result.reads.isNotEmpty) {
          failures.add('question turn read a skill or library file');
        }
        if (result.steps != 1 || calls.length != 1) {
          failures.add('question turn must finish in one model call');
        }
        if (agent.questionsAsked != questions) {
          failures.add('question counter mismatch');
        }
        if (questions > 3) {
          failures.add('exceeded three-question task limit');
          break;
        }
        final topic = _topic(question.question, question.options);
        if (known.contains(topic)) {
          failures.add('repeated known topic: $topic');
        }
        if (c['response'] == 'choice' && question.mode == AskUserMode.choice) {
          final choice = _choice(question.options, question.multiple, topic);
          text = choice.join('、');
          clickedAnswers++;
          _facts(expected, text, topic);
          known.add(topic);
        } else {
          text = c['answer'] as String? ?? _answer(topic);
          if (c['answerFacts'] case final Map<String, dynamic> facts) {
            expected.addAll(Map<String, dynamic>.from(facts));
          }
          if (c['answer'] == null) {
            _facts(expected, text, topic);
            known.add(topic);
          }
        }
        if (questions > (expected['maxQuestions'] as int? ?? 3)) {
          failures.add('unexpected extra question');
          break;
        }
        continue;
      }
      if (questionEvents.isNotEmpty) {
        failures.add('askUser event without question result');
      }
      finalPlan = plan;
      finalText = result.text;
      if (plan != null && agent.questionsAsked != 0) {
        failures.add('successful plan did not clear question budget');
      }
      break;
    }
    if (questions < (expected['minQuestions'] as int? ?? 0) ||
        questions > (expected['maxQuestions'] as int? ?? 3)) {
      failures.add('question count outside case expectation');
    }
    if (expected['requireChoiceAnswer'] == true && clickedAnswers == 0) {
      failures.add('no actual choice option selected');
    }
    if (finalPlan == null) {
      failures.add('no final validated plan');
    } else {
      _assertPlan(finalPlan, finalText, catalog, expected, questions, failures);
    }
  } finally {
    watch.stop();
    await subscription.cancel();
    await agent.dispose();
  }
  return {
    'id': c['id'],
    'title': c['title'],
    'passed': failures.isEmpty,
    'failures': failures,
    'questions': questions,
    'enableUserMemory': c['enableUserMemory'] == true,
    'budgetExhausted': questions == 3,
    'choiceAnswers': clickedAnswers,
    'elapsedMs': watch.elapsedMilliseconds,
    'turns': turns,
    'appliedAnswerExpectations': expected,
  };
}

CoachContext _context(Json j) => CoachContext(
  scene: j['scene'] as String?,
  equipment: (j['equipment'] as List?)?.cast<String>().toSet(),
  avoid: (j['avoid'] as List? ?? []).cast<String>().toSet(),
  level: j['level'] as int?,
  minutes: j['minutes'] as int?,
  goal: j['goal'] as String?,
  notes: (j['notes'] as List? ?? []).cast<String>(),
);

String _topic(String question, List<String> options) {
  if (RegExp('多久|多长|分钟|时长|时间').hasMatch(question)) return 'duration';
  if (RegExp('疼|痛|不适|受伤|伤病|麻木').hasMatch(question)) return 'pain';
  if (RegExp('水平|新手|经验|练了|入门|基础').hasMatch(question)) return 'level';
  if (RegExp(
    '部位|紧|僵硬|重点|肩颈|髋|放松哪',
  ).hasMatch('$question ${options.join(' ')}')) {
    return 'focus';
  }
  if (RegExp('哪里|哪儿|地点|场地|器械|工具|在家|健身房').hasMatch(question)) return 'scene';
  return 'other';
}

List<String> _choice(List<String> options, bool multiple, String topic) {
  final preferred = switch (topic) {
    'duration' => RegExp('12|15|10'),
    'scene' => RegExp('在家|家里|居家|家中'),
    'pain' => RegExp('没有|无|不疼|都不'),
    'level' => RegExp('新手|入门|初级|初学'),
    'focus' => RegExp('肩|颈|髋屈|髂腰|髋前|髋'),
    _ => RegExp('.'),
  };
  final matches = options.where(preferred.hasMatch).toList();
  return matches.isEmpty
      ? [options.first]
      : multiple
      ? matches.take(2).toList()
      : [matches.first];
}

String _answer(String topic) => switch (topic) {
  'duration' => '12 分钟',
  'scene' => '在家，只有垫子',
  'pain' => '没有疼痛或不适',
  'level' => '入门水平',
  'focus' => '肩颈、髋屈肌',
  _ => '在家，只有垫子，12 分钟，重点肩颈和髋屈肌，没有疼痛，入门水平。',
};

void _facts(Json expected, String answer, String topic) {
  if (topic == 'duration') {
    final values = RegExp(
      r'\d+',
    ).allMatches(answer).map((m) => int.parse(m.group(0)!)).toList();
    if (values.isNotEmpty) {
      expected['minutes'] = [
        values.first,
        values.length > 1 ? values.last : values.first,
      ];
    }
  }
  if (topic == 'scene' && RegExp('家|居家').hasMatch(answer)) {
    expected['scene'] = 'home';
  }
  if (topic == 'scene' && answer.contains('只有垫子')) {
    expected['equipmentAllowed'] = ['mat', 'none'];
  }
  if (topic == 'level' && RegExp('新手|入门|初级|初学').hasMatch(answer)) {
    expected['level'] = 1;
  }
  if (topic == 'focus') {
    final hipFlexor = RegExp(
      '髋屈|髋前|髂腰|腰大|股直|hip.flex|iliopsoas|rectus.femoris',
      caseSensitive: false,
    ).hasMatch(answer);
    expected['focus'] = [
      if (RegExp('肩|颈').hasMatch(answer)) 'shoulder',
      if (hipFlexor)
        'hip-flexor'
      else if (RegExp('髋|hip', caseSensitive: false).hasMatch(answer))
        'hip',
    ];
  }
}

void _assertPlan(
  TrainingPlan p,
  String text,
  Catalog catalog,
  Json e,
  int questions,
  List<String> failures,
) {
  if (e['scene'] != null && p.scene != e['scene']) {
    failures.add('scene did not use user answer');
  }
  if (e['level'] != null && p.level != e['level']) {
    failures.add('level did not use user answer');
  }
  if (e['minutes'] case final List<dynamic> range) {
    if (p.targetMinutes < (range[0] as num) ||
        p.targetMinutes > (range[1] as num)) {
      failures.add('duration did not use user answer');
    }
  }
  if (e['goals'] case final List<dynamic> goals) {
    if (!goals.contains(p.goal)) {
      failures.add('wrong plan goal: ${p.goal}');
    }
  }
  if (e['avoid'] case final List<dynamic> avoid) {
    if (!p.avoid.containsAll(avoid)) {
      failures.add('plan omitted known discomfort');
    }
  }
  if (e['equipmentAllowed'] case final List<dynamic> allowed) {
    for (final item in p.items) {
      if (!catalog[item.exerciseId]!.equipment.every(allowed.contains)) {
        failures.add('equipment did not use user answer');
      }
    }
  }
  // Use selected actions' names and muscle metadata, not a claim in plan.notes.
  final targets = p.items
      .map(
        (i) =>
            '${catalog[i.exerciseId]!.name.of()} ${catalog[i.exerciseId]!.muscles.join(' ')}',
      )
      .join(' ');
  for (final focus in e['focus'] as List? ?? []) {
    final pattern = switch (focus) {
      'shoulder' => RegExp(
        '肩|颈|斜方|neck|shoulder|trapezius|deltoid',
        caseSensitive: false,
      ),
      'hip' => RegExp(
        '髋|髂|腰大|股直|hip|iliopsoas|rectus.femoris',
        caseSensitive: false,
      ),
      'hip-flexor' => RegExp(
        'hip.flex|髋屈|髋前|髂腰|腰大|股直|iliopsoas|rectus.femoris',
        caseSensitive: false,
      ),
      'core' => RegExp('腹|核心|躯干|abdom|core|oblique', caseSensitive: false),
      _ => RegExp(focus as String),
    };
    if (!pattern.hasMatch(targets)) {
      failures.add('selected actions did not target $focus');
    }
  }
  final shouldExplain =
      e['assumptions'] == true ||
      e['assumptionsAtCap'] == true && questions == 3;
  if (shouldExplain &&
      !RegExp(
        '默认|假设|先按|暂按|按.*(?:分钟|居家|水平)|未提供|未说明',
      ).hasMatch('$text ${p.summary} ${p.notes.join(' ')}')) {
    failures.add('default assumptions not explained');
  }
}

class _ObservedClient implements LlmClient {
  _ObservedClient(this.inner);
  final LlmClient inner;
  final calls = <Json>[];
  @override
  String get model => inner.model;
  @override
  Pricing? get pricing => inner.pricing;
  @override
  Future<LlmResponse> complete(
    LlmRequest request, {
    CancelToken? cancel,
  }) async {
    final at = DateTime.now().toUtc();
    final watch = Stopwatch()..start();
    try {
      final response = await inner.complete(request, cancel: cancel);
      calls.add({
        'at': at.toIso8601String(),
        'model': response.model ?? model,
        'elapsedMs': watch.elapsedMilliseconds,
        'tools': response.toolCalls.map((c) => c.name).toList(),
        'usage': response.usage.toJson(),
        'finishReason': response.finishReason,
      });
      return response;
    } on LlmException catch (error) {
      calls.add({
        'at': at.toIso8601String(),
        'model': model,
        'elapsedMs': watch.elapsedMilliseconds,
        'errorKind': error.kind.name,
      });
      rethrow;
    }
  }
}

Future<void> _json(File file, Object data) =>
    file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
