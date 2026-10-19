import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();

  group('Catalog（pose-hub-catalog@1）', () {
    test('解析快照：142 个动作、分类字典、无问题', () {
      expect(catalog.version, '0.1.0');
      expect(catalog.length, 142);
      expect(catalog.problems, isEmpty);
      expect(catalog.taxonomy.floorPositions, containsAll(['supine', 'prone', 'kneeling']));
      expect(catalog.taxonomy.floorPositions, isNot(contains('seated')));
      expect(catalog.taxonomy.equipmentLabel('dumbbell'), '哑铃');
      final d = catalog['glute-max-A']!;
      expect(d.unilateral, isTrue);
      expect(d.doseRange.reps, isNotNull);
      expect(d.apps, containsAll(['flarelab', 'hiplab', 'smartfit']));
      expect(d.assets.spec.ok, isTrue);
    });
    test('format / formatVersion 不对就拒绝', () {
      expect(() => Catalog.fromJson({'format': 'x'}), throwsA(isA<CatalogFormatException>()));
      expect(() => Catalog.fromJson({'format': catalogFormat, 'formatVersion': 2, 'version': '1.0.0', 'drills': <Object>[]}),
          throwsA(isA<CatalogFormatException>()));
    });
    test('缺必填字段的动作跳过并记录；重复 id 保留第一条', () {
      final c = Catalog.fromJson({
        'format': catalogFormat,
        'formatVersion': 1,
        'version': '1.0.0',
        'drills': [
          {'id': 'a'},
          (jsonDecode(jsonEncode(catalog['h-squat']!.raw)) as Map),
          (jsonDecode(jsonEncode(catalog['h-squat']!.raw)) as Map),
        ],
      });
      expect(c.ids, ['h-squat']);
      expect(c.problems, hasLength(2));
    });
    test('toJson → fromJson 往返', () {
      final back = Catalog.fromJson(jsonDecode(jsonEncode(catalog.toJson())));
      expect(back.length, catalog.length);
      expect(back['s-figure4']!.assets.voiceAudio.length, catalog['s-figure4']!.assets.voiceAudio.length);
    });
    test('profile 范围', () {
      expect(loadProfile('hiplab').scope(catalog), hasLength(46));
      expect(loadProfile('flarelab').scope(catalog), hasLength(51));
      expect(loadProfile('smartfit').scope(catalog), hasLength(142), reason: 'SmartFit 用全库');
    });
  });

  group('DrillSelector', () {
    final squat = catalog['h-squat']!;
    test('全空 = 全库', () => expect(const DrillSelector().matches(squat), isTrue));
    test('并集与排除', () {
      expect(const DrillSelector(idPrefixes: ['h-']).matches(squat), isTrue);
      expect(const DrillSelector(categories: {'stretch'}).matches(squat), isFalse);
      expect(const DrillSelector(apps: {'smartfit'}, exclude: {'h-squat'}).matches(squat), isFalse);
      expect(const DrillSelector(tags: {'hip'}, excludeTags: {'hip'}).matches(squat), isFalse);
    });
  });

  group('AssetResolver：一个 id 带出整套素材', () {
    test('SmartFit：drill-pack 路径、每句台词带时长', () {
      final r = const AssetResolver(appOrder: ['smartfit']).resolveId(catalog, 'h-squat')!;
      expect(r.cover!.uri, 'assets/packs/h-squat/cover.jpg');
      expect(r.video!.uri, 'assets/packs/h-squat/demo.mp4');
      expect(r.video!.source.repSeconds, isNotNull);
      expect(r.voice['cue1']!.uri, 'assets/packs/h-squat/voice/zh/cue1.m4a');
      expect(r.voice['cue1']!.ms, greaterThan(0));
      expect(r.spec, startsWith('drill-anim/specs/'));
      expect(r.complete, isTrue);
    });
    test('HipLab：明暗版本与 key 风格语音', () {
      final dark = const AssetResolver(appOrder: ['hiplab'], variant: 'dark').resolveId(catalog, 'glute-max-A')!;
      final light = const AssetResolver(appOrder: ['hiplab'], variant: 'light').resolveId(catalog, 'glute-max-A')!;
      expect(dark.video!.uri, isNot(light.video!.uri));
      expect(light.video!.uri, contains('/light/'));
      expect(dark.voiceKeys.map((k) => k.uri), contains('assets/voice/zh/drill.glute-max-A.m4a'));
    });
    test('Pose-Hub 发布素材：拼远端前缀、取最新发布版', () {
      final r = const AssetResolver(appOrder: ['pose-hub'], baseByApp: {'pose-hub': 'https://cdn.example.com/pose-hub'})
          .resolveId(catalog, 'glute-max-A')!;
      expect(r.video!.uri, startsWith('https://cdn.example.com/pose-hub/glute-max-A/'));
      expect(r.video!.source.release, '0.2.0');
    });
    test('按偏好顺序回退', () {
      final r = const AssetResolver(appOrder: ['smartfit', 'flarelab']).resolveId(catalog, 'abs-A')!;
      expect(r.video!.source.app, 'flarelab');
      expect(r.missing, contains(AssetKind.voice));
    });
    test('缺素材清单', () {
      final report = const AssetResolver(appOrder: ['flarelab']).missingReport(loadProfile('flarelab').scope(catalog));
      expect(report.values.every((m) => m.isNotEmpty), isTrue);
      expect(report['abs-A'], contains(AssetKind.voice));
    });
    test('不存在的 id', () => expect(const AssetResolver(appOrder: ['smartfit']).resolveId(catalog, 'nope'), isNull));
  });

  group('DrillPackAdapter（统一目录落地前直接读 SmartFit 小包）', () {
    final packs = {
      for (final id in ['h-squat', 's-figure4']) id: jsonDecode(File('test/fixtures/packs/$id/pack.json').readAsStringSync()),
    };
    final c = const DrillPackAdapter().build(version: '1.0.0', packs: packs.cast());
    test('字段与素材', () {
      expect(c.ids, unorderedEquals(['h-squat', 's-figure4']));
      final r = const AssetResolver(appOrder: ['smartfit']).resolveId(c, 's-figure4')!;
      expect(r.video!.uri, 'assets/packs/s-figure4/demo.mp4');
      expect(r.voice.keys, contains('side_switch'));
      expect(c['s-figure4']!.assets.drillPack!.path, 'assets/packs/s-figure4/pack.json');
    });
    test('没有 doseRange 时提示词按 build_catalog 规则推导', () {
      expect(PromptBuilder.catalogRow(c['h-squat']!), contains('组1-4 次6-18'));
    });
  });
}
