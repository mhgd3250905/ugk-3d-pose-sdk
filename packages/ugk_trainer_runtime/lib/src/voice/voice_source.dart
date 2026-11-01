// ugk_trainer's own: the voice-clip library seen through one interface, so
// the session script works with HipLab's single manifest
// ([ManifestVoiceSource]) and SmartFit's drill packs
// ([DrillPackVoiceSource]) alike. The lookup half (has / seconds / total /
// line / asset) is the API of HipLab@99fcc83 lib/hip/voice/voice_library.dart.
// Pure Dart.

/// Calls the script says, by meaning. Each source maps them to its keys.
enum VoiceCall {
  welcome,
  total,
  first,
  next,
  last,
  rest,
  go,
  goRight,
  rightFirst,
  switchLeft,
  switchRight,
  finish,
  nice,
  ready,
  half,
  tenLeft,
  perSide,
  roundDone,
  lastSet,
  lastRep,
  again,
  slow,
  paused,
  resume,
}

/// A move's own lines.
enum DrillLine { name, intro, cue1, cue2, cue3, sideSwitch, rest, finish }

/// HipLab action-kit voice script (ported from HipLab@99fcc83
/// lib/hip/domain/action_kit.dart KitVoice): which clips mark which moment
/// of one action.
class KitVoice {
  const KitVoice({
    required this.prepare,
    required this.go,
    required this.count,
    required this.lastRep,
    required this.nextSet,
    required this.end,
    required this.coach,
    this.firstSide,
    this.half,
    this.last10,
    this.countdown = 5,
  });
  final List<String> prepare;
  final String go;

  /// Clip pattern of a count, e.g. `n.{k}`.
  final String count;
  final String lastRep;
  final String nextSet;

  /// Said when the action ends (p.nice / p.release).
  final String end;
  final List<String> coach;
  final String? firstSide;
  final String? half;
  final String? last10;
  final int countdown;

  String countClip(int k) => count.replaceAll('{k}', '$k');

  factory KitVoice.fromJson(Map<String, dynamic> j) {
    final mid = j['midHold'] as Map?;
    return KitVoice(
      prepare: [for (final x in j['prepare'] as List? ?? const []) x as String],
      go: j['go'] as String,
      count: j['count'] as String,
      lastRep: j['lastRep'] as String,
      nextSet: j['nextSet'] as String,
      end: j['end'] as String,
      coach: [for (final x in (j['coach'] as List?) ?? const []) x as String],
      firstSide: j['firstSide'] as String?,
      half: mid?['half'] as String?,
      last10: mid?['last10'] as String?,
      countdown: (mid?['countdown'] as int?) ?? 5,
    );
  }

  /// From a whole action-kit file (`action-kit@1`).
  static KitVoice fromActionKitJson(Map<String, dynamic> kit) =>
      KitVoice.fromJson(Map<String, dynamic>.from(kit['voice'] as Map));
}

/// Where voice clips come from. Keys are opaque to the script except the
/// `chime.*` prefix (the chime channel); the source maps meanings
/// ([VoiceCall], [DrillLine], numbers) to its own keys.
abstract class VoiceSource {
  const VoiceSource();

  /// The clip exists. `chime.*` keys ignore [lang].
  bool has(String key, {required String lang});

  /// Clip length in seconds; an estimate when unknown (counts .4 s, other
  /// lines 1.2 s), 0 for chimes.
  double seconds(String key, {required String lang});

  /// Asset path to play.
  String asset(String key, {required String lang});

  /// The written line (subtitle).
  String? line(String key, {required String lang});

  /// Languages with any recorded voice. A language outside this set gets
  /// chimes and the on-screen countdown only (decision B).
  Set<String> get languages;

  bool supports(String lang) => languages.contains(lang);

  /// Played back to back: lengths plus a small gap between clips.
  double total(Iterable<String> keys, {required String lang}) =>
      keys.fold(0.0, (s, k) => s + seconds(k, lang: lang)) +
      .06 *
          (keys.where((k) => !k.startsWith('chime.')).length - 1).clamp(0, 99);

  /// Key of a call, null when this source has none.
  String? call(VoiceCall c);

  /// Key of a move's own line, null when it has none.
  String? drill(String exerciseId, DrillLine line);

  /// Voice script of an action (HipLab kits), null when none.
  KitVoice? kitVoice(String exerciseId) => null;

  /// Clips of a number (a count, a total), empty when not recorded as one.
  List<String> number(int n) => ['n.$n'];

  /// "30 秒"; empty when it cannot be said whole.
  List<String> secondsPhrase(int n);

  /// "12 分钟".
  List<String> minutesPhrase(int n);

  /// "3 组".
  List<String> setsPhrase(int n) => const [];

  /// "12 次".
  List<String> repsPhrase(int n) => const [];

  /// "第 2 组".
  List<String> ordinalSet(int n) => const [];

  /// "第 2 轮".
  List<String> ordinalRound(int n) => const [];
}

/// Shared length rule of both sources.
double estimateSeconds(String key) {
  if (key.startsWith('chime.')) return 0;
  if (key.startsWith('n.')) return .4;
  return 1.2;
}
