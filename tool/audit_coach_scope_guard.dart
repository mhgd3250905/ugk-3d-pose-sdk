/// Offline recalculation of immutable real-run evidence; never starts an Agent.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'coach_scope_guard_evaluation.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/audit_coach_scope_guard.dart --input RAW_SDK_BUILD_DIR '
      '--out NEW_SDK_BUILD_DIR\n'
      'Reads captured public records and timing assertions only. Issues 0 HTTP '
      'requests, never reads a key, never constructs an Agent, never rewrites raw '
      'evidence. Functional and budget gates are separate for both hosts.',
    );
    return;
  }
  try {
    await _audit(args);
  } on Object catch (error) {
    stderr.writeln('Offline audit stopped: ${error.runtimeType}.');
    exitCode = 2;
  }
}

Future<void> _audit(List<String> args) async {
  final options = <String, String>{};
  for (var index = 0; index < args.length; index += 2) {
    if (!{'--input', '--out'}.contains(args[index]) ||
        options.containsKey(args[index]) ||
        index + 1 >= args.length ||
        args[index + 1].startsWith('--')) {
      throw ArgumentError('Expected explicit input and output once each');
    }
    options[args[index]] = args[index + 1];
  }
  if (options.length != 2) throw ArgumentError('Missing input or output');
  final sdk = File.fromUri(Platform.script).parent.parent;
  final input = _withinBuild(options['--input']!, sdk);
  final output = _withinBuild(options['--out']!, sdk);
  if (!input.existsSync()) throw StateError('Raw run is unavailable');
  final sourceUri = input.uri.toString().toLowerCase();
  final outputUri = output.uri.toString().toLowerCase();
  if (sourceUri.startsWith(outputUri) || outputUri.startsWith(sourceUri)) {
    throw StateError('Audit output must be separate from raw evidence');
  }
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError('Refusing to overwrite previous evidence');
  }
  final inputBefore = scopeEvaluationRawFileHashes(input);
  Map<String, Object?> read(String name) =>
      (jsonDecode(File('${input.path}/$name').readAsStringSync()) as Map)
          .cast<String, Object?>();
  final run = read('run.json');
  final originalSummary = read('summary.json');
  final host = run['host']! as String;
  if (host != 'smartfit' && host != 'hiplab') {
    throw StateError('Unrecognized captured host');
  }
  final manifest = (run['scopeManifest']! as Map).cast<String, Object?>();
  final master = File(
    '${sdk.path}/packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
  ).readAsBytesSync();
  if (sha256.convert(master).toString() != manifest['catalogSha256']) {
    throw StateError('Captured master catalog identity changed');
  }
  final actions = (jsonDecode(utf8.decode(master)) as Map)['actions']! as List;
  final fallbackPolicy = scopeEvaluationPolicyForHost(host);
  final policy = run['scopePolicy'] is Map
      ? (run['scopePolicy']! as Map).cast<String, Object?>()
      : fallbackPolicy;
  final binding = ScopeEvaluationBinding(
    manifest: manifest,
    authorizedIds: (run['authorizedIds']! as List).cast<String>().toSet(),
    plannableIds: (run['plannableIds']! as List).cast<String>().toSet(),
    masterIds: {for (final action in actions) (action as Map)['id']! as String},
    masterActionIdsByExactName: scopeEvaluationExactMasterNames(actions),
    specialty: policy['specialty']! as String,
    suggestions: (policy['suggestions']! as List).cast<String>(),
    guidance: policy['guidance']! as String,
    safetyMessage: policy['safetyMessage'] as String?,
    candidate: run['scopeStatus'] == 'candidate-test-fixture',
    createAgent: (_, _, _) =>
        throw StateError('Offline audit cannot create Agent'),
    scopeRecords: (_) =>
        throw StateError('Offline audit uses captured records'),
  );
  if (binding.authorizedIds.isEmpty ||
      binding.plannableIds.isEmpty ||
      !binding.authorizedIds.containsAll(binding.plannableIds)) {
    throw StateError('Invalid captured explicit scope');
  }
  final scenarios = scopeEvaluationScenarios(host);
  final declared = (run['cases']! as List).cast<Map<String, Object?>>();
  final runFailures = <String>[];
  if (declared.length != scenarios.length) {
    runFailures.add('fixed_case_count_changed');
  }
  for (final scenario in scenarios) {
    final original = declared.where((row) => row['id'] == scenario.id).toList();
    if (original.length != 1 ||
        original.single['path'] != scenario.path ||
        original.single['targetMinutes'] != scenario.targetMinutes ||
        original.single['guidanceEnabled'] != scenario.guidanceEnabled ||
        jsonEncode(original.single['inputs']) != jsonEncode(scenario.inputs)) {
      runFailures.add('fixed_case_definition_changed:${scenario.id}');
    }
  }
  if (originalSummary['sourceUnchangedAcrossRun'] != true) {
    runFailures.add('original_source_stability_not_verified');
  }
  await output.create(recursive: true);
  final results = <Map<String, Object?>>[];
  for (final scenario in scenarios) {
    final name = '${scenario.id}.json';
    final rawCaseSha = inputBefore[name];
    if (rawCaseSha == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(rawCaseSha)) {
      throw StateError('Captured case must have an exact nonnull SHA');
    }
    final raw = read(name);
    final audited = scopeEvaluationAuditCase(
      raw,
      binding: binding,
      scenario: scenario,
      host: host,
      retainOriginalVerdicts: true,
    );
    audited['rawCaseFile'] = name;
    audited['rawCaseSha256'] = rawCaseSha;
    await _write(File('${output.path}/$name'), audited);
    results.add(audited);
  }
  final inputAfter = scopeEvaluationRawFileHashes(input);
  final unchanged = jsonEncode(inputBefore) == jsonEncode(inputAfter);
  if (!unchanged) runFailures.add('raw_artifact_changed_during_audit');
  final functional =
      runFailures.isEmpty &&
      results.every((r) => r['functionalGatePassed'] == true);
  final budget = results.every((r) => r['budgetGatePassed'] == true);
  final summary = <String, Object?>{
    ...run,
    'schemaVersion': 2,
    'mode': 'offline-audit-of-immutable-real-run',
    'auditedAt': DateTime.now().toUtc().toIso8601String(),
    'inputDirectory': input.path,
    'httpRequestsIssuedByAudit': 0,
    'modelRequestsIssuedByAudit': 0,
    'agentConstructedByAudit': false,
    'appBuilderExecutedByAudit': false,
    'modelCallsRecorded': results.fold<int>(
      0,
      (sum, r) => sum + (r['modelCalls']! as int),
    ),
    'rawGatePassed': originalSummary['gatePassed'],
    'originalRealRunSourceSha256': run['sdkSourceSha256'],
    'currentSourceSha256': scopeEvaluationSourceFingerprint(sdk.path),
    'currentCodeValidatedByAudit': false,
    'auditPolicy':
        'Only top-level derived check caches are excluded from retained-version identity. Every other version key and plan/dose remains strict; latest delivered version must pass check and exactly match the delivered plan. Safety disclosure is verified against trusted Runner policy, never mutable record.message, and still requires no plan, denied admission, no adoption and complete safety/specialty/suggestions. Raw filenames use URI path segments and every case SHA must be nonnull. Numeric duration bounds, safety decisions, scope, protocol and call budgets are unchanged.',
    'scopePolicySource': run['scopePolicy'] is Map
        ? 'captured-run-metadata'
        : 'identical-frozen-r1-harness-constants',
    'timingSource':
        'captured original host SessionBuilder phase measurements and assertions; no new estimate or host execution',
    'rawFilesSha256': inputBefore,
    'rawArtifactsUnchanged': unchanged,
    'auditorFilesSha256': {
      for (final name in [
        'tool/audit_coach_scope_guard.dart',
        'tool/coach_scope_guard_evaluation.dart',
      ])
        name: sha256
            .convert(File('${sdk.path}/$name').readAsBytesSync())
            .toString(),
    },
    'functionalGatePassed': functional,
    'budgetGatePassed': budget,
    'gatePassed': functional && budget,
    'runFailures': runFailures,
    'cases': results,
  };
  await _write(File('${output.path}/summary.json'), summary);
  await File('${output.path}/summary.md').writeAsString(
    '# Offline audit of retained real-run evidence\n\n'
    'New HTTP/model requests: **0**. Raw artifacts unchanged: **$unchanged**. '
    'This audits the originally recorded code; it does not validate current '
    'SDK production changes. Original verdicts and file SHA remain attached.\n\n'
    'Functional: **$functional**; budget: **$budget**; overall: **${functional && budget}**.\n\n'
    '${scopeEvaluationMarkdown(summary)}',
  );
  stdout.writeln(
    '$host: offline audit; HTTP=0; functional=$functional; budget=$budget; rawUnchanged=$unchanged.',
  );
  if (!functional || !budget) {
    exitCode = 1;
  }
}

