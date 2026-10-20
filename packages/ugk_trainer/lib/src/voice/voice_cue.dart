// Ported from HipLab@99fcc83 lib/hip/voice/session_script.dart (VoiceCue,
// CuePriority; SmartFit@e8981ee lib/voice/voice_cue.dart is the same
// extract). Unchanged semantics. Pure Dart.

/// Who wins when two lines want the air at once: counts are never
/// interrupted and interrupt everything else; calls (开始 / 换边 / 还剩 10 秒)
/// beat information (预告) which beats coaching tips.
enum CuePriority { coach, info, call, count }

/// One thing to say (and/or a chime to play) at [at] seconds into a phase.
/// Clip keys are [VoiceSource] keys; `chime.*` keys play on the chime
/// channel.
class VoiceCue {
  const VoiceCue(this.at, this.clips, this.priority, {this.subtitle});
  final double at;
  final List<String> clips;
  final CuePriority priority;

  /// Shown under the drill name while it plays (coach / tip lines).
  final String? subtitle;

  List<String> get voiceClips =>
      clips.where((c) => !c.startsWith('chime.')).toList();
  List<String> get chimes =>
      clips.where((c) => c.startsWith('chime.')).toList();

  @override
  String toString() => '${at.toStringAsFixed(2)} ${clips.join('+')}';
}
