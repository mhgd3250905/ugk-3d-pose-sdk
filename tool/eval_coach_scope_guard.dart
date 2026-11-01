/// Fixed live conversations with the same playback builders as the hosts.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/eval_coach_scope_guard.dart --host smartfit|hiplab '
      '--out NEW_SDK_BUILD_DIR [--case name1,name2] [--host-root DIR] [--thinking on|off] [--dry]',
    );
    return;
  }
  try {
    await _run(args);
  } on Object catch (error) {
    stderr.writeln('Evaluation stopped: ${error.runtimeType}');
    exitCode = 2;
  }
}

Future<void> _run(List<String> args) async {
  final options = <String, String>{};
  var dry = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dry') {
      dry = true;
      continue;
    }
    if (!{
          '--host',
          '--out',
          '--case',
          '--host-root',
          '--thinking',
        }.contains(args[i]) ||
        options.containsKey(args[i]) ||
        i + 1 >= args.length ||
        args[i + 1].startsWith('--')) {
      throw ArgumentError('Invalid option');
    }
    final flag = args[i];
    options[flag] = args[++i];
  }
  final host = options['--host'] ?? 'smartfit';
  if (!{'smartfit', 'hiplab'}.contains(host)) {
    throw ArgumentError('Unknown host');
  }
  final thinking = options['--thinking'] ?? 'on';
  if (!{'on', 'off'}.contains(thinking)) {
    throw ArgumentError('Unknown thinking mode');
  }
  final sdk = File.fromUri(Platform.script).parent.parent;
  final hostRoot =
      options['--host-root'] ??
      (host == 'smartfit'
          ? r'E:\AII-3D\3D-Sport-AI\Sport-Helper-coach-ui-kit'
          : r'E:\AII-3D\3D-Hip-worktrees\coach-v2\3D-Hip');
  final output = Directory.fromUri(
    Directory(
      options['--out'] ?? (throw ArgumentError('Explicit output required')),
    ).absolute.uri.normalizePath(),
  );
  if (!output.uri.toString().toLowerCase().startsWith(
    sdk.uri.resolve('build/').toString().toLowerCase(),
  )) {
    throw StateError('Output must be inside SDK build');
  }
  var ancestor = output;
  while (!ancestor.existsSync()) {
    ancestor = ancestor.parent;
  }
  if (!Directory(
    ancestor.resolveSymbolicLinksSync(),
  ).uri.toString().toLowerCase().startsWith(
    Directory(sdk.resolveSymbolicLinksSync()).uri.toString().toLowerCase(),
  )) {
    throw StateError('Output escapes SDK');
  }
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError('Output already contains a run');
  }
  await output.create(recursive: true);
  final original = File(
    '${sdk.path}/packages/ugk_trainer/.dart_tool/package_config.json',
  );
  final config =
      jsonDecode(await original.readAsString()) as Map<String, dynamic>;
  final roots = {
    'ugk_coach': sdk.uri,
    'ugk_trainer': Directory('${sdk.path}/packages/ugk_trainer').uri,
    'ugk_trainer_runtime': Directory(
      '${sdk.path}/packages/ugk_trainer_runtime',
    ).uri,
  };
  final packageConfig = File('${output.path}/packages.json');
  await packageConfig.writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        for (final raw in config['packages'] as List)
          if ((raw as Map)['name'] != host)
            {
              ...raw,
              'rootUri':
                  (roots[raw['name']] ??
                          original.uri.resolve(raw['rootUri'] as String))
                      .toString(),
            },
        {
          'name': host,
          'rootUri': Directory(hostRoot).absolute.uri.toString(),
          'packageUri': 'lib/',
          'languageVersion': '3.12',
        },
      ],
    }),
  );
  final bridge = File('${output.path}/host_bridge.dart.txt');
  await bridge.writeAsString(_bridge(host, sdk.path, hostRoot, output.path));
  final child = await Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${packageConfig.path}',
      bridge.path,
      '--thinking',
      thinking,
      if (options['--case'] case final String cases) ...['--case', cases],
      if (dry) '--dry',
    ],
    workingDirectory: sdk.path,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await child.exitCode;
}

String _literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');

String _bridge(String host, String sdk, String app, String output) =>
    '''
import 'dart:convert';
import 'dart:io';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer/engine.dart' as trainer;
import ${_literal(File('$sdk/tool/coach_scope_guard_evaluation.dart').uri.toString())} as gate;
${host == 'smartfit' ? """
import 'package:smartfit/app/app_test_catalog.dart' as sf_catalog;
import 'package:smartfit/app/app_test_content.dart' as sf_content;
import 'package:smartfit/domain/exercise.dart' as sf_exercise;
import 'package:smartfit/domain/plan.dart' as sf_plan;
import 'package:smartfit/domain/session.dart' as sf_session;
""" : 'import ${_literal(File('$app/tools/coach/coach_v2_native_metrics.dart').uri.toString())} as hip_metrics;'}
const host = ${_literal(host)};
const sdkRoot = ${_literal(sdk)};
const hostRoot = ${_literal(app)};
const output = ${_literal(output)};
Map<String,dynamic> readJson(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String,dynamic>;
Future<void> main(List<String> args) async {
  final profile = coach.CoachProfile.fromJson(readJson('\$hostRoot/assets/coach/\$host.json'));
  late coach.Catalog catalog;
  late trainer.SessionBuilder builder;
  late bool Function(coach.TrainingPlan) matchesHost;
  ${host == 'smartfit' ? _smartfit : _hiplab}
  $_scope
  Map<String,Object?> measure(coach.TrainingPlan plan) {
    if (!matchesHost(plan)) throw StateError('Host and callback timelines differ');
    final timing = coach.evaluatePlanExecutionTiming(plan, builder.executionTiming);
    final card = const coach.PlanDuration().estimateSeconds(plan,catalog);
    final target = plan.targetMinutes * 60;
    return {'targetSeconds':target,'cardSeconds':card,'executionSeconds':timing.totalSeconds,
      'cardDeviationPercent':(card-target)/target*100,
      'executionDeviationPercent':(timing.totalSeconds-target)/target*100,
      'isEstimate':timing.containsManualCounting,
      'manualCountingLabel':timing.containsManualCounting?'估算':null};
  }
  await gate.runScopeEvaluation(args, outputPath:output,
    host:gate.ScopeEvaluationHost(id:host,root:hostRoot,catalog:catalog,measure:measure,
      builder:${_literal(host == 'smartfit' ? 'SF AppTestContent / trainerRhythms / prep10 / App SessionBuilder' : 'Hip original catalog+kit+voice / prep15 / native timeline')}));
}
''';

