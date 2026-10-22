import 'dart:convert';
import 'dart:io';

/// Compiles and runs actual AOT executables for all mode/flavor/opt-in pairs.
/// Run from any directory with `dart run path/to/this_file.dart`.
Future<void> main() async {
  final toolDirectory = File.fromUri(Platform.script).parent;
  final probe = File.fromUri(
    toolDirectory.uri.resolve('training_media_preview_policy_probe.dart'),
  );
  final temporary = await Directory.systemTemp.createTemp(
    'trainer-policy-aot-',
  );
  var count = 0;
  try {
    for (final mode in ['debug', 'profile', 'release']) {
      for (final flavor in ['', 'production', 'internal']) {
        for (final optIn in [false, true]) {
          final executable = temporary.uri.resolve(
            'probe${Platform.isWindows ? '.exe' : ''}',
          );
          final compiled = await Process.run(Platform.resolvedExecutable, [
            'compile',
            'exe',
            '-Ddart.vm.product=${mode == 'release'}',
            '-Ddart.vm.profile=${mode == 'profile'}',
            '-DFLUTTER_APP_FLAVOR=$flavor',
            '-DUGK_INTERNAL_MEDIA_PREVIEW=$optIn',
            '-o',
            executable.toFilePath(),
            probe.path,
          ]);
          if (compiled.exitCode != 0) {
            throw StateError('${compiled.stdout}\n${compiled.stderr}');
          }
          final executed = await Process.run(executable.toFilePath(), const []);
          if (executed.exitCode != 0) {
            throw StateError('${executed.stdout}\n${executed.stderr}');
          }
          final actual =
              jsonDecode(executed.stdout as String) as Map<String, dynamic>;
          final expected = mode == 'debug' || (flavor == 'internal' && optIn);
          if (actual['product'] != (mode == 'release') ||
              actual['profile'] != (mode == 'profile') ||
              actual['flavor'] != flavor ||
              actual['optIn'] != optIn ||
              actual['enabled'] != expected) {
            throw StateError(
              '$mode/$flavor/$optIn: expected $expected, got $actual',
            );
          }
          count++;
          stdout.writeln('$mode/$flavor/preview=$optIn -> $expected [PASS]');
        }
      }
    }
    stdout.writeln('AOT policy matrix: $count/$count passed.');
  } finally {
    await temporary.delete(recursive: true);
  }
}
