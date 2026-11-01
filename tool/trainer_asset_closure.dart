/// Offline generation of one exact allowlist's runtime asset closure.
library;

import 'dart:convert';
import 'dart:io';

import 'src/trainer_assets/closure.dart';

export 'src/trainer_assets/closure.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help')) {
    stdout.writeln('''
dart run tool/trainer_asset_closure.dart --manifest FILE --out NEW_DIRECTORY
  [--asset-prefix assets/trainer]

Offline only. Exact IDs; no wildcard, prefix, empty-list fallback or download.
Missing files, unpinned asset receipts and invalid hashes are configuration errors.
The output directory must be absent or empty; existing contents are never replaced.
''');
    return;
  }
  try {
    String? option(String name) {
      final index = arguments.indexOf(name);
      if (index < 0) return null;
      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('--')) {
        throw TrainerAssetConfigurationException('missing_option_value', name);
      }
      return arguments[index + 1];
    }

    const flags = {'--manifest', '--out', '--asset-prefix'};
    final seenFlags = <String>{};
    for (var index = 0; index < arguments.length; index += 2) {
      if (!flags.contains(arguments[index])) {
        throw const TrainerAssetConfigurationException(
          'unknown_option',
          'arguments',
        );
      }
      if (!seenFlags.add(arguments[index])) {
        throw TrainerAssetConfigurationException(
          'duplicate_option',
          arguments[index],
        );
      }
    }
    final manifest = option('--manifest');
    final output = option('--out');
    if (manifest == null || output == null) {
      throw const TrainerAssetConfigurationException(
        'missing_required_option',
        '--manifest/--out',
      );
    }
    final result = await generateTrainerAssetClosure(
      manifestFile: File(manifest),
      outputDirectory: Directory(output),
      assetPrefix: option('--asset-prefix') ?? 'assets/trainer',
    );
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'actions': result.allowedActionIds.length,
        'files': result.files.length,
        'bytes': result.totalBytes,
        'proof': '${result.outputDirectory.path}/asset-closure.json',
      }),
    );
  } on TrainerAssetConfigurationException catch (error) {
    stderr.writeln(
      jsonEncode({'ok': false, 'code': error.code, 'field': error.field}),
    );
    exitCode = 2;
  } on Object catch (error) {
    // Source/host paths and private configuration are not copied to diagnostics.
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'code': 'asset_generation_failed',
        'errorType': error.runtimeType.toString(),
      }),
    );
    exitCode = 2;
  }
}