const _scope = r'''
  final masterBytes = File('$sdkRoot/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync();
  final fixture = readJson('$sdkRoot/test/fixtures/action-scope/${host == 'smartfit' ? 'smartfit-219' : 'hiplab-candidate-45'}.json');
  final manifest = coach.CoachActionScopeManifest.fromCatalogBytes(
    appId:host,catalogBytes:masterBytes,
    allowedActionIds:(fixture['allowedActionIds'] as List).cast<String>());
  final scope = manifest.restrict(catalog:catalog,profile:profile);
  gate.installScopeEvaluationBinding(gate.ScopeEvaluationBinding(
    authorizedIds:manifest.allowedActionIds,plannableIds:scope.plannableIds,candidate:host=='hiplab',
    createAgent:(client,onSpan)=>coach.CoachAgent(client:client,catalog:()=>catalog,profile:profile,
      scopeManifest:manifest,
      scopePolicy:coach.CoachScopeConversationPolicy(
        specialty:host=='hiplab'?'本 App 专注开胯、髋部与臀部训练':'本 App 提供全身训练、拉伸与灵活性训练',
        suggestions:['大腿内侧拉伸','轻柔髋部活动']),
      executionTiming:builder.executionTiming,onSpan:onSpan,maxRequestRetries:0,appId:host),
    scopeRecords:(agent)=>[for(final record in agent.scopeRecords)record.toJson()]));
''';

const _hiplab = r'''
  catalog = coach.Catalog.fromJson(readJson('$hostRoot/assets/coach/catalog.json'));
  final kits = <String,Map<String,dynamic>>{};
  for(final path in readJson('$hostRoot/assets/action_kits/index.json')['kits'] as List) {
    final kit = readJson('$hostRoot/$path');kits[kit['id'] as String]=kit;
  }
  final script = trainer.SessionScript(lang:'zh',source:trainer.ManifestVoiceSource.fromJson(
    readJson('$hostRoot/assets/voice/manifest.json'),kitVoices:{for(final e in kits.entries)e.key:trainer.KitVoice.fromActionKitJson(e.value)}));
  builder = trainer.SessionBuilder(prepSeconds:15,transitionSeconds:15,
    rhythms:{for(final e in kits.entries)e.key:trainer.Rhythm.fromActionKitJson(e.value)},switchSecondsFor:script.switchSecondsFor);
  final previous = Directory.current;
  late final dynamic content;
  try {Directory.current=hostRoot;content=hip_metrics.loadCoachMetricContent();}
  finally {Directory.current=previous;}
  matchesHost=(plan) {
    final value=hip_metrics.measureCoachPlanTiming(plan:plan,content:content,catalog:catalog,executionBuilder:builder);
    return value['nativeTotalSeconds']==builder.executionTiming(plan).totalSeconds && value['completePlanPreserved']==true;
  };
''';

const _smartfit = r'''
  final delivery=readJson('$sdkRoot/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json');
  final metadata=coach.PoseHubAppTestCatalog.fromJson(delivery);
  final sdkCatalog=coach.PoseHubAppTestCatalog.fromJson(delivery,semanticCatalog:
    readJson('$sdkRoot/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/${metadata.semanticCatalogFile.path}'));
  final content=sf_content.AppTestContent.build(catalog:sf_catalog.AppTestCatalog.fromSdk(sdkCatalog),legacyLibrary:sf_exercise.ExerciseLibrary(const []));
  catalog=content.coachCatalog;
  builder=trainer.SessionBuilder(prepSeconds:10,rhythms:sf_session.trainerRhythms(content.library),known:content.library.contains);
  matchesHost=(plan) {
    final app=sf_session.SessionBuilder(content.library).phases(sf_plan.TrainingPlan.fromJson(plan.toJson()));
    final sdk=builder.phases(plan);
    if(app.length!=sdk.length)return false;
    for(var i=0;i<app.length;i++) {
      final a=app[i],b=sdk[i];
      if(a.kind!=b.kind || a.seconds!=b.seconds || a.exerciseId!=b.exerciseId ||
        a.blockIndex!=b.blockIndex || a.set!=b.set || a.round!=b.round ||
        a.side!=b.side || a.selfPaced!=b.selfPaced || a.segmentId!=b.segmentId)return false;
    }
    return true;
  };
''';
