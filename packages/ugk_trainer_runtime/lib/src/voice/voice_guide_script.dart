part of 'session_script.dart';

extension _VoiceGuideScript on SessionScript {
  List<VoiceCue> _queuedGuideCues(List<VoiceCue> cues) => [
    for (final cue in cues)
      VoiceCue(
        cue.at,
        cue.clips,
        cue.priority,
        subtitle: cue.subtitle,
        queueWithoutCutting: true,
      ),
  ];

  void _placeGuideBefore(_Timeline timeline, String exerciseId) {
    final before = source.voiceGuide(exerciseId)?.before;
    if (before == null || before.isEmpty) return;
    final clips = [for (final key in before) ..._guideCommon(key)];
    if (clips.isNotEmpty) timeline.place([clips], CuePriority.call);
  }

  List<String> _guideCommon(String key) =>
      source.voiceGuideCommonKeys(key, lang: lang);

  List<VoiceCue> _guideCountdown(double end) => [
    for (var k = 3; k >= 1; k--)
      if (end > k)
        VoiceCue(end - k, [
          'chime.tick',
          ..._guideCommon('n.$k'),
        ], CuePriority.count),
  ];

  List<String> _guideLine(String exerciseId, PoseHubVoiceGuideCue cue) {
    if (cue.key case final key?) return _guideCommon(key);
    final clipId = cue.clipId;
    return [
      if (clipId != null)
        ?source.voiceGuideClipKey(exerciseId, clipId, lang: lang),
    ];
  }

  List<VoiceCue>? _guidedWork(SessionPhase phase) {
    final id = phase.exerciseId;
    if (id == null || phase.selfPaced) return null;
    final guide = source.voiceGuide(id);
    if (guide == null) return null;
    final counting = guide.mode == PoseHubVoiceGuideMode.reps;
    if (counting != phase.countedOnClock) return null;
    final cues = <VoiceCue>[];
    void add(
      double at,
      List<String> clips,
      CuePriority priority, {
      bool boundary = false,
      String? subtitle,
    }) {
      if (clips.isEmpty) return;
      cues.add(
        VoiceCue(
          at,
          clips,
          priority,
          subtitle: subtitle,
          queueWithoutCutting: true,
          atWorkEnd: boundary,
        ),
      );
    }

    void line(double at, PoseHubVoiceGuideCue cue, double deadline) {
      final clips = _guideLine(id, cue);
      if (clips.isEmpty || at + len(clips) > deadline + 1e-9) return;
      add(
        at,
        clips,
        CuePriority.coach,
        subtitle: cue.key == null
            ? source.line(clips.first, lang: lang) ??
                  (lang == 'zh' ? cue.zh : cue.en)
            : null,
      );
    }

    if (!counting) {
      for (final cue in guide.set) {
        final at = cue.at!;
        final key = cue.key;
        if (key == 'n.3' || key == 'n.2' || key == 'n.1') continue;
        if (at == 0 && key == 'p.go') {
          add(0, ['chime.start', ..._guideCommon('p.go')], CuePriority.call);
        } else {
          line(at, cue, phase.seconds - 4);
        }
      }
      for (var k = 3; k >= 1; k--) {
        final at = phase.seconds - k;
        if (at > 0) {
          add(at, ['chime.tick', ..._guideCommon('n.$k')], CuePriority.count);
        }
      }
    } else {
      final rhythm = phase.rhythm!;
      final plan = rhythm.repPlan(
        reps: phase.reps,
        hold: phase.holdSeconds,
        seconds: phase.seconds,
      );
      final steps = guide.phaseCues == PoseHubVoiceGuidePhaseCues.steps;
      add(0, ['chime.start', ..._guideCommon('p.go')], CuePriority.call);
      for (var rep = 1; rep <= plan.reps; rep++) {
        final start = plan.repStart(0, rep);
        final finalRep = rep == plan.reps;
        final end = finalRep ? phase.seconds : start + plan.cycle;
        if (steps) {
          for (final step in guide.steps) {
            line(start + step.at!, step, end - .8);
          }
        } else if (rep <= 2) {
          var at = start;
          for (final part in plan.phases) {
            final clipId = part.guideCue ?? part.cueFor(rep);
            if (clipId != null && clipId.startsWith('phase.')) {
              final key = source.voiceGuideClipKey(id, clipId, lang: lang);
              add(at + part.cueAt, [?key], CuePriority.call);
            }
            at += part.seconds;
          }
        }
        final count = _guideCommon(guide.countKey!.replaceAll('{rep}', '$rep'));
        add(
          end,
          count.isEmpty ? ['chime.tick'] : count,
          CuePriority.count,
          boundary: finalRep,
        );
        if (finalRep) continue;
        final remindersAt = end + len(count) + (count.isEmpty ? 0 : .06);
        for (final reminder in guide.reminders) {
          final last = reminder.key == 'p.last_rep';
          if (last ? rep == plan.reps - 1 : rep == reminder.afterRep) {
            // If a shorter dose moves the final reminder onto an existing
            // coaching reminder, keep the final-rep announcement first.
            if (!last &&
                rep == plan.reps - 1 &&
                guide.reminders.any((cue) => cue.key == 'p.last_rep')) {
              continue;
            }
            line(remindersAt, reminder, end + plan.cycle);
          }
        }
      }
    }

    final exit = phase.voiceGuideSetExit;
    final after = switch (exit) {
      VoiceGuideSetExit.moreSets => guide.afterSet.moreSets,
      VoiceGuideSetExit.moreSetsSameSide =>
        guide.afterSet.moreSetsSameSide.isEmpty
            ? guide.afterSet.moreSets
            : guide.afterSet.moreSetsSameSide,
      VoiceGuideSetExit.sideDone => guide.afterSet.sideDone,
      VoiceGuideSetExit.allDone => guide.afterSet.allDone,
      null => const <String>[],
    };
    final rest = phase.item?.restSeconds;
    final sameExerciseRest =
        exit == VoiceGuideSetExit.moreSets ||
        exit == VoiceGuideSetExit.moreSetsSameSide;
    add(
      phase.seconds,
      [
        for (final key in after)
          ..._guideCommon(
            sameExerciseRest && key.startsWith('sec.') && rest != null
                ? 'sec.$rest'
                : key == 'p.switch_left' || key == 'p.switch_right'
                ? (phase.side == Side.left ? 'p.switch_right' : 'p.switch_left')
                : key,
          ),
      ],
      CuePriority.call,
      boundary: true,
    );
    // Preserve insertion order for coincident events. The queue can put a
    // count first without cutting the line already on the audio channel.
    return [
      for (final entry
          in (cues.indexed.toList()..sort((a, b) {
            final at = a.$2.at.compareTo(b.$2.at);
            return at == 0 ? a.$1.compareTo(b.$1) : at;
          })))
        entry.$2,
    ];
  }
}
