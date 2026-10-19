/// 把 SmartFit drill-pack format 1（`index.json` + 各 `pack.json`）转成 [Catalog]。
/// 统一目录落地前、或 App 只带了小包时用。
library;

import '../util/json.dart';
import 'catalog.dart';

class DrillPackAdapter {
  /// [root]：包目录在 App 资源里的路径，如 `assets/packs`。
  const DrillPackAdapter({this.root = 'assets/packs', this.app = 'smartfit'});
  final String root;
  final String app;

  /// [packs]：id → pack.json 内容（只取 kind=exercise）。
  Catalog build({required String version, required Map<String, Object?> packs, String? generatedAt}) {
    final drills = <Object?>[];
    for (final e in packs.entries) {
      final p = asMap(e.value);
      if (p['format'] != 'drill-pack' || p['kind'] != 'exercise') continue;
      if (asInt(p['formatVersion']) != 1) continue;
      drills.add(toDrillJson(p));
    }
    return Catalog.fromJson({
      'format': catalogFormat,
      'formatVersion': 1,
      'version': version,
      'generatedAt': ?generatedAt,
      'source': {'repo': 'drill-packs', 'commit': 'local'},
      'drills': drills,
    });
  }

  Map<String, Object?> toDrillJson(Map<String, Object?> p) {
    final id = p['id'] as String;
    final dir = '$root/$id';
    final media = asMap(p['media']);
    final voice = asMap(p['voice']);
    final langs = asStringList(voice['languages']);
    final credits = asMap(p['credits']);
    return {
      for (final k in const [
        'id', 'name', 'category', 'muscles', 'muscleGroups', 'equipment', 'position', 'unilateral', 'level',
        'scenes', 'defaultDose', 'cues', 'primaryCue', 'cautions', 'contraindications', 'alternative',
      ])
        k: p[k],
      'apps': [app],
      'tags': const <String>[],
      'assets': {
        'spec': {'status': credits['spec'] == null ? 'missing' : 'ok', 'path': ?credits['spec']},
        'cover': {
          'sources': [
            if (media['cover'] != null)
              {'app': app, 'path': '$dir/${media['cover']}', 'coverSeconds': ?media['coverSeconds']},
          ],
        },
        'video': {
          'sources': [
            if (media['video'] != null)
              {
                'app': app,
                'path': '$dir/${media['video']}',
                'width': ?media['width'],
                'height': ?media['height'],
                'loopSeconds': ?media['loopSeconds'],
                'repSeconds': ?media['repSeconds'],
                'showsSide': ?media['showsSide'],
              },
          ],
        },
        'voice': {
          'languages': langs,
          'lines': voice['lines'],
          'audio': [
            {'app': app, 'pathPattern': '$dir/voice/{lang}/{line}.m4a', 'languages': langs},
          ],
        },
        'drillPack': {'app': app, 'path': '$dir/pack.json', 'version': p['version']},
      },
    };
  }
}
