// Generate offline defaults from the profile-owned configuration.
import 'dart:convert';
import 'dart:io';

void main() {
  final config =
      jsonDecode(File('profiles/plan-rules-default.json').readAsStringSync())
          as Map<String, dynamic>;
  final warmup = config['warmupFromMinutes'];
  final cooldown = config['cooldownFromMinutes'];
  final exempt = config['exemptWarmupForPureStretch'];
  final focus = config['focusRatio'];
  final maxSame = config['maxSameMuscleInRow'];
  final replaceDiff = config['replaceAllMinDiff'];
  final derivedStep = config['derivedStep'];
  final derivedMin = derivedStep is Map ? derivedStep['min'] : null;
  final derivedMax = derivedStep is Map ? derivedStep['max'] : null;
  final pairs = config['antagonisticPairs'];
  if (warmup is! int ||
      warmup < 0 ||
      cooldown is! int ||
      cooldown < 0 ||
      exempt is! bool ||
      focus is! num ||
      !focus.isFinite ||
      focus < 0 ||
      focus > 1 ||
      maxSame is! int ||
      maxSame < 1 ||
      replaceDiff is! num ||
      !replaceDiff.isFinite ||
      replaceDiff < 0 ||
      replaceDiff > 1 ||
      derivedMin is! num ||
      !derivedMin.isFinite ||
      derivedMin <= 0 ||
      derivedMax is! num ||
      !derivedMax.isFinite ||
      derivedMax < derivedMin ||
      derivedMax > 1 ||
      pairs is! List) {
    throw const FormatException('Invalid default plan rules');
  }
  String encodeStrings(Object? input) {
    if (input is! List ||
        input.isEmpty ||
        input.any((s) => s is! String || s.isEmpty)) {
      throw const FormatException('Invalid default antagonist pair');
    }
    return '[${input.map((s) => jsonEncode(s).replaceAll(r'$', r'\$')).join(', ')}]';
  }

  final expressions = <String>[];
  for (final item in pairs) {
    if (item is! Map) {
      throw const FormatException('Invalid default antagonist pair');
    }
    expressions.add(
      'AntagonistPair(first: ${encodeStrings(item['first'])}, second: ${encodeStrings(item['second'])})',
    );
  }
  File('lib/src/profile/plan_rules_defaults.g.dart').writeAsStringSync(
    '// Generated from profiles/plan-rules-default.json by tool/embed_plan_rules.dart.\n'
    '// Do not edit by hand.\n'
    '// ignore_for_file: lines_longer_than_80_chars, prefer_single_quotes\n\n'
    "import 'coach_profile.dart';\n\n"
    'const defaultWarmupFromMinutes = $warmup;\n'
    'const defaultCooldownFromMinutes = $cooldown;\n'
    'const defaultExemptWarmupForPureStretch = $exempt;\n'
    'const defaultFocusRatio = ${focus.toDouble()};\n'
    'const defaultMaxSameMuscleInRow = $maxSame;\n'
    'const defaultReplaceAllMinDiff = ${replaceDiff.toDouble()};\n'
    'const defaultDerivedStepMin = ${derivedMin.toDouble()};\n'
    'const defaultDerivedStepMax = ${derivedMax.toDouble()};\n'
    'const defaultAntagonisticPairs = <AntagonistPair>[${expressions.join(', ')}];\n',
  );
}
