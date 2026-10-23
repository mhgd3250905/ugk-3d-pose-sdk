// Read-only catalog pacing audit. No media or language assets are fetched.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/audit_catalog_guidance.dart catalog.json',
    );
    exitCode = 64;
    return;
  }
  final bytes = File(args.single).readAsBytesSync();
  final catalog = Catalog.fromJson(
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
  );
  final rhythms = rhythmsFromCatalog(catalog);
  final rows = <Map<String, Object?>>[];
  for (final drill in catalog.drills) {
    final dose = drill.defaultDose;
    final item = PlanItem(
      exerciseId: drill.id,
      mode: dose.mode,
      sets: dose.sets,
      reps: dose.reps,
      workSeconds: dose.seconds,
      perSide: drill.unilateral,
      restSeconds: dose.restSeconds,
    );
    final rhythm = rhythms[drill.id]!.effectiveFor(item);
    rows.add({
      'id': drill.id,
      'name': drill.name.toJson(),
      'category': drill.category,
      'mode': dose.mode.name,
      'source': rhythm.source.name,
      'automatic': !rhythm.selfPaced,
      'repSeconds': rhythm.counted ? rhythm.cycleFor() : null,
    });
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'catalogVersion': catalog.version,
      'catalogSha256': sha256.convert(bytes).toString(),
      'parserProblems': catalog.problems.map((p) => p.toString()).toList(),
      'total': rows.length,
      'automatic': rows.where((r) => r['automatic'] == true).length,
      'fallbackReps': rows
          .where(
            (r) =>
                r['source'] == 'dose' &&
                r['mode'] == 'reps' &&
                r['automatic'] == true,
          )
          .length,
      'explicitSelfPaced': rows
          .where((r) => r['automatic'] == false)
          .map((r) => r['id'])
          .toList(),
      'drills': rows,
    }),
  );
}
