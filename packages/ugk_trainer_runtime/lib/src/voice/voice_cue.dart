// Ported from HipLab@99fcc83 lib/hip/voice/session_script.dart (VoiceCue,
// CuePriority; SmartFit@e8981ee lib/voice/voice_cue.dart is the same
// extract). Pure Dart.

/// Who wins when two lines want the air at once: counts are never
/// interrupted and interrupt everything else; calls (开始 / 换边 / 还剩 10 秒)
/// beat information (预告) which beats coaching tips.
enum CuePriority { coach, info, call, count }

/// One thing to say (and/or a chime to play) at [at] seconds into a phase.
/// Clip keys are [VoiceSource] keys; `chime.*` keys play on the chime
/// channel.
class VoiceCue {
  const VoiceCue(
    this.at,
    this.clips,
    this.priority, {
    this.subtitle,
    this.queueWithoutCutting = false,
    this.atWorkEnd = false,
  });
  final double at;
  final List<String> clips;
  final CuePriority priority;

  /// Shown under the drill name while it plays (coach / tip lines).
  final String? subtitle;

  /// Wait for active speech to finish. Other waiting counts are offered first.
  final bool queueWithoutCutting;

  /// Deliver this cue as a timed work phase naturally ends at [at].
  final bool atWorkEnd;

  List<String> get voiceClips =>
      clips.where((c) => !c.startsWith('chime.')).toList();
  List<String> get chimes =>
      clips.where((c) => c.startsWith('chime.')).toList();

  @override
  String toString() => '${at.toStringAsFixed(2)} ${clips.join('+')}';
}
