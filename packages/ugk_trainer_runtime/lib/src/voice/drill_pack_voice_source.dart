// Ported from SmartFit@e8981ee lib/voice/voice_library.dart (VoiceLibrary.
// fromPacks) and the voice part of lib/packs/drill_pack.dart (drill-pack
// format 1, docs/drill-pack-spec.md). Changes: implements [VoiceSource];
// reads pack.json maps directly (no SmartFit PackSet), pure Dart.
//
// Clip keys:
//   `n.3`, `p.go`, `u.sets` …   a line of the shared `_common` pack
//   `h-squat/cue1` …            line `cue1` of the `h-squat` pack
//   `chime.tick` …              a chime of the `_common` pack (own channel)
import 'dart:convert';

import 'voice_source.dart';

class _Clip {
  const _Clip(this.asset, this.text, this.ms);
  final Map<String, String> asset;
  final Map<String, String> text;
  final Map<String, int> ms;
}

class DrillPackVoiceSource extends VoiceSource {
  DrillPackVoiceSource._(this._clips, this._chimes, this.root, this._langs);

  static const commonPackId = '_common';
  static const defaultRoot = 'assets/packs';

  /// [common]: the `_common` pack.json; [packs]: exercise id → pack.json.
  /// Pack folders are `<root>/<id>`.
  factory DrillPackVoiceSource.fromPacks({
    required Map<String, dynamic> common,
    Map<String, Map<String, dynamic>> packs = const {},
    String root = defaultRoot,
  }) {
    final clips = <String, _Clip>{};
    final langs = <String>{};
    void add(Map<String, dynamic> p, String Function(String id) key) {
      final id = p['id'] as String;
      final folder = '$root/$id';
      final voice = Map<String, dynamic>.from(p['voice'] as Map? ?? const {});
      for (final raw in voice['lines'] as List? ?? const []) {
        final l = Map<String, dynamic>.from(raw as Map);
        final lineId = l['id'] as String;
        final ms = {
          for (final e in Map<String, dynamic>.from(
            l['ms'] as Map? ?? const {},
          ).entries)
            e.key: (e.value as num).toInt(),
        };
        langs.addAll(ms.keys);
        clips[key(lineId)] = _Clip(
          {for (final lang in ms.keys) lang: '$folder/voice/$lang/$lineId.m4a'},
          Map<String, String>.from(l['text'] as Map? ?? const {}),
          ms,
        );
      }
    }

    add(common, (id) => id);
    for (final e in packs.entries) {
      add(e.value, (id) => lineKey(e.key, id));
    }
    final commonId = common['id'] as String? ?? commonPackId;
    return DrillPackVoiceSource._(
      clips,
      {
        for (final e in Map<String, dynamic>.from(
          common['chimes'] as Map? ?? const {},
        ).entries)
          e.key: '$root/$commonId/${(e.value as Map)['file']}',
      },
      root,
      langs,
    );
  }

  /// Reads `<root>/index.json` (drill-pack-index format 1) and every pack
  /// it lists with [read] (rootBundle.loadString in an app).
  static Future<DrillPackVoiceSource> load(
    Future<String> Function(String path) read, {
    String root = defaultRoot,
  }) async {
    final index = jsonDecode(await read('$root/index.json')) as Map;
    final commonId = index['common'] as String? ?? commonPackId;
    Future<Map<String, dynamic>> pack(String id) async =>
        Map<String, dynamic>.from(
          jsonDecode(await read('$root/$id/pack.json')) as Map,
        );
    final common = await pack(commonId);
    final packs = <String, Map<String, dynamic>>{};
    for (final e in index['packs'] as List? ?? const []) {
      final id = (e as Map)['id'] as String;
      if (id == commonId) continue;
      packs[id] = await pack(id);
    }
    return DrillPackVoiceSource.fromPacks(
      common: common,
      packs: packs,
      root: root,
    );
  }

  static final empty = DrillPackVoiceSource._(const {}, const {}, '', const {});

