/// The work dose that the voice guide was authored for.
enum PoseHubVoiceGuideMode { hold, reps }

/// Spoken instructions within a repetition.
enum PoseHubVoiceGuidePhaseCues { firstTwoReps, steps }

/// A recorded action line or a shared vocabulary clip.
final class PoseHubVoiceGuideCue {
  const PoseHubVoiceGuideCue._({
    this.at,
    this.afterRep,
    this.key,
    this.clipId,
    this.zh,
    this.en,
  });

  /// Seconds into the set or, for [PoseHubVoiceGuide.steps], one repetition.
  final double? at;
  final int? afterRep;
  final String? key;
  final String? clipId;
  final String? zh;
  final String? en;

  String? text(String language) => switch (language) {
    'zh' => zh,
    'en' => en,
    _ => null,
  };
}

/// Shared vocabulary to play at the boundary following a completed set.
final class PoseHubVoiceGuideAfterSet {
  const PoseHubVoiceGuideAfterSet._({
    required this.moreSets,
    required this.moreSetsSameSide,
    required this.sideDone,
    required this.allDone,
  });

  final List<String> moreSets;
  final List<String> moreSetsSameSide;
  final List<String> sideDone;
  final List<String> allDone;
}

final class PoseHubVoiceGuideSides {
  const PoseHubVoiceGuideSides._(this.order, this.eachSideSeparately);

  final List<String> order;
  final bool eachSideSeparately;
}

/// The optional playback script delivered with a Pose-Hub action.
final class PoseHubVoiceGuide {
  const PoseHubVoiceGuide._({
    required this.mode,
    required this.set,
    required this.steps,
    required this.reminders,
    required this.before,
    required this.afterSet,
    this.phaseCues,
    this.repSeconds,
    this.repUnit,
    this.countKey,
    this.sides,
  });

  static const format = 'pose-hub-voice-guide@1';

  final PoseHubVoiceGuideMode mode;
  final List<PoseHubVoiceGuideCue> set;
  final List<PoseHubVoiceGuideCue> steps;
  final List<PoseHubVoiceGuideCue> reminders;
  final List<String> before;
  final PoseHubVoiceGuideAfterSet afterSet;
  final PoseHubVoiceGuidePhaseCues? phaseCues;
  final double? repSeconds;
  final String? repUnit;
  final String? countKey;
  final PoseHubVoiceGuideSides? sides;

  /// Read the ready script and use the authored training sides if the
  /// guide itself omits them.
  static PoseHubVoiceGuide? forAction(Map<Object?, Object?> action) {
    final guide = tryParse(action['voiceGuide']);
    if (guide == null || guide.sides != null) return guide;
    final execution = _executionOf(action);
    final training = _readMap(action['training']);
    final perSide = execution?['perSide'] ?? training?['perSide'];
    if (perSide != 'each-side-separately') return guide;
    final start =
        execution?['startingSide'] ??
        training?['startingSide'] ??
        action['startingSide'];
    return PoseHubVoiceGuide._(
      mode: guide.mode,
      set: guide.set,
      steps: guide.steps,
      reminders: guide.reminders,
      before: guide.before,
      afterSet: guide.afterSet,
      phaseCues: guide.phaseCues,
      repSeconds: guide.repSeconds,
      repUnit: guide.repUnit,
      countKey: guide.countKey,
      sides: PoseHubVoiceGuideSides._(
        start == 'left' ? const ['left', 'right'] : const ['right', 'left'],
        true,
      ),
    );
  }

