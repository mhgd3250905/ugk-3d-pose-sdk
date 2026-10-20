// Ported from HipLab@99fcc83 test/hip/hip_voice_playback_test.dart. The
// routine-timeline case now runs ugk_trainer plans (support.dart Sim).
// Voice audit 2026-10-18: lines must play to their end. On the iPhone build
// lines faded out after a word or two because the duck release (which on
// iOS deactivates the audio session) ran while the next line was still
// playing. These tests drive VoiceLineController with a fake platform that
// plays clips in real (scaled-down) time and fails on any session
// deactivation while something is audible.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

class FakePlatform implements VoicePlatform {
  FakePlatform({
    this.ios = true,
    this.clipMs = 60,
    this.playReturnsAtOnce = false,
  });
  final bool ios;

  /// Old just_audio usage: `play()` on a player still in the "playing"
  /// state (after a completed clip) returns at once.
  final bool playReturnsAtOnce;
  bool _playerPlaying = false;
  final int clipMs;
  final sw = Stopwatch()..start();
  final events = <String>[];
  final violations = <String>[];
  bool active = false;
  bool duckOption = false;
  List<String> _loaded = const [];
  Completer<void>? _playing;
  Timer? _clip;
  String? onAir;
  final finished = <String>[];
  final stopped = <String>[];
  bool chimeOn = false;

  int get now => sw.elapsedMilliseconds;
  void log(String e) => events.add('$now $e');

  @override
  bool get isIOS => ios;

  @override
  Future<void> configureSession({required bool duck}) async {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    duckOption = duck;
    log('configure duck=$duck');
  }

  @override
  Future<void> setSessionActive(bool on) async {
    await Future<void>.delayed(const Duration(milliseconds: 3));
    if (!on && (voiceAudible || chimeAudible)) {
      violations.add('deactivated at $now while ${onAir ?? 'chime'} audible');
    }
    active = on;
    log('active=$on');
  }

  @override
  Future<void> keepAlivePause() async => log('keepAlive pause');
  @override
  Future<void> keepAliveResume() async => log('keepAlive play');
  @override
  Future<void> setVoiceVolume(double v) async {}

  @override
  Future<void> loadVoice(List<String> assets) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _loaded = assets;
  }

  @override
  Future<void> playVoiceToEnd() {
    if (onAir != null) {
      violations.add('$onAir replaced by ${_loaded.join('+')} at $now');
      stopped.add(onAir!);
      _finish();
    }
    if (!active) violations.add('${_loaded.join('+')} played without session');
    final name = _loaded.join('+');
    onAir = name;
    log('play $name');
    final c = _playing = Completer<void>();
    final returnAtOnce = playReturnsAtOnce && _playerPlaying;
    _playerPlaying = true;
    _clip = Timer(Duration(milliseconds: clipMs * _loaded.length), () {
      finished.add(name);
      log('end $name');
      _finish();
    });
    return returnAtOnce ? Future.value() : c.future;
  }

  void _finish() {
    _clip?.cancel();
    onAir = null;
    final c = _playing;
    _playing = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> stopVoice() async {
    if (onAir != null) {
      stopped.add(onAir!);
      log('stop $onAir');
    }
    _finish();
  }

  @override
  bool get voiceAudible => onAir != null;
  @override
  bool get chimeAudible => chimeOn;
}

class DelayedPlatform extends FakePlatform {
  final configureStarted = Completer<void>();
  final configureGate = Completer<void>();
  bool delayConfigure = false;
  int configureCalls = 0;
  final volumeStarted = Completer<void>();
  final volumeGate = Completer<void>();
  final loadStarted = Completer<void>();
  final loadGate = Completer<void>();
  bool delayVolume = false;
  bool delayLoad = false;
  int volumeCalls = 0;

  @override
  Future<void> configureSession({required bool duck}) async {
    if (delayConfigure && configureCalls++ == 0) {
      configureStarted.complete();
      await configureGate.future;
    }
    await super.configureSession(duck: duck);
  }

  @override
  Future<void> setVoiceVolume(double v) async {
    if (delayVolume && volumeCalls++ == 0) {
      volumeStarted.complete();
      await volumeGate.future;
    }
  }

  @override
  Future<void> loadVoice(List<String> assets) async {
    if (delayLoad) {
      loadStarted.complete();
      await loadGate.future;
    }
    await super.loadVoice(assets);
  }
}

