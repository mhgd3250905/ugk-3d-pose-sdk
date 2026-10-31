// Offline configuration loading happens before the synchronous timing callback.
// No phase math is duplicated here: host bridges call SessionBuilder.phases.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/io_client.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'eval_api_config.dart';
import 'eval_coach_agent_v2.dart' show EvaluationRedactor, EvaluationWireClient;
import 'eval_thinking_mode.dart';

typedef GateJson = Map<String, Object?>;

class ExecutedDurationHost {
  const ExecutedDurationHost({
    required this.id,
    required this.root,
    required this.sdkRoot,
    required this.profile,
    required this.catalog,
    required this.executionTiming,
    required this.measure,
    required this.provenance,
  });
  final String id;
  final String root;
  final String sdkRoot;
  final CoachProfile profile;
  final Catalog catalog;
  final PlanExecutionTimingCallback executionTiming;
  final GateJson Function(TrainingPlan) measure;
  final GateJson provenance;
}

Future<void> runExecutedDurationGate(
  List<String> args, {
  required ExecutedDurationHost host,
  required String outputPath,
}) async {
  final output = Directory(outputPath);
  final modeIndex = args.indexOf('--thinking');
  final thinking = parseEvaluationThinkingMode(
    modeIndex < 0 ? null : args[modeIndex + 1],
  );
  final cases = [
    for (var index = 1; index <= 5; index++) (id: 'five-$index', minutes: 5),
    (id: 'ten-1', minutes: 10),
    (id: 'twenty-1', minutes: 20),
  ];
  List<String> inputs(int minutes) => host.id == 'hiplab'
      ? [
          '在家开胯10分钟入门',
          '推荐几个拉大腿内侧的动作',
          minutes == 5 ? '换一套，缩短到5分钟' : '换一套，改成$minutes分钟',
        ]
      : [
          '在家拉伸10分钟，入门，徒手和瑜伽垫，重点大腿内侧和髋部，无不适',
          '推荐几个拉大腿内侧的动作',
          '换一套，改成$minutes分钟',
        ];
  final runMetadata = <String, Object?>{
    'schemaVersion': 1,
    'host': host.id,
    'hostRoot': host.root,
    'provenance': host.provenance,
    'thinkingMode': thinking.name,
    'executionMeasurement': 'same SessionBuilder.phases used by the callback',
    'manualCountingClassification': 'estimate; numeric gate still enforced',
    'simulatedSupplementaryUserFacts': false,
    'independentConversations': cases.length,
    'cases': [
      for (final item in cases)
        {
          'id': item.id,
          'targetMinutes': item.minutes,
          'inputs': inputs(item.minutes),
        },
    ],
    'retries': 0,
    'resampling': false,
    'deviceOperated': false,
  };
  await _writeJson(File('${output.path}/run.json'), runMetadata);
  if (args.contains('--dry')) {
    final drill = host.catalog.drills.first;
    final dose = drill.defaultDose;
    final sample = TrainingPlan(
      id: 'dry-host-timing',
      source: 'evaluation',
      title: 'Dry host timeline assertion',
      goal: 'relax',
      scene: 'home',
      equipment: const [],
      level: 1,
      targetMinutes: 5,
      blocks: [
        PlanBlock(
          id: 'main',
          name: 'main',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: drill.id,
              mode: dose.mode,
              sets: dose.sets,
              reps: dose.reps,
              workSeconds: dose.seconds,
              perSide: drill.unilateral,
              restSeconds: dose.restSeconds,
            ),
          ],
        ),
      ],
    );
    final timing = evaluatePlanExecutionTiming(sample, host.executionTiming);
    await _writeJson(File('${output.path}/summary.json'), {
      ...runMetadata,
      'mode': 'dry-configuration-and-timeline-validation',
      'modelCalls': 0,
      'sampleExecutionSeconds': timing.totalSeconds,
      'sampleMeasurement': host.measure(sample),
      'gatePassed': null,
    });
    stdout.writeln('${host.id}: dry complete; modelCalls=0.');
    return;
  }

  final redactor = EvaluationRedactor([ToolPromptBuilder().canary]);
  if ((Platform.environment['UGK_BASE_URL'] != null &&
          Platform.environment['UGK_BASE_URL'] != evaluationBaseUrl) ||
      (Platform.environment['UGK_MODEL'] != null &&
          Platform.environment['UGK_MODEL'] != evaluationModel)) {
    throw StateError('Retain the approved evaluation route and model');
  }
  final key = await readEvaluationApiKey(Platform.environment);
  redactor.secrets.add(key);
  final config = evaluationLlmConfig(thinking);
  redactor.secrets.add(config.baseUrl);
  final security = SecurityContext(withTrustedRoots: true);
  final certificate = Platform.environment['SSL_CERT_FILE'];
  if (certificate != null && certificate.isNotEmpty) {
    security.setTrustedCertificates(certificate);
  }
  final journal = File('${output.path}/timeline.jsonl').openWrite();
  void append(GateJson row) => journal.writeln(jsonEncode(redactor.clean(row)));
  final results = <GateJson>[];
  final sdkFingerprint = _sdkSourceFingerprint(host.sdkRoot);
  final allWatch = Stopwatch()..start();
  try {
    for (final item in cases) {
      final sourceBefore = _sdkSourceFingerprint(host.sdkRoot);
      final hostUnchangedBefore = _hostSourcesUnchanged(host.provenance);
      stdout.writeln(
        '${host.id}/${item.id}: starting independent conversation.',
      );
      final calls = EvaluationWireClient(
        IOClient(HttpClient(context: security)),
        redactor,
        (row) => append({'case': item.id, ...row}),
      );
      final client = OpenAiCompatibleClient(
        config: config,
        auth: ApiKeyAuth(key),
        httpClient: calls,
      );
      final agent = CoachAgent(
        client: client,
        catalog: () => host.catalog,
        profile: host.profile,
        executionTiming: host.executionTiming,
        maxRequestRetries: 0,
        appId: '${host.id}-executed-duration-evaluation',
      );
      final conversation = CoachConversationController(agent: agent);
      calls.onBadRequest = conversation.cancel;
      calls.onModelMismatch = conversation.cancel;
      final watch = Stopwatch()..start();
      final turns = <GateJson>[];
      final events = agent.events.listen((event) {
        if (event.kind == AgentEventKind.thinking) calls.agentStep = event.step;
      });
      try {
        for (final (index, input) in inputs(item.minutes).indexed) {
          final turnWatch = Stopwatch()..start();
          final callsBefore = calls.calls.length;
          calls.turn = index + 1;
          final reply = await conversation.send(input);
          turnWatch.stop();
          final plan = reply?.plan?.plan;
          final row = <String, Object?>{
            'turn': index + 1,
            'input': input,
            'status': reply?.status.name,
            'modelCalls': calls.calls.length - callsBefore,
            'elapsedMs': turnWatch.elapsedMilliseconds,
            'text': reply?.text,
            'question': reply?.question?.toJson(),
            'isPlanningFailure': reply?.isPlanningFailure,
            'errorType': reply?.error?.runtimeType.toString(),
            if (plan != null) ...{
              'plan': plan.toJson(),
              'timing': host.measure(plan),
              'savedVersion': agent.sessionState.plans[plan.id]?.last.toJson(),
            },
          };
          turns.add(row);
          append({'case': item.id, 'recordType': 'turn-result', ...row});
          // No answer/retry is manufactured for a rejected or failed turn.
          if (reply?.question != null || reply?.error != null) break;
        }
      } on Object catch (error) {
        turns.add({
          'errorType': error.runtimeType.toString(),
          'status': 'exception',
        });
      } finally {
        watch.stop();
        await events.cancel();
        await conversation.dispose();
        client.close();
      }
      final finalTurn = turns.isEmpty ? <String, Object?>{} : turns.last;
      final timing = finalTurn['timing'] as Map<String, Object?>?;
      final routeMatches =
          calls.calls.isNotEmpty &&
          calls.calls.every((row) => row['modelMatchesRequest'] == true);
      final sourceUnchanged =
          sourceBefore == _sdkSourceFingerprint(host.sdkRoot);
      final passed =
          turns.length == 3 &&
          finalTurn['turn'] == 3 &&
          timing?['targetSeconds'] == item.minutes * 60 &&
          timing?['cardWithinTolerance'] == true &&
          timing?['executionWithinTolerance'] == true &&
          timing?['timelineAssertionPassed'] == true &&
          routeMatches &&
          sourceUnchanged &&
          hostUnchangedBefore &&
          _hostSourcesUnchanged(host.provenance);
      final result = <String, Object?>{
        'id': item.id,
        'host': host.id,
        'targetMinutes': item.minutes,
        'modelCalls': calls.calls.length,
        'elapsedMs': watch.elapsedMilliseconds,
        'finalTurnModelCalls': finalTurn['modelCalls'],
        'finalTurnElapsedMs': finalTurn['elapsedMs'],
        'cardSeconds': timing?['cardSeconds'],
        'executionSeconds': timing?['executionSeconds'],
        'isEstimate': timing?['isEstimate'],
        'routeMatches': routeMatches,
        'sdkSourceSha256': sourceBefore,
        'sourceUnchangedDuringCase': sourceUnchanged,
        'hostSourcesUnchangedDuringCase':
            hostUnchangedBefore && _hostSourcesUnchanged(host.provenance),
        'gatePassed': passed,
        'turns': turns,
        'calls': calls.calls,
      };
      results.add(result);
      await _writeJson(
        File('${output.path}/${item.id}.json'),
        redactor.clean(result),
      );
      await journal.flush();
      stdout.writeln(
        '${host.id}/${item.id}: card=${result['cardSeconds']}, '
        'execution=${result['executionSeconds']}, calls=${calls.calls.length}, '
        'elapsedMs=${watch.elapsedMilliseconds}, passed=$passed.',
      );
    }
  } finally {
    allWatch.stop();
    await journal.flush();
    await journal.close();
  }
  final passed =
      results.length == 7 &&
      results.every((row) => row['gatePassed'] == true) &&
      sdkFingerprint == _sdkSourceFingerprint(host.sdkRoot) &&
      _hostSourcesUnchanged(host.provenance);
  final summary = <String, Object?>{
    ...runMetadata,
    'mode': 'real-model-seven-independent-three-turn-conversations',
    'model': evaluationModel,
    'modelCalls': results.fold<int>(
      0,
      (sum, row) => sum + (row['modelCalls'] as int),
    ),
    'elapsedMs': allWatch.elapsedMilliseconds,
    'gatePassed': passed,
    'sdkSourceSha256': sdkFingerprint,
    'sourceUnchangedAcrossRun':
        sdkFingerprint == _sdkSourceFingerprint(host.sdkRoot),
    'hostSourcesUnchangedAcrossRun': _hostSourcesUnchanged(host.provenance),
    'cases': [
      for (final row in results)
        {
          for (final entry in row.entries)
            if (!{'turns', 'calls'}.contains(entry.key)) entry.key: entry.value,
        },
    ],
  };
  await _writeJson(File('${output.path}/summary.json'), summary);
  final markdown = StringBuffer()
    ..writeln('# ${host.id} executed-duration real gate')
    ..writeln()
    ..writeln(
      'Seven independent three-turn conversations; no resampling or supplementary replies. '
      'Manual phases remain estimates and still pass both numeric gates. '
      'No audio playback or device operation was performed.',
    )
    ..writeln()
    ..writeln(
      '| Case | Target s | Card s | Execution s | Estimate | Final calls | Final ms | All calls | All ms | Pass |',
    )
    ..writeln('|---|---:|---:|---:|---|---:|---:|---:|---:|---|');
  for (final row in results) {
    markdown.writeln(
      '| ${row['id']} | ${(row['targetMinutes'] as int) * 60} | '
      '${row['cardSeconds']} | ${row['executionSeconds']} | ${row['isEstimate']} | '
      '${row['finalTurnModelCalls']} | ${row['finalTurnElapsedMs']} | '
      '${row['modelCalls']} | ${row['elapsedMs']} | ${row['gatePassed']} |',
    );
  }
  await File('${output.path}/summary.md').writeAsString(markdown.toString());
  if (!passed) exitCode = 1;
}

