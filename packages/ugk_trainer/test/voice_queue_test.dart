// Ported from HipLab@99fcc83 test/hip/hip_voice_android_fix_test.dart and
// test/hip/hip_voice_pr24_review_test.dart (group F24-2), plus SmartFit@e8981ee
// test/voice_session_test.dart (group 'voice queue').

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';
import 'voice_line_controller_test.dart' show FakePlatform, wait;

/// Every prepare takes [loadMs] (a slow, backgrounded player).
class SlowLoadPlatform extends FakePlatform {
  SlowLoadPlatform({required this.loadMs, super.clipMs = 40})
    : super(ios: false);
  final int loadMs;
  @override
  Future<void> loadVoice(List<String> assets) async {
    await wait(loadMs);
    await super.loadVoice(assets);
  }
}

class _GatedVolumePlatform extends FakePlatform {
  _GatedVolumePlatform() : super(ios: false, clipMs: 20);
  final applied = <double>[];
  Completer<void>? gate;
  @override
  Future<void> setVoiceVolume(double v) async {
    final g = gate;
    if (g != null) await g.future;
    applied.add(v);
  }
}

void main() {
  group('3: numbers are never swallowed', () {
    test('3-2-1 asked faster than the player prepares: all three play, in '
        'order (before: each number dropped the one before it)', () async {
      final p = SlowLoadPlatform(loadMs: 120);
      final c = VoiceLineController(
        p,
        releaseDelay: const Duration(milliseconds: 40),
      );
      final calls = <Future<void>>[];
      for (final n in ['n.3', 'n.2', 'n.1']) {
        calls.add(c.speak([n]));
        await wait(60); // next number before the previous one has loaded
      }
      await Future.wait(calls);
      expect(p.finished, ['n.3', 'n.2', 'n.1']);
      expect(p.stopped, isEmpty);
      expect(p.violations, isEmpty);
    });

    test('the backlog rule counts from the time the line was asked for '
        'upstream (PR #7 fourth review)', () async {
      final p = SlowLoadPlatform(loadMs: 0);
      final skipped = <String>[];
      final c = VoiceLineController(
        p,
        releaseDelay: const Duration(milliseconds: 40),
        onSkip: (a) => skipped.addAll(a),
      );
      final first = c.speak(['coach']);
      // Asked for 3.1 s ago upstream (the output waited for its session).
      final late = c.speak([
        'p.go',
      ], asked: DateTime.now().subtract(const Duration(milliseconds: 3100)));
      final count = c.speak(['n.1']);
      await Future.wait([first, late, count]);
      expect(p.finished, ['coach', 'n.1']);
      expect(skipped, ['p.go']);
    });

    test(
      'a deliberate cut still drops everything asked for before it',
      () async {
        final p = SlowLoadPlatform(loadMs: 80);
        final c = VoiceLineController(p);
        final a = c.speak(['coach']);
        final b = c.speak(['info']);
        await wait(20);
        await c.stopSpeech();
        final n = c.speak(['n.3']);
        await Future.wait([a, b, n]);
        expect(p.finished, ['n.3']);
      },
    );

    test('a backlog line more than staleAfter late is skipped only when a '
        'newer one waits', () async {
      final p = SlowLoadPlatform(loadMs: 10, clipMs: 200);
      final skipped = <String>[];
      final c = VoiceLineController(
        p,
        releaseDelay: const Duration(milliseconds: 40),
        staleAfter: const Duration(milliseconds: 100),
        onSkip: (a) => skipped.addAll(a),
      );
      final calls = [
        c.speak(['long']),
        c.speak(['late']), // waits ~210 ms > staleAfter, 'last' behind it
        c.speak(['last']),
      ];
      await Future.wait(calls);
      expect(p.finished, ['long', 'last']);
      expect(skipped, ['late']);
    });
  });

  group('2: line endings are not chopped', () {
    VoiceQueue queueWith(RecordingOutput out) => VoiceQueue(
      output: out,
      lib: ManifestVoiceSource(
        {
          'zh': {'info': 3000, 'n.3': 464},
        },
        const {},
        const {},
        const {},
      ),
      settings: const VoiceSettings(chimes: false),
    );

    test('a count with only the last word left lets the line finish and '
        'follows it', () {
      final out = RecordingOutput();
      final q = queueWith(out);
      q.submit(const VoiceCue(0, ['info'], CuePriority.info), 0);
      q.submit(const VoiceCue(0, ['n.3'], CuePriority.count), 2.4);
      expect(out.stops, 0, reason: '0.6 s left ≤ tailGrace');
      expect(q.log.first.cutAt, isNull);
      expect(out.spoken.length, 2);
    });

    test('a count still cuts a line that has a lot left (by design)', () {
      final out = RecordingOutput();
      final q = queueWith(out);
      q.submit(const VoiceCue(0, ['info'], CuePriority.info), 0);
      q.submit(const VoiceCue(0, ['n.3'], CuePriority.count), 1.0);
      expect(out.stops, 1);
      expect(q.log.first.cutAt, 1.0);
    });
  });

  group('F24-2: the last volume asked for wins', () {
    test('lowered while the previous setVoiceVolume is in flight', () async {
      final p = _GatedVolumePlatform();
      final c = VoiceLineController(
        p,
        releaseDelay: const Duration(milliseconds: 20),
      );
      c.volume = 1.0;
      p.gate = Completer<void>();
      final first = c.speak(['a']);
      await wait(30); // first line is inside setVoiceVolume(1.0)
      c.volume = 0.25; // slider moved, 试听 again
      p.gate!.complete();
      p.gate = null;
      await first;
      await c.speak(['b']);
      expect(p.applied, [1.0, 0.25]);
      expect(p.finished, ['a', 'b']);
    });

    test('unchanged volume is not re-sent for every line', () async {
      final p = _GatedVolumePlatform();
      final c = VoiceLineController(
        p,
        releaseDelay: const Duration(milliseconds: 20),
      );
      c.volume = .5;
      await c.speak(['a']);
      await c.speak(['b']);
      expect(p.applied, [.5]);
      c.volume = .8;
      await c.speak(['c']);
      expect(p.applied, [.5, .8]);
    });
  });

  group('voice queue (SmartFit)', () {
    final voices = smartSource();

    test('higher priorities interrupt coaching; calls wait for counts', () {
      final output = RecordingOutput();
      final queue = VoiceQueue(
        output: output,
        lib: voices,
        settings: const VoiceSettings(),
      );
      queue.submit(const VoiceCue(0, ['p.slow'], CuePriority.coach), 0);
      queue.submit(const VoiceCue(0, ['p.half'], CuePriority.info), .1);
      queue.submit(const VoiceCue(0, ['n.1'], CuePriority.count), .2);
      queue.submit(const VoiceCue(0, ['p.go'], CuePriority.call), .3);
      expect(output.spoken, hasLength(3));
      expect(output.stops, 2);
      queue.tick(.8);
      expect(queue.log.map((line) => line.clips.single), [
        'p.slow',
        'p.half',
        'n.1',
        'p.go',
      ]);
      expect(queue.log[0].cutAt, .1);
      expect(queue.log[1].cutAt, .2);
      expect(queue.log[2].cutAt, isNull);
      expect(output.spoken.last, [voices.asset('p.go', lang: 'zh')]);
    });

    test('cancel clears pending lines and stops the current line', () {
      final output = RecordingOutput();
      final queue = VoiceQueue(
        output: output,
        lib: voices,
        settings: const VoiceSettings(),
      );
      queue.submit(const VoiceCue(0, ['n.1'], CuePriority.count), 0);
      queue.submit(const VoiceCue(0, ['p.half'], CuePriority.info), .1);
      queue.cancelAll(.2);
      queue.tick(1);
      expect(output.spoken, hasLength(1));
      expect(output.stops, 1);
      expect(queue.log.single.cutAt, .2);
    });

    test('chimes remain available with spoken coaching switched off', () {
      final output = RecordingOutput();
      final queue = VoiceQueue(
        output: output,
        lib: voices,
        settings: const VoiceSettings(voice: false),
      );
      queue.submit(
        const VoiceCue(0, ['chime.tick', 'n.3'], CuePriority.count),
        0,
      );
      expect(output.chimes, [voices.asset('chime.tick', lang: 'zh')]);
      expect(output.spoken, isEmpty);
    });
  });

  group('PR #7 review 3: a start is what the output confirms', () {
    test('a line queued behind a tail is reported only once it starts, '
        'and never after cancelAll dropped it', () {
      final source = smartSource();
      final probe = SerialVoiceProbe.forSource(source);
      final reported = <String>[];
      final q = VoiceQueue(
        output: probe,
        lib: source,
        settings: const VoiceSettings(),
        onStarted: (cue) => reported.add(cue.clips.join('+')),
      );
      q.submit(const VoiceCue(0, ['chime.start', 'p.go'], CuePriority.call), 0);
      expect(reported, ['chime.start+p.go']);
      // p.go (673 ms) has < tailGrace left: the count follows it.
      q.submit(const VoiceCue(.1, ['n.1'], CuePriority.count), .1);
      expect(probe.submitted, hasLength(2));
      expect(probe.started, hasLength(1));
      expect(reported, ['chime.start+p.go'], reason: 'submitted, not started');
      q.cancelAll(.12);
      expect(probe.started, hasLength(1));
      expect(reported, ['chime.start+p.go']);
    });

    test('an output that cannot confirm a start reports nothing', () {
      final source = smartSource();
      final reported = <VoiceCue>[];
      final q = VoiceQueue(
        output: const MutedVoiceOutput(),
        lib: source,
        settings: const VoiceSettings(),
        onStarted: reported.add,
      );
      q.submit(const VoiceCue(0, ['chime.start', 'p.go'], CuePriority.call), 0);
      q.submit(const VoiceCue(0, ['chime.tick'], CuePriority.count), 1);
      expect(reported, isEmpty);
    });
  });
}