  /// Unsupported, unpublished or malformed guides leave legacy speech intact.
  static PoseHubVoiceGuide? tryParse(Object? value) {
    if (value is! Map<Object?, Object?> ||
        value['format'] != format ||
        value['status'] != 'ready') {
      return null;
    }
    try {
      final mode = switch (value['mode']) {
        'hold' => PoseHubVoiceGuideMode.hold,
        'reps' => PoseHubVoiceGuideMode.reps,
        _ => throw const FormatException('Unknown voice guide mode'),
      };
      final reps = mode == PoseHubVoiceGuideMode.reps;
      final phaseCues = reps
          ? switch (value['phaseCues']) {
              'first-2-reps' => PoseHubVoiceGuidePhaseCues.firstTwoReps,
              'steps' => PoseHubVoiceGuidePhaseCues.steps,
              _ => throw const FormatException('Unknown repetition cue mode'),
            }
          : null;
      final repSeconds = reps ? _seconds(value['repSeconds']) : null;
      final count = reps ? _object(value['count']) : const <Object?, Object?>{};
      final countKey = _nonempty(count['key']);
      if (reps &&
          (repSeconds == 0 ||
              countKey == null ||
              !countKey.contains('{rep}') ||
              count['at'] != 'rep-end')) {
        return null;
      }
      final isSteps = phaseCues == PoseHubVoiceGuidePhaseCues.steps;
      final endings = _optionalObject(value['afterSet']);
      final sides = _optionalObject(value['sides']);
      return PoseHubVoiceGuide._(
        mode: mode,
        set: reps ? const [] : _cues(value['set'], required: true),
        steps: isSteps ? _cues(value['steps'], required: true) : const [],
        reminders: reps ? _cues(value['reminders'], byRep: true) : const [],
        before: _strings(value['before']),
        afterSet: PoseHubVoiceGuideAfterSet._(
          moreSets: _strings(endings['moreSets']),
          moreSetsSameSide: _strings(endings['moreSetsSameSide']),
          sideDone: _strings(endings['sideDone']),
          allDone: _strings(endings['allDone']),
        ),
        phaseCues: phaseCues,
        repSeconds: repSeconds,
        repUnit: _nonempty(value['repUnit']),
        countKey: countKey,
        sides: value['sides'] == null
            ? null
            : PoseHubVoiceGuideSides._(
                _strings(sides['order']),
                sides['perSide'] == 'each-side-separately',
              ),
      );
    } on FormatException {
      return null;
    }
  }

  /// Pack execution takes precedence over the authored training object.
  static int? sideSwitchSecondsOfAction(Map<Object?, Object?> action) {
    int? from(Map<Object?, Object?>? value) {
      final seconds = value?['sideSwitchSeconds'];
      return seconds is int && seconds >= 5 && seconds <= 20 ? seconds : null;
    }

    return from(_executionOf(action)) ?? from(_readMap(action['training']));
  }

  static Map<Object?, Object?>? _executionOf(Map<Object?, Object?> action) =>
      _readMap(_readMap(action['rhythm'])?['execution']);
}

Map<Object?, Object?>? _readMap(Object? value) =>
    value is Map<Object?, Object?> ? value : null;

Map<Object?, Object?> _object(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  throw const FormatException('Voice guide field must be an object');
}

Map<Object?, Object?> _optionalObject(Object? value) =>
    value == null ? const {} : _object(value);

String? _nonempty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

double _seconds(Object? value) {
  if (value is num && value.isFinite && value >= 0) return value.toDouble();
  throw const FormatException('Invalid voice guide timestamp');
}

List<String> _strings(Object? value) {
  if (value == null) return const [];
  if (value is! List<Object?>) {
    throw const FormatException('Voice guide keys must be an array');
  }
  return List.unmodifiable([
    for (final key in value)
      _nonempty(key) ??
          (throw const FormatException('Invalid voice guide key')),
  ]);
}

List<PoseHubVoiceGuideCue> _cues(
  Object? value, {
  bool byRep = false,
  bool required = false,
}) {
  if (value == null && !required) return const [];
  if (value is! List<Object?> || (required && value.isEmpty)) {
    throw const FormatException('Voice guide cues must be an array');
  }
  return List.unmodifiable(
    value.map((entry) {
      final cue = _object(entry);
      final key = _nonempty(cue['key']);
      final clipId = _nonempty(cue['clipId']);
      final afterRep = cue['afterRep'];
      if ((key == null && clipId == null) ||
          (byRep && (afterRep is! int || afterRep < 1))) {
        throw const FormatException('Invalid voice guide cue');
      }
      return PoseHubVoiceGuideCue._(
        at: byRep ? null : _seconds(cue['at']),
        afterRep: byRep ? afterRep as int : null,
        key: key,
        clipId: clipId,
        zh: _nonempty(cue['zh']),
        en: _nonempty(cue['en']),
      );
    }),
  );
}
