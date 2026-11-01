/// Launches fixed real-model scope/budget cases using read-only host builders.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'executed_duration_host_timing.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln('''
dart run tool/eval_coach_scope_guard.dart --host smartfit|hiplab --out SDK_BUILD_DIR
  [--host-root DIR] [--thinking on|off] [--dry]

SF: original seven independent three-turn conversations (5min x5, 10/20 x1).
Hip: candidate-only 45-ID fixture, fixed R1-R6 (R5 off/on; R4 two turns).
Every failed sample is retained. No rerun, resampling, supplementary user reply,
new timing estimator, App write, device operation or gateway/model substitution.
--dry validates scope/configuration and the actual host timeline; modelCalls=0.
''');
    return;
  }
  try {
    await _launch(args);
  } on Object catch (error) {
    stderr.writeln('Scope evaluation stopped: ${error.runtimeType}.');
    stderr.writeln(
      'No credentials or exception body are printed. Inspect local evidence.',
    );
    exitCode = 2;
  }
}

Future<void> _launch(List<String> args) async {
  String? option(String flag) {
    final index = args.indexOf(flag);
    if (index < 0) return null;
    if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
      throw ArgumentError('Missing option value');
    }
    return args[index + 1];
  }

  const flags = {'--host', '--out', '--host-root', '--thinking'};
  final observed = <String>{};
  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    if (flag == '--dry') continue;
    if (!flags.contains(flag) || !observed.add(flag)) {
      throw ArgumentError('Unknown or repeated option');
    }
    option(flag);
    i++;
  }
  final host = option('--host') ?? 'smartfit';
  if (!{'smartfit', 'hiplab'}.contains(host)) {
    throw ArgumentError('Unknown host');
  }
  final thinking = option('--thinking') ?? 'on';
  if (!{'on', 'off'}.contains(thinking)) {
    throw ArgumentError('Unknown thinking mode');
  }
  final sdkRoot = File.fromUri(Platform.script).parent.parent;
  final defaultHost = host == 'smartfit'
      ? r'E:\AII-3D\3D-Sport-AI\Sport-Helper-coach-ui-kit'
      : r'E:\AII-3D\3D-Hip-worktrees\coach-v2\3D-Hip';
  final hostRoot = Directory(option('--host-root') ?? defaultHost).absolute;
  if (!File('${hostRoot.path}/pubspec.yaml').existsSync()) {
    throw StateError('Read-only host checkout is unavailable');
  }
  final outputArgument = option('--out');
  if (outputArgument == null) {
    throw ArgumentError('An explicit output is required');
  }
  final output = Directory.fromUri(
    Directory(outputArgument).absolute.uri.normalizePath(),
  );
  final allowed = sdkRoot.absolute.uri
      .resolve('build/')
      .normalizePath()
      .toString()
      .toLowerCase();
  if (!output.uri.toString().toLowerCase().startsWith(allowed)) {
    throw StateError(
      'Output must remain inside this SDK checkout build directory',
    );
  }
  var ancestor = output;
  while (!ancestor.existsSync()) {
    ancestor = ancestor.parent;
  }
  final canonicalAncestor = Directory(
    ancestor.resolveSymbolicLinksSync(),
  ).uri.toString().toLowerCase();
  final canonicalSdk = Directory(
    sdkRoot.resolveSymbolicLinksSync(),
  ).uri.toString().toLowerCase();
  if (!canonicalAncestor.startsWith(canonicalSdk)) {
    throw StateError('Output source ancestor escapes the SDK checkout');
  }
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError('Refusing to overwrite a previous evidence run');
  }
  await output.create(recursive: true);

  final originalConfig = File(
    '${sdkRoot.path}/packages/ugk_trainer/.dart_tool/package_config.json',
  );
  final decoded =
      jsonDecode(await originalConfig.readAsString()) as Map<String, dynamic>;
  final packages = <Map<String, Object?>>[];
  final sdkPackageRoots = {
    'ugk_coach': sdkRoot.uri,
    'ugk_trainer': Directory('${sdkRoot.path}/packages/ugk_trainer').uri,
    'ugk_trainer_runtime': Directory(
      '${sdkRoot.path}/packages/ugk_trainer_runtime',
    ).uri,
  };
  final foundSdk = <String>{};
  for (final raw in decoded['packages'] as List) {
    final package = Map<String, Object?>.from(raw as Map);
    final name = package['name'] as String;
    if (name == host) continue;
    final root = sdkPackageRoots[name];
    if (root != null) foundSdk.add(name);
    packages.add({
      ...package,
      'rootUri':
          root?.toString() ??
          originalConfig.uri.resolve(package['rootUri']! as String).toString(),
    });
  }
  if (!foundSdk.containsAll(sdkPackageRoots.keys)) {
    throw StateError(
      'Resolve the current SDK trainer packages before the gate',
    );
  }
  packages.add({
    'name': host,
    'rootUri': hostRoot.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.12',
  });
  final packageConfig = File('${output.path}/host_package_config.json');
  await packageConfig.writeAsString(
    jsonEncode({'configVersion': 2, 'packages': packages}),
  );
  final helper = File('${sdkRoot.path}/tool/coach_scope_guard_evaluation.dart');
  var bridgeSource = executedDurationHostBridge(
    host: host,
    sdkRoot: sdkRoot.path,
    hostRoot: hostRoot.path,
    output: output.path,
    helperUri: helper.uri.toString(),
  );
  const marker = '  Map<String, Object?> measure(coach.TrainingPlan plan) {';
  if (marker.allMatches(bridgeSource).length != 1) {
    throw StateError('The existing host bridge contract changed');
  }
  bridgeSource = bridgeSource.replaceFirst(marker, '$_scopeBinding\n$marker');
  final bridge = File('${output.path}/host_bridge.dart.txt');
  await bridge.writeAsString(bridgeSource);
  await File('${output.path}/launch.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'host': host,
      'sdkRoot': sdkRoot.path,
      'readOnlyHostRoot': hostRoot.path,
      'bridgeSha256': sha256.convert(utf8.encode(bridgeSource)).toString(),
      'helperSha256': sha256.convert(helper.readAsBytesSync()).toString(),
      'hostPackageConfigSha256': sha256
          .convert(packageConfig.readAsBytesSync())
          .toString(),
      'thinking': thinking,
      'dry': args.contains('--dry'),
      'appWritten': false,
      'deviceOperated': false,
    }),
  );
  final child = await Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${packageConfig.path}',
      bridge.path,
      '--thinking',
      thinking,
      if (args.contains('--dry')) '--dry',
    ],
    workingDirectory: sdkRoot.path,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await child.exitCode;
}

const _scopeBinding = r'''
  final masterPath = '$sdkRoot/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json';
  final masterBytes = File(masterPath).readAsBytesSync();
  recordSource(masterPath);
  final fixturePath = '$sdkRoot/test/fixtures/action-scope/${host == 'smartfit' ? 'smartfit-219' : 'hiplab-candidate-45'}.json';
  final fixture = readJson(fixturePath);
  final manifest = coach.CoachActionScopeManifest.fromCatalogBytes(
    appId: host,
    catalogBytes: masterBytes,
    planningCatalog: catalog,
    catalogSha256: fixture['catalogSha256'] as String,
    allowedActionIds: (fixture['allowedActionIds'] as List).cast<String>(),
  );
  final scope = manifest.restrict(catalog: catalog, profile: profile);
  if (manifest.allowedActionIds.length != (host == 'hiplab' ? 45 : 219)) {
    throw StateError('The declared evaluation authorization changed');
  }
  if (host == 'smartfit' && scope.plannableIds.length != 211) {
    throw StateError('SF 219 authorized / 211 plannable contract changed');
  }
  if (host == 'hiplab' && fixture['approvalStatus'] != 'candidate-not-user-approved') {
    throw StateError('Hip scope must remain explicitly candidate-only');
  }
  final policyData = gate.scopeEvaluationPolicyForHost(host);
  final specialty = policyData['specialty'] as String;
  final suggestions = (policyData['suggestions'] as List).cast<String>();
  final guidance = policyData['guidance'] as String;
  final preflight = <Map<String,Object?>>[];
  if (host == 'hiplab') {
    for (final scenario in gate.scopeEvaluationScenarios(host)) {
      final input = scenario.inputs.last;
      final sourceId = switch(scenario.path) {
        'partial-substitute' || 'insist' || 'safety-first' => 'h-side-leg-raise',
        'partial-remove' => 'h-band-row',
        _ => null,
      };
      final expected = switch(scenario.path) {
        'partial-substitute' => coach.CoachScopeDecisionKind.substituted,
        'partial-remove' => coach.CoachScopeDecisionKind.removed,
        'insist' => coach.CoachScopeDecisionKind.insistedUnavailable,
        'safety-first' => coach.CoachScopeDecisionKind.safetyBlocked,
        _ => coach.CoachScopeDecisionKind.outOfScope,
      };
      final policy = coach.CoachScopeConversationPolicy(specialty:specialty,
        suggestions:suggestions, outOfScopeGuidance:scenario.guidanceEnabled?guidance:null);
      final insideEvidence = [for(final drill in scope.catalog.drills)
        if(scope.matchesRequestedAction(drill.id,input))drill.id];
      final record = scope.evaluateRequest(coach.CoachScopeRequest(
        originalText:input, sourceActionId:sourceId,
        targetBodyCodes: sourceId == null ? {'body.chest','body.lats'} : const {},
        scene:'home', equipment: scenario.path == 'partial-remove' ? {'mat','band'} : {'mat'},
        avoid:scenario.safety?{'knee'}:const {},
        hasInScopeContent:insideEvidence.isNotEmpty, insists:scenario.path=='insist',
        safetyBlocked:scenario.safety,
      ),policy);
      final valid = record.kind == expected &&
        (expected != coach.CoachScopeDecisionKind.substituted ||
          (record.adoptedActionId != null && scope.contains(record.adoptedActionId!))) &&
        (expected != coach.CoachScopeDecisionKind.removed || insideEvidence.isNotEmpty);
      preflight.add({'case':scenario.id,'expectedKind':expected.name,
        'codeRecord':record.toJson(),'inScopeUserEvidence':insideEvidence,'passed':valid});
    }
    await File('$output/scope-preflight.json').writeAsString(jsonEncode(preflight));
    if(preflight.any((row)=>row['passed']!=true)) {
      throw StateError('Fixed scope case is not feasible under actual host facts; modelCalls=0');
    }
  }
  gate.installScopeEvaluationBinding(gate.ScopeEvaluationBinding(
    manifest: manifest.toJson(), authorizedIds: manifest.allowedActionIds,
    plannableIds: scope.plannableIds,
    masterIds: {(jsonDecode(utf8.decode(masterBytes)) as Map<String,dynamic>)['actions']}
      .expand((raw) => (raw as List).cast<Map<String,dynamic>>()).map((action) => action['id'] as String).toSet(),
    specialty: specialty, suggestions: suggestions, guidance: guidance,
    candidate: host == 'hiplab',
    preflight: preflight,
    createAgent: (client, onSpan, scenario) => coach.CoachAgent(
      client: client, catalog: () => catalog, profile: profile,
      scopeManifest: manifest,
      scopePolicy: coach.CoachScopeConversationPolicy(specialty: specialty,
        suggestions: suggestions,
        outOfScopeGuidance: scenario.guidanceEnabled ? guidance : null),
      executionTiming: builder.executionTiming, onSpan: onSpan,
      maxRequestRetries: 0, appId: host,
    ),
    scopeRecords: (agent) => [for(final record in agent.scopeRecords)record.toJson()],
  ));
''';