  /// Key of a pack's own line (`h-squat/cue1`).
  static String lineKey(String packId, String lineId) => '$packId/$lineId';

  final Map<String, _Clip> _clips;
  final Map<String, String> _chimes;
  final String root;
  final Set<String> _langs;

  @override
  Set<String> get languages => _langs;

  @override
  bool has(String key, {required String lang}) => key.startsWith('chime.')
      ? _chimes.containsKey(key.substring(6))
      : _clips[key]?.ms.containsKey(lang) ?? false;

  @override
  double seconds(String key, {required String lang}) {
    if (key.startsWith('chime.')) return 0;
    final ms = _clips[key]?.ms[lang];
    return ms != null ? ms / 1000 : estimateSeconds(key);
  }

  @override
  String? line(String key, {required String lang}) => _clips[key]?.text[lang];

  @override
  String asset(String key, {required String lang}) {
    if (key.startsWith('chime.')) {
      return _chimes[key.substring(6)] ??
          '$root/$commonPackId/chime/${key.substring(6)}.m4a';
    }
    final a = _clips[key]?.asset[lang];
    if (a != null) return a;
    final slash = key.indexOf('/');
    return slash < 0
        ? '$root/$commonPackId/voice/$lang/$key.m4a'
        : '$root/${key.substring(0, slash)}/voice/$lang/'
              '${key.substring(slash + 1)}.m4a';
  }

  @override
  String? call(VoiceCall c) => switch (c) {
    VoiceCall.welcome => 'p.welcome',
    VoiceCall.total => 'p.total',
    VoiceCall.first => 'p.first',
    VoiceCall.next => 'p.next',
    VoiceCall.rest => 'p.rest',
    VoiceCall.go => 'p.go',
    VoiceCall.goRight => 'p.go_right',
    VoiceCall.switchLeft => 'p.switch_left',
    VoiceCall.switchRight => 'p.switch_right',
    VoiceCall.finish => 'p.finish',
    VoiceCall.nice => 'p.nice',
    VoiceCall.half => 'p.half',
    VoiceCall.tenLeft => 'p.ten_left',
    VoiceCall.perSide => 'p.per_side',
    VoiceCall.roundDone => 'p.round_done',
    VoiceCall.lastSet => 'p.last_set',
    VoiceCall.slow => 'p.slow',
    VoiceCall.paused => 'p.paused',
    VoiceCall.resume => 'p.resume',
    VoiceCall.last => 'p.last',
    VoiceCall.ready => 'p.ready',
    VoiceCall.rightFirst => 'p.right_first',
    VoiceCall.lastRep => 'p.last_rep',
    VoiceCall.again => 'p.again',
  };

  @override
  String? drill(String exerciseId, DrillLine line) =>
      lineKey(exerciseId, switch (line) {
        DrillLine.name => 'name',
        DrillLine.intro => 'intro',
        DrillLine.cue1 => 'cue1',
        DrillLine.cue2 => 'cue2',
        DrillLine.cue3 => 'cue3',
        DrillLine.sideSwitch => 'side_switch',
        DrillLine.rest => 'rest',
        DrillLine.finish => 'finish',
      });

  @override
  List<String> number(int n) => n >= 1 && n <= 60 ? ['n.$n'] : const [];

  @override
  List<String> secondsPhrase(int n) => _unit(n, 'u.sec');

  List<String> _unit(int n, String unit) {
    final k = number(n);
    return k.isEmpty ? const [] : [...k, unit];
  }

  @override
  List<String> minutesPhrase(int n) => _unit(n, 'u.min');

  @override
  List<String> setsPhrase(int n) => _unit(n, 'u.sets');

  @override
  List<String> repsPhrase(int n) => _unit(n, 'u.reps');

  @override
  List<String> ordinalSet(int n) =>
      number(n).isEmpty ? const [] : ['p.di', ...number(n), 'u.sets'];

  @override
  List<String> ordinalRound(int n) =>
      number(n).isEmpty ? const [] : ['p.di', ...number(n), 'u.rounds'];
}