class FailingPlatform extends FakePlatform {
  @override
  Future<void> playVoiceToEnd() => Future.error(StateError('decode failed'));
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  VoiceLineController controller(FakePlatform p) => VoiceLineController(
    p,
    releaseDelay: const Duration(milliseconds: 40),
    maxTailWait: const Duration(milliseconds: 400),
  );

  test('a line plays to its end; the duck is released only after it', () async {
    final p = FakePlatform();
    final c = controller(p);
    await c.speak(['a']);
    expect(p.finished, ['a']);
    expect(c.ducking, isTrue, reason: 'release waits releaseDelay');
    await wait(120);
    expect(c.ducking, isFalse);
    expect(p.violations, isEmpty);
    // iOS: deactivate (lift the duck) and take the session straight back.
    expect(p.active, isTrue);
  });

  test('the next line inside the release window keeps the session '
      '(the iPhone bug: the release cut it after ~0.7 s)', () async {
    final p = FakePlatform();
    final c = controller(p);
    await c.speak(['a']);
    await wait(15); // < releaseDelay
    final b = c.speak(['b']);
    await wait(30); // the old release moment falls inside b
    await b;
    expect(p.finished, ['a', 'b']);
    expect(p.stopped, isEmpty);
    expect(p.violations, isEmpty);
    expect(
      p.events.where((e) => e.endsWith('active=false')),
      isEmpty,
      reason: 'no deactivation between back-to-back lines',
    );
  });

  test('second guard: even if play() returned at once (the old just_audio '
      'case), the release waits until nothing is audible', () async {
    final p = FakePlatform(clipMs: 120, playReturnsAtOnce: true);
    final c = controller(p);
    await c.speak(['first']);
    await c.speak(['second']); // returns at once, release due 40 ms later
    await wait(400);
    expect(p.finished, ['first', 'second']);
    expect(p.violations, isEmpty);
    expect(c.ducking, isFalse);
  });

  test('a release that is already running finishes before the next line '
      'activates the session again', () async {
    final p = FakePlatform();
    final c = controller(p);
    await c.speak(['a']);
    await wait(42); // release has just started its platform calls
    await c.speak(['b']);
    expect(p.finished, ['a', 'b']);
    expect(p.violations, isEmpty);
  });

  test('a line asked for while the previous one is still audible waits for '
      'its end instead of clipping its tail', () async {
    final p = FakePlatform(clipMs: 80);
    final c = controller(p);
    unawaited(c.speak(['long', 'line']));
    await wait(100); // the queue's clock says "free", the clip still plays
    await c.speak(['next']);
    expect(p.finished, ['long+line', 'next']);
    expect(p.stopped, isEmpty);
    expect(p.violations, isEmpty);
  });

  test(
    'a deliberate cut (stopSpeech, e.g. a count) takes over at once',
    () async {
      final p = FakePlatform(clipMs: 200);
      final c = controller(p);
      unawaited(c.speak(['coach']));
      await wait(60);
      await c.stopSpeech();
      final t0 = p.now;
      unawaited(c.speak(['n.3']));
      await wait(40);
      expect(p.onAir, 'n.3');
      expect(p.now - t0, lessThan(150));
      expect(p.stopped, ['coach']);
      await wait(300);
      expect(p.violations, isEmpty);
    },
  );

  test('the duck is not released while a chime is still sounding', () async {
    final p = FakePlatform();
    final c = controller(p);
    p.chimeOn = true;
    await c.speak(['a']);
    await wait(120);
    expect(c.ducking, isTrue);
    p.chimeOn = false;
    await wait(120);
    expect(c.ducking, isFalse);
    expect(p.violations, isEmpty);
  });

  test('after an interruption the old line never releases anything', () async {
    final p = FakePlatform(clipMs: 100);
    final c = controller(p);
    unawaited(c.speak(['a']));
    await wait(30);
    c
      ..abandon()
      ..forgetDuck();
    await p.stopVoice();
    final before = p.events.length;
    await wait(200);
    expect(
      p.events.skip(before).where((e) => e.contains('active=false')),
      isEmpty,
    );
  });