Future<void> _writeJson(File file, Object? value) => file.writeAsString(
  '${const JsonEncoder.withIndent('  ').convert(value)}\n',
);

String _sdkSourceFingerprint(String sdkRoot) {
  final files = <File>[];
  for (final root in ['$sdkRoot/lib', '$sdkRoot/packages/ugk_trainer/lib']) {
    files.addAll(
      Directory(root)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
    );
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return sha256
      .convert(
        utf8.encode(
          files
              .map(
                (file) =>
                    '${file.path.substring(sdkRoot.length)}:${sha256.convert(file.readAsBytesSync())}',
              )
              .join('\n'),
        ),
      )
      .toString();
}

bool _hostSourcesUnchanged(GateJson provenance) {
  final files = provenance['filesSha256'] as Map<String, String>;
  return files.entries.every(
    (entry) =>
        File(entry.key).existsSync() &&
        sha256.convert(File(entry.key).readAsBytesSync()).toString() ==
            entry.value,
  );
}

/// Reads host code/configuration once, before making a synchronous callback.
/// The bridge is generated because Apps are read-only references, not package
/// dependencies of the pure Dart Coach SDK.
String executedDurationHostBridge({
  required String host,
  required String sdkRoot,
  required String hostRoot,
  required String output,
  required String helperUri,
}) {
  final imports = host == 'smartfit'
      ? '''
import 'package:smartfit/app/app_test_catalog.dart' as sf_catalog;
import 'package:smartfit/app/app_test_content.dart' as sf_content;
import 'package:smartfit/domain/exercise.dart' as sf_exercise;
import 'package:smartfit/domain/plan.dart' as sf_plan;
import 'package:smartfit/domain/session.dart' as sf_session;
'''
      : "import '${File('$hostRoot/tools/coach/coach_v2_native_metrics.dart').uri}' as hip_metrics;";
  return '''
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer/engine.dart' as trainer;
import '$helperUri' as gate;
$imports

const host = ${jsonEncode(host)};
const sdkRoot = ${jsonEncode(sdkRoot)};
const hostRoot = ${jsonEncode(hostRoot)};
const output = ${jsonEncode(output)};
final fingerprints = <String, String>{};

void recordSource(String path) {
  fingerprints[path] = sha256.convert(File(path).readAsBytesSync()).toString();
}

Map<String, dynamic> readJson(String path) {
  final bytes = File(path).readAsBytesSync();
  fingerprints[path] = sha256.convert(bytes).toString();
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}
String head(String root) {
  final result = Process.runSync('git', ['-C', root, 'rev-parse', 'HEAD']);
  if (result.exitCode != 0) throw StateError('Cannot resolve source HEAD');
  return (result.stdout as String).trim();
}

Future<void> main(List<String> args) async {
  final profile = coach.CoachProfile.fromJson(readJson('\$hostRoot/assets/coach/\$host.json'));
  recordSource('\$hostRoot/lib/${host == 'hiplab' ? 'hip/ui/hip_player_page.dart' : 'ui/player_page.dart'}');
  recordSource('\$hostRoot/lib/${host == 'hiplab' ? 'hip/coach/coach_service.dart' : 'chat/ai_chat_engine.dart'}');
  late coach.Catalog catalog;
  late trainer.SessionBuilder builder;
  bool Function(coach.TrainingPlan)? assertHostTimeline;
  ${host == 'hiplab' ? _hipBridgeSetup : _sfBridgeSetup}
  Map<String, Object?> measure(coach.TrainingPlan plan) {
    final timing = coach.evaluatePlanExecutionTiming(plan, builder.executionTiming);
    final phases = builder.phases(plan);
    final total = phases.fold<double>(0, (sum, phase) => sum + phase.seconds);
    final callbackMatches = (total - timing.totalSeconds).abs() <= 1e-9;
    if (!callbackMatches || !(assertHostTimeline?.call(plan) ?? true)) {
      throw StateError('Host callback and player timeline differ');
    }
    final target = plan.targetMinutes * 60.0;
    final card = const coach.PlanDuration().estimateSeconds(plan, catalog);
    final estimated = phases.any((phase) => phase.isWork && phase.selfPaced);
    double? visited;
    if (!estimated) {
      final engine = trainer.SessionEngine(phases)..update(total + .001);
      visited = engine.visits.fold<double>(0, (sum, visit) => sum + visit.seconds);
      if (!engine.done || (visited - total).abs() > 1e-6) {
        throw StateError('Natural engine visits differ from timeline');
      }
    }
    return {
      'targetSeconds': target,
      'cardSeconds': card,
      'executionSeconds': total,
      'cardWithinTolerance': (card - target).abs() <= target * .1 + 1e-9,
      'executionWithinTolerance': (total - target).abs() <= target * .1 + 1e-9,
      'isEstimate': estimated,
      'manualCountingLabel': estimated ? '估算' : null,
      'timelineAssertionPassed': callbackMatches,
      'naturalEngineVisitSeconds': visited,
      'blocks': [for (final block in timing.blocks) {'blockId': block.blockId, 'seconds': block.seconds}],
      'phases': [for (final phase in phases) {
        'kind': phase.kind.name, 'seconds': phase.seconds,
        'exerciseId': phase.exerciseId, 'blockIndex': phase.blockIndex,
        'round': phase.round, 'set': phase.set, 'side': phase.side?.name,
        'selfPaced': phase.selfPaced,
      }],
    };
  }
  await gate.runExecutedDurationGate(args,
    host: gate.ExecutedDurationHost(id: host, root: hostRoot, sdkRoot: sdkRoot, profile: profile,
      catalog: catalog, executionTiming: builder.executionTiming, measure: measure,
      provenance: {
        'sdkHead': head(sdkRoot), 'hostHead': head(hostRoot),
        'referenceMainRoot': ${jsonEncode(host == 'smartfit' ? r'E:\AII-3D\3D-Sport-AI\Sport-Helper' : hostRoot)},
        'referenceMainHead': head(${jsonEncode(host == 'smartfit' ? r'E:\AII-3D\3D-Sport-AI\Sport-Helper' : hostRoot)}),
        'filesSha256': fingerprints,
        'builder': ${jsonEncode(host == 'hiplab' ? 'HipPlayerPage SDK plan configuration: prep15, action-kit rhythms, zh ManifestVoiceSource+KitVoice switch timing' : 'AppTestContent.build + trainerRhythms(library), prep10, known=library.contains; assert App SessionBuilder.phases identical')},
      }), outputPath: output);
}
''';
}

const _hipBridgeSetup = r'''
  catalog = coach.Catalog.fromJson(readJson('$hostRoot/assets/coach/catalog.json'));
  final index = readJson('$hostRoot/assets/action_kits/index.json');
  final kits = <String, Map<String, dynamic>>{};
  for (final path in index['kits'] as List) {
    final kit = readJson('$hostRoot/$path');
    kits[kit['id'] as String] = kit;
  }
  final script = trainer.SessionScript(lang: 'zh', source:
    trainer.ManifestVoiceSource.fromJson(readJson('$hostRoot/assets/voice/manifest.json'),
      kitVoices: {for (final entry in kits.entries)
        entry.key: trainer.KitVoice.fromActionKitJson(entry.value)}));
  builder = trainer.SessionBuilder(prepSeconds: 15, transitionSeconds: 15,
    rhythms: {for (final entry in kits.entries)
      entry.key: trainer.Rhythm.fromActionKitJson(entry.value)},
    switchSecondsFor: script.switchSecondsFor);
  // Import the App's existing lossless plan adapter/native acceptance helper.
  // Loading assets is complete before the synchronous callback is installed.
  final previousDirectory = Directory.current;
  late final dynamic content;
  try {
    Directory.current = hostRoot;
    content = hip_metrics.loadCoachMetricContent();
  } finally {
    Directory.current = previousDirectory;
  }
  recordSource('$hostRoot/tools/coach/coach_v2_native_metrics.dart');
  recordSource('$hostRoot/lib/hip/voice/session_script.dart');
  recordSource('$hostRoot/lib/hip/domain/hip_session.dart');
  assertHostTimeline = (plan) {
    final metrics = hip_metrics.measureCoachPlanTiming(plan: plan,
      content: content, catalog: catalog, executionBuilder: builder);
    return metrics['nativeTotalSeconds'] == builder.executionTiming(plan).totalSeconds &&
      metrics['completePlanPreserved'] == true;
  };
''';

const _sfBridgeSetup = r'''
  final delivery = readJson('$sdkRoot/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json');
  // The SDK catalog exposes its verified semantic descriptor; its path remains
  // relative to the immutable delivery catalog, just like the App asset loader.
  final metadata = coach.PoseHubAppTestCatalog.fromJson(delivery);
  final semantic = readJson('$sdkRoot/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/${metadata.semanticCatalogFile.path}');
  final sdkCatalog = coach.PoseHubAppTestCatalog.fromJson(delivery, semanticCatalog: semantic);
  final content = sf_content.AppTestContent.build(
    catalog: sf_catalog.AppTestCatalog.fromSdk(sdkCatalog),
    legacyLibrary: sf_exercise.ExerciseLibrary(const []));
  recordSource('$hostRoot/lib/app/app_test_content.dart');
  recordSource('$hostRoot/lib/app/app_test_catalog.dart');
  recordSource('$hostRoot/lib/domain/session.dart');
  catalog = content.coachCatalog;
  builder = trainer.SessionBuilder(prepSeconds: 10,
    rhythms: sf_session.trainerRhythms(content.library), known: content.library.contains);
  assertHostTimeline = (plan) {
    final app = sf_session.SessionBuilder(content.library)
      .phases(sf_plan.TrainingPlan.fromJson(plan.toJson()));
    final sdk = builder.phases(plan);
    if (app.length != sdk.length) return false;
    for (var i = 0; i < app.length; i++) {
      final a = app[i], b = sdk[i];
      if (a.kind != b.kind || a.seconds != b.seconds ||
          a.exerciseId != b.exerciseId || a.blockIndex != b.blockIndex ||
          a.set != b.set || a.round != b.round || a.side != b.side ||
          a.selfPaced != b.selfPaced || a.segmentId != b.segmentId) return false;
    }
    return true;
  };
''';
