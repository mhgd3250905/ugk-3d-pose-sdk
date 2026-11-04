import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

/// Lifecycle status filtering (action-library hot update, batch B):
/// the coach never suggests `not_recommended` / `retired`, while the
/// definitions stay in the catalogue for saved plans and history.
void main() {
  final root = 'test/fixtures/pose_hub/r1-v3';
  final catalogJson =
      jsonDecode(File('$root/catalog.json').readAsStringSync())
          as Map<String, Object?>;
  final semanticBytes = File('$root/catalog/catalog.json').readAsBytesSync();
  final profile = CoachProfile.fromJson(
    jsonDecode(File('profiles/smartfit.json').readAsStringSync()),
  );

  Catalog withStatus(Map<String, String> statuses) {
    final copy = jsonDecode(jsonEncode(catalogJson)) as Map<String, Object?>;
    for (final row in copy['actions']! as List<Object?>) {
      final action = row! as Map<String, Object?>;
      if (statuses[action['id']] case final status?) {
        action['status'] = status;
      }
    }
    return PoseHubAppTestCatalog.fromBytes(
      utf8.encode(jsonEncode(copy)),
      semanticCatalogBytes: semanticBytes,
    ).toAiCatalog();
  }

  final query = QaQuery(scene: 'gym', equipment: const {}, limit: 40);
  final base = withStatus(const {});
  final baseFinder = QaFinder(QaActionIndex(base), profile: profile);
  final found = [for (final h in baseFinder.find(query)) h.action.id];

  test('status reaches coach definitions; inactive stay resolvable', () {
    final ids = found.take(2).toList();
    final catalog = withStatus({
      ids[0]: 'not_recommended',
      ids[1]: 'retired',
    });
    expect(catalog[ids[0]]!.lifecycleStatus, 'not_recommended');
    expect(catalog[ids[1]]!.lifecycleStatus, 'retired');
    expect(catalog[ids[0]]!.suggestible, isFalse);
    expect(catalog[ids[1]]!.suggestible, isFalse);
    expect(catalog[found[2]]!.lifecycleStatus, 'active');
    // Saved plans validate against the App scope, which still holds them.
    final scope = {for (final d in profile.scope(catalog)) d.id};
    expect(scope, containsAll(ids));
  });

  test('search / recommend / plan picks skip not_recommended and retired', () {
    expect(found.length, greaterThan(3));
    final ids = found.take(2).toList();
    final finder = QaFinder(
      QaActionIndex(
        withStatus({ids[0]: 'not_recommended', ids[1]: 'retired'}),
      ),
      profile: profile,
    );
    final hits = [for (final h in finder.find(query)) h.action.id];
    expect(hits, isNot(contains(ids[0])));
    expect(hits, isNot(contains(ids[1])));
    expect(hits, contains(found[2]));
    // build_plan / show_actions / swap new_id are admitted through passes().
    expect(finder.passes(finder.index[ids[0]]!, query), isFalse);
    expect(finder.passes(finder.index[ids[1]]!, query), isFalse);
    expect(finder.inScope(query).map((a) => a.id), isNot(contains(ids[1])));
  });

  test('swap candidates skip not_recommended and retired', () {
    final from = baseFinder.index[found.first]!;
    final candidates = [
      for (final a in baseFinder.swapCandidates(from, query)) a.id,
    ];
    expect(candidates.length, greaterThan(1));
    final finder = QaFinder(
      QaActionIndex(
        withStatus({
          candidates[0]: 'not_recommended',
          candidates[1]: 'retired',
        }),
      ),
      profile: profile,
    );
    final next = [
      for (final a in finder.swapCandidates(finder.index[from.id]!, query))
        a.id,
    ];
    expect(next, isNot(contains(candidates[0])));
    expect(next, isNot(contains(candidates[1])));
  });
}
