// Generate the synchronous, offline default from the profile-owned JSON data.
import 'dart:convert';
import 'dart:io';

void main() {
  final source = File('profiles/legacy-goal-default.json');
  final decoded = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
  final rules = decoded['legacyGoalMap'];
  if (rules is! List ||
      rules.isEmpty ||
      rules.any(
        (rule) =>
            rule is! Map || rule['anyOf'] is! List || rule['goal'] is! String,
      ) ||
      (rules.last as Map)['fallback'] != true) {
    throw const FormatException(
      'Invalid legacyGoalMap or missing final fallback',
    );
  }
  final encoded = jsonEncode(jsonEncode(rules)).replaceAll(r'$', r'\$');
  File('lib/src/agent/legacy_goal_defaults.g.dart').writeAsStringSync(
    '// Generated from profiles/legacy-goal-default.json by tool/embed_legacy_goal.dart.\n'
    '// Do not edit by hand.\n'
    '// ignore_for_file: lines_longer_than_80_chars, prefer_single_quotes\n\n'
    'const legacyGoalDefaultsJson = $encoded;\n',
  );
}
