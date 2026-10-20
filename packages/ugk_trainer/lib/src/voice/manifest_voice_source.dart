// Ported from HipLab@99fcc83 lib/hip/voice/voice_library.dart (VoiceLibrary:
// the read-only view of assets/voice/manifest.json written by HipLab's
// tools/voice/build_voice.py). Changes: implements [VoiceSource]; the asset
// root and the text loader are parameters (no rootBundle here, pure Dart);
// the voice language is a plain code; action-kit voice scripts can be
// attached ([kitVoices]).
import 'dart:convert';

import 'voice_source.dart';

class ManifestVoiceSource extends VoiceSource {
  ManifestVoiceSource(
    this._clips,
    this._chimes,
    this._texts,
    this._lines, {
    this.root = 'assets/voice',
    this.kitVoices = const {},
  });

  factory ManifestVoiceSource.fromJson(
    Map<String, dynamic> j, {
    String root = 'assets/voice',
    Map<String, KitVoice> kitVoices = const {},
  }) {
    Map<String, int> ints(Object? m) => {
      for (final e in Map<String, dynamic>.from(m as Map? ?? const {}).entries)
        e.key: (e.value as num).toInt(),
    };
    return ManifestVoiceSource(
      {
        for (final e in Map<String, dynamic>.from(
          j['clips'] as Map? ?? const {},
        ).entries)
          e.key: ints(e.value),
      },
      ints(j['chimes']),
      {
        for (final e in Map<String, dynamic>.from(
          j['texts'] as Map? ?? const {},
        ).entries)
          e.key: Map<String, String>.from(e.value as Map),
      },
      {
        for (final e in Map<String, dynamic>.from(
          j['lines'] as Map? ?? const {},
        ).entries)
          e.key: Map<String, String>.from(e.value as Map),
      },
      root: root,
      kitVoices: kitVoices,
    );
  }

  /// No clips: every lookup misses, durations fall back to estimates.
  static final empty = ManifestVoiceSource(
    const {},
    const {},
    const {},
    const {},
  );

  static const manifestAsset = 'assets/voice/manifest.json';

  /// Loads [asset] with [read] (rootBundle.loadString in an app); [empty]
  /// when it is missing or broken.
  static Future<ManifestVoiceSource> load(
    Future<String> Function(String path) read, {
    String asset = manifestAsset,
    String root = 'assets/voice',
    Map<String, KitVoice> kitVoices = const {},
  }) async {
    try {
      return ManifestVoiceSource.fromJson(
        jsonDecode(await read(asset)) as Map<String, dynamic>,
        root: root,
        kitVoices: kitVoices,
      );
    } on Object {
      return empty;
    }
  }

  final String root;
  final Map<String, KitVoice> kitVoices;
  final Map<String, Map<String, int>> _clips;
  final Map<String, int> _chimes;
  final Map<String, Map<String, String>> _texts;
  final Map<String, Map<String, String>> _lines;

  @override
  Set<String> get languages => {
    for (final e in _clips.entries)
      if (e.value.isNotEmpty) e.key,
  };

  @override
  bool has(String key, {required String lang}) => key.startsWith('chime.')
      ? _chimes.containsKey(key.substring(6))
      : _clips[lang]?.containsKey(key) ?? false;

  @override
  double seconds(String key, {required String lang}) {
    if (key.startsWith('chime.')) return 0;
    final ms = _clips[lang]?[key];
    return ms != null ? ms / 1000 : estimateSeconds(key);
  }

  /// Clip key for a content string, e.g. a dose ("每侧 30 秒") or a tip.
  String? textKey(String kind, String text) => _texts[kind]?[text];

  @override
  String? line(String key, {required String lang}) => _lines[key]?[lang];

  @override
  String asset(String key, {required String lang}) => key.startsWith('chime.')
      ? '$root/chime/${key.substring(6)}.m4a'
      : '$root/$lang/$key.m4a';

  @override
  KitVoice? kitVoice(String exerciseId) => kitVoices[exerciseId];

  @override
  String? call(VoiceCall c) => switch (c) {
    VoiceCall.welcome => 'p.welcome',
    VoiceCall.total => 'p.total',
    VoiceCall.first => 'p.first',
    VoiceCall.next => 'p.next',
    VoiceCall.last => 'p.last',
    VoiceCall.rest => 'p.rest',
    VoiceCall.go => 'p.go',
    VoiceCall.goRight => 'p.go_right',
    VoiceCall.rightFirst => 'p.right_first',
    VoiceCall.switchLeft => 'p.switch_left',
    VoiceCall.switchRight => 'p.switch_right',
    VoiceCall.finish => 'p.finish',
    VoiceCall.nice => 'p.nice',
    VoiceCall.ready => 'p.ready',
    VoiceCall.half => 'p.half',
    VoiceCall.tenLeft => 'p.last10',
    VoiceCall.perSide => 'p.each_side',
    VoiceCall.lastRep => 'p.last_rep',
    VoiceCall.again => 'p.again',
    VoiceCall.paused => 'p.paused',
    VoiceCall.resume => 'p.resume',
    VoiceCall.roundDone || VoiceCall.lastSet || VoiceCall.slow => null,
  };

  @override
  String? drill(String exerciseId, DrillLine line) => switch (line) {
    DrillLine.name => 'drill.$exerciseId',
    DrillLine.cue1 => 'point.$exerciseId',
    _ => null,
  };

  @override
  List<String> secondsPhrase(int n) => ['sec.$n'];

  @override
  List<String> minutesPhrase(int n) => ['min.$n'];
}