Directory _withinBuild(String path, Directory sdk) {
  final target = Directory.fromUri(
    Directory(path).absolute.uri.normalizePath(),
  );
  final allowed = sdk.absolute.uri.resolve('build/').toString().toLowerCase();
  if (!target.uri.toString().toLowerCase().startsWith(allowed)) {
    throw StateError(
      'Evidence must remain under the current SDK build directory',
    );
  }
  var ancestor = target;
  while (!ancestor.existsSync()) {
    ancestor = ancestor.parent;
  }
  final canonical = Directory(
    ancestor.resolveSymbolicLinksSync(),
  ).uri.toString().toLowerCase();
  final root = Directory(
    Directory('${sdk.path}/build').resolveSymbolicLinksSync(),
  ).uri.toString().toLowerCase();
  if (!canonical.startsWith(root)) {
    throw StateError('Evidence path escapes SDK');
  }
  return target;
}

/// Exact relative names for evidence hashes, independent of a trailing slash.
/// URI segments also preserve Unicode/space names without string offsets.
Map<String, String> scopeEvaluationRawFileHashes(Directory input) {
  final rootUri = input.absolute.uri.normalizePath();
  final rootSegments = rootUri.pathSegments.toList();
  while (rootSegments.isNotEmpty && rootSegments.last.isEmpty) {
    rootSegments.removeLast();
  }
  final files =
      input
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final hashes = <String, String>{};
  for (final file in files) {
    final uri = file.absolute.uri.normalizePath();
    final parts = uri.pathSegments;
    if (uri.scheme != rootUri.scheme ||
        uri.host != rootUri.host ||
        parts.length <= rootSegments.length ||
        !List.generate(
          rootSegments.length,
          (index) => parts[index] == rootSegments[index],
        ).every((same) => same)) {
      throw StateError('Evidence file escapes input URI');
    }
    final relative = parts.skip(rootSegments.length).join('/');
    if (relative.isEmpty || hashes.containsKey(relative)) {
      throw StateError('Empty or duplicate evidence path');
    }
    hashes[relative] = sha256.convert(file.readAsBytesSync()).toString();
  }
  return hashes;
}

Future<void> _write(File file, Object value) => file.writeAsString(
  '${const JsonEncoder.withIndent('  ').convert(value)}\n',
);