  for (final ios in [true, false]) {
    test('random cue storm (${ios ? 'iOS' : 'Android'}): never deactivated '
        'while audible, never two lines at once', () async {
      final rnd = math.Random(7);
      final p = FakePlatform(ios: ios, clipMs: 30);
      final c = controller(p);
      final calls = <Future<void>>[];
      for (var i = 0; i < 60; i++) {
        await wait(rnd.nextInt(90));
        if (rnd.nextInt(4) == 0) await c.stopSpeech();
        calls.add(c.speak(['l$i', if (rnd.nextBool()) 'm$i']));
      }
      await Future.wait(calls);
      await wait(150);
      expect(p.violations, isEmpty, reason: p.events.join('\n'));
      expect(c.ducking, isFalse);
    });
  }

  test('no line is cut by the session timeline (HipLab kits and SmartFit '
      'packs, both HipLab languages)', () {
    for (final (name, sim) in [
      for (final lang in ['zh', 'en']) ('hiplab $lang', () => hipSim(lang)),
      ('smartfit zh', smartSim),
    ]) {
      final s = sim()..run();
      final cut = s.lines.where((l) => l.cutAt != null);
      expect(cut, isEmpty, reason: '$name: $cut');
      expect(
        s.lines.length,
        s.fired.where((f) => f.cue.voiceClips.isNotEmpty).length,
        reason: '$name: a cue was dropped',
      );
    }
  });

  test('stop cancels a line still loading before any sound starts', () async {
    final p = DelayedPlatform()..delayLoad = true;
    final c = controller(p);
    final line = c.speak(['stale']);
    await p.loadStarted.future;
    final stopped = c.stopSpeech();
    p.loadGate.complete();
    await Future.wait([line, stopped]);
    await wait(120);
    expect(p.events.where((e) => e.contains('play stale')), isEmpty);
    expect(p.finished, isEmpty);
    expect(c.ducking, isFalse);
  });

  test('abandoned queued activation never takes audio focus', () async {
    final p = FakePlatform();
    final c = controller(p);
    final gate = Completer<void>();
    final held = c.serial(() => gate.future);
    final line = c.speak(['stale']);
    c.abandon();
    gate.complete();
    await Future.wait([held, line]);
    expect(p.events, isEmpty);
    expect(c.ducking, isFalse);
  });

  // Android voice fix 2026-10-19: this used to expect ['new'] only – a line
  // still preparing was dropped by the next request, which is how a slow
  // (background) player swallowed whole 3-2-1 countdowns. Lines now keep
  // their order and never overlap; only stopSpeech / abandon drop them.
  test('a line still preparing is not dropped by the next one: both play, '
      'in order, never over each other', () async {
    final p = DelayedPlatform()..delayVolume = true;
    final c = controller(p);
    final old = c.speak(['old']);
    await p.volumeStarted.future;
    final next = c.speak(['new']);
    p.volumeGate.complete();
    await Future.wait([old, next]);
    expect(p.finished, ['old', 'new']);
    expect(p.stopped, isEmpty);
    expect(p.violations, isEmpty);
    await wait(120);
    expect(c.ducking, isFalse);
  });

  test('ending during load cannot restart a voice or keep-alive', () async {
    final p = DelayedPlatform()..delayLoad = true;
    var active = true;
    final c = VoiceLineController(p, isActive: () => active);
    final line = c.speak(['stale']);
    await p.loadStarted.future;
    active = false;
    c.abandon();
    p.loadGate.complete();
    await line;
    expect(p.events.where((e) => e.contains('play stale')), isEmpty);
    expect(p.events.where((e) => e.contains('keepAlive play')), isEmpty);
    c.forgetDuck();
  });

  test(
    'cancelled configure does not mark the next line already ducked',
    () async {
      final p = DelayedPlatform()..delayConfigure = true;
      final c = controller(p);
      final old = c.speak(['old']);
      await p.configureStarted.future;
      final stopped = c.stopSpeech();
      final next = c.speak(['new']);
      p.configureGate.complete();
      await Future.wait([old, stopped, next]);
      expect(p.finished, ['new']);
      expect(p.violations, isEmpty, reason: p.events.join('\n'));
      expect(p.events.where((e) => e.endsWith('active=true')), isNotEmpty);
      await wait(120);
      expect(c.ducking, isFalse);
    },
  );

  test(
    'an immediately failing play future is handled before serial yields',
    () async {
      final p = FailingPlatform();
      final c = controller(p);
      await c.speak(['bad']);
      await wait(120);
      expect(c.ducking, isFalse);
      expect(p.violations, isEmpty);
    },
  );
}
