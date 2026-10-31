// Launch the SDK gate against read-only host assets and host adapter source.
// Generated bridge files stay in the evidence folder, never in an App checkout.
import 'dart:convert';
import 'dart:io';

import 'executed_duration_host_timing.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln('''
dart run tool/eval_executed_duration.dart --host hiplab|smartfit [--dry] --out DIR
  [--host-root DIR] [--thinking on|off]

Seven independent, three-turn conversations per host. Final targets: five
5-minute runs, one 10-minute run and one 20-minute run. No supplemental answer,
failed-case rerun, timing exemption, dose truncation or plan resampling.
The callback and acceptance measurement share one actual SDK SessionBuilder.
SmartFit also asserts equality with its read-only App SessionBuilder adapter.
--dry loads configurations and checks a sample timeline; modelCalls=0.
Credentials use the existing authorized eval_api_config route and are excluded.
''');
    return;
  }
  try {
    await _launch(args);
  } on Object catch (error) {
    stderr.writeln(
      'Executed-duration evaluation stopped: ${error.runtimeType}.',
    );
    stderr.writeln('Check host paths, generated bridge and local diagnostics.');
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

  final host = option('--host') ?? 'hiplab';
  if (!{'hiplab', 'smartfit'}.contains(host)) {
    throw ArgumentError('Unknown host');
  }
  final sdkRoot = File.fromUri(Platform.script).parent.parent;
  final defaultHostRoot = host == 'hiplab'
      ? r'E:\AII-3D\3D-Hip-worktrees\coach-v2\3D-Hip'
      : r'E:\AII-3D\3D-Sport-AI\Sport-Helper-coach-ui-kit';
  final hostRoot = Directory(option('--host-root') ?? defaultHostRoot).absolute;
  if (!File('${hostRoot.path}/pubspec.yaml').existsSync()) {
    throw StateError('Host checkout is unavailable');
  }
  final output = Directory(
    option('--out') ??
        '${sdkRoot.path}/build/fit-executed-duration/live-$host-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}',
  ).absolute;
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError('Refusing to overwrite an existing evidence run');
  }
  await output.create(recursive: true);

  // Resolve existing SDK dependency locations to absolute URIs, then add only
  // the read-only App package used by the pure Dart host adapter bridge.
  final originalConfig = File(
    '${sdkRoot.path}/packages/ugk_trainer/.dart_tool/package_config.json',
  );
  final config =
      jsonDecode(await originalConfig.readAsString()) as Map<String, dynamic>;
  final packages = [
    for (final raw in config['packages'] as List)
      if (raw case final Map<String, dynamic> package)
        {
          ...Map<String, Object?>.from(package),
          'rootUri': originalConfig.uri
              .resolve(package['rootUri'] as String)
              .toString(),
        },
    {
      'name': host == 'hiplab' ? 'hiplab' : 'smartfit',
      'rootUri': hostRoot.uri.toString(),
      'packageUri': 'lib/',
      'languageVersion': '3.12',
    },
  ];
  final packageConfig = File('${output.path}/host_package_config.json');
  await packageConfig.writeAsString(
    const JsonEncoder.withIndent(
      '  ',
    ).convert({'configVersion': 2, 'packages': packages}),
  );
  final bridge = File('${output.path}/host_bridge.dart.txt');
  await bridge.writeAsString(
    executedDurationHostBridge(
      host: host,
      sdkRoot: sdkRoot.path,
      hostRoot: hostRoot.path,
      output: output.path,
      helperUri: File(
        '${sdkRoot.path}/tool/executed_duration_host_timing.dart',
      ).uri.toString(),
    ),
  );
  final childArgs = [
    '--packages=${packageConfig.path}',
    bridge.path,
    if (args.contains('--dry')) '--dry',
    '--thinking',
    option('--thinking') ?? 'on',
  ];
  final process = await Process.start(
    Platform.resolvedExecutable,
    childArgs,
    workingDirectory: sdkRoot.path,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
