// Ported from HipLab@99fcc83 test/hip/just_audio_output_test.dart. Unchanged
// except the import. Android continuous keep-alive regressions added below.
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _Player extends Fake implements AudioPlayer {
  _Player(this.events, {this.autoComplete = true});
  final List<String> events;
  final bool autoComplete;
  final states = StreamController<PlayerState>.broadcast(sync: true);
  PlayerState state = PlayerState(false, ProcessingState.idle);
  Completer<void>? playback;
  int stops = 0;
  int pauses = 0;
  final playingStarted = <Completer<void>>[];

  void emit(bool playing, ProcessingState processing) {
    state = PlayerState(playing, processing);
    states.add(state);
  }

  void complete() {
    // just_audio keeps playing=true when processingState becomes completed.
    emit(true, ProcessingState.completed);
    if (playback case final done? when !done.isCompleted) done.complete();
  }

  @override
  bool get playing => state.playing;
  @override
  ProcessingState get processingState => state.processingState;
  @override
  Stream<PlayerState> get playerStateStream => Stream.multi((events) {
    events.add(state);
    final sub = states.stream.listen(events.add);
    events.onCancel = sub.cancel;
  });
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    emit(false, ProcessingState.ready);
    return Duration.zero;
  }

  @override
  Future<void> play() {
    if (playing) return Future.value();
    playback = Completer<void>();
    events.add('play');
    emit(true, ProcessingState.ready);
    for (final started in playingStarted) {
      if (!started.isCompleted) started.complete();
    }
    if (autoComplete) complete();
    return playback!.future;
  }

  @override
  Future<void> pause() async {
    pauses++;
    emit(false, processingState);
    if (playback case final done? when !done.isCompleted) done.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    emit(false, ProcessingState.idle);
    if (playback case final done? when !done.isCompleted) done.complete();
  }

  @override
  Future<void> dispose() => states.close();
}

class _Session extends Fake implements AudioSession {
  _Session(
    this.events, {
    this.noisy = const Stream.empty(),
    this.interruptions = const Stream.empty(),
  });
  final List<String> events;
  final Stream<void> noisy;
  final Stream<AudioInterruptionEvent> interruptions;
  final configurations = <AudioSessionConfiguration>[];
  @override
  Stream<void> get becomingNoisyEventStream => noisy;
  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream => interruptions;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations.add(configuration);
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    events.add('active:$active');
    return true;
  }
}

/// Realistic independent loop player: play stays pending until paused/stopped.
class _LoopPlayer extends _Player {
  _LoopPlayer(super.events, {this.loading}) : super(autoComplete: false);
  final Completer<void>? loading;
  AudioSource? source;
  LoopMode? mode;
  final assets = <String>[];
  final volumes = <double>[];
  @override
  AudioSource? get audioSource => source;
  @override
  Future<Duration?> setAsset(
    String assetPath, {
    String? package,
    bool preload = true,
    Duration? initialPosition,
    dynamic tag,
  }) async {
    assets.add(assetPath);
    source = AudioSource.asset(assetPath);
    await loading?.future;
    emit(false, ProcessingState.ready);
    return Duration.zero;
  }

  @override
  Future<void> setLoopMode(LoopMode value) async {
    mode = value;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }
}

/// Records the clip names of every line loaded into the voice player.
class _NamedPlayer extends _Player {
  _NamedPlayer(super.events);
  final loaded = <String>[];
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) {
    for (final s in audioSources) {
      loaded.add((s as UriAudioSource).uri.pathSegments.last);
    }
    return super.setAudioSources(audioSources);
  }
}

/// A real [VoiceQueue] on a [JustAudioVoiceOutput] whose [AudioSession]
/// initialization is held by [session] (PR #7 fourth review).
({JustAudioVoiceOutput output, VoiceQueue queue, _NamedPlayer voice})
_gatedQueue(Completer<AudioSession> session, List<String> started) {
  final events = <String>[];
  final voice = _NamedPlayer(events);
  final output = JustAudioVoiceOutput.forTesting(
    voice: voice,
    chime: _Player(events),
    keepAlive: _Player(events),
    session: () => session.future,
  );
  final queue = VoiceQueue(
    output: output,
    lib: ManifestVoiceSource(
      {
        'zh': {'p.go': 800, 'n.1': 464},
      },
      const {},
      const {},
      const {},
    ),
    settings: const VoiceSettings(chimes: false),
    onStarted: (cue) => started.add(cue.clips.join('+')),
  );
  return (output: output, queue: queue, voice: voice);
}

void main() {
  group('slow audio initialization (PR #7 fourth review)', () {
    test('a call that went stale while the session initialized is dropped '
        'once a newer count is asked for: only the count plays and only it '
        'reports a start', () async {
      var now = DateTime(2026, 10, 27, 10);
      await withClock(Clock(() => now), () async {
        final session = Completer<AudioSession>();
        final started = <String>[];
        final t = _gatedQueue(session, started);
        final beginning = t.output.begin();
        t.queue.submit(const VoiceCue(0, ['p.go'], CuePriority.call), 0);
        await Future<void>.delayed(Duration.zero);
        // Training time runs on; the audio session is still initializing.
        now = now.add(const Duration(milliseconds: 3200));
        t.queue.submit(const VoiceCue(0, ['n.1'], CuePriority.count), 3.2);
        await Future<void>.delayed(Duration.zero);
        expect(t.voice.loaded, isEmpty);
        session.complete(_Session([]));
        await beginning;
        await pumpEventQueue();
        expect(t.voice.loaded, ['n.1.m4a']);
        expect(started, ['n.1']);
        await t.output.dispose();
      });
    });

    test('a short initialization delay keeps the adjacent call and first '
        'count: both play in order and both report their start', () async {
      var now = DateTime(2026, 10, 27, 10);
      await withClock(Clock(() => now), () async {
        final session = Completer<AudioSession>();
        final started = <String>[];
        final t = _gatedQueue(session, started);
        final beginning = t.output.begin();
        t.queue.submit(const VoiceCue(0, ['p.go'], CuePriority.call), 0);
        // The count lands in the call's last 0.3 s (≤ tailGrace): queued
        // behind it, not cut.
        t.queue.submit(const VoiceCue(0, ['n.1'], CuePriority.count), .5);
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(milliseconds: 500));
        expect(t.voice.loaded, isEmpty);
        session.complete(_Session([]));
        await beginning;
        await pumpEventQueue();
        expect(t.voice.loaded, ['p.go.m4a', 'n.1.m4a']);
        expect(started, ['p.go', 'n.1']);
        await t.output.dispose();
      });
    });

    test('a stale line with nothing newer behind it still plays (same rule '
        'as the controller backlog)', () async {
      var now = DateTime(2026, 10, 27, 10);
      await withClock(Clock(() => now), () async {
        final session = Completer<AudioSession>();
        final started = <String>[];
        final t = _gatedQueue(session, started);
        final beginning = t.output.begin();
        t.queue.submit(const VoiceCue(0, ['p.go'], CuePriority.call), 0);
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(milliseconds: 3200));
        session.complete(_Session([]));
        await beginning;
        await pumpEventQueue();
        expect(t.voice.loaded, ['p.go.m4a']);
        expect(started, ['p.go']);
        await t.output.dispose();
      });
    });
  });

  test('unplugging stops both players and releases music focus', () async {
    final events = <String>[];
    final noisy = StreamController<void>.broadcast(sync: true);
    final voice = _Player(events);
    final chime = _Player(events);
    final output = JustAudioVoiceOutput.forTesting(
      voice: voice,
      chime: chime,
      keepAlive: _Player(events),
      session: () async => _Session(events, noisy: noisy.stream),
    );
    await output.begin();
    await output.speak(['assets/voice/zh/p.welcome.m4a']);
    expect(events, ['active:true', 'play']);
    noisy.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(voice.stops, 1);
    expect(chime.stops, 1);
    expect(events, ['active:true', 'play', 'active:false']);
    await output.dispose();
    await noisy.close();
  });

  test(
    'first speech waits for initialization and acquires focus before play',
    () async {
      final events = <String>[];
      final session = Completer<AudioSession>();
      final player = _Player(events);
      final output = JustAudioVoiceOutput.forTesting(
        voice: player,
        chime: player,
        keepAlive: player,
        session: () => session.future,
      );
      final beginning = output.begin();
      final speech = output.speak(['assets/voice/zh/p.welcome.m4a']);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      session.complete(_Session(events));
      await beginning;
      await speech;
      expect(events, ['active:true', 'play']);
      await output.dispose();
    },
  );

  test(
    'ending while initialization is pending prevents stale speech',
    () async {
      final events = <String>[];
      final session = Completer<AudioSession>();
      final player = _Player(events);
      final output = JustAudioVoiceOutput.forTesting(
        voice: player,
        chime: player,
        keepAlive: player,
        session: () => session.future,
      );
      final beginning = output.begin();
      final speech = output.speak(['assets/voice/zh/p.welcome.m4a']);
      await Future<void>.delayed(Duration.zero);
      final ending = output.end();
      session.complete(_Session(events));
      await Future.wait([beginning, speech, ending]);
      expect(events, isNot(contains('play')));
      expect(events, isNot(contains('active:true')));
      await output.dispose();
    },
  );

  test('adapter waits for each completed line, then resets playing', () async {
    final events = <String>[];
    final voice = _Player(events, autoComplete: false);
    final output = JustAudioVoiceOutput.forTesting(
      voice: voice,
      chime: _Player(events),
      keepAlive: _Player(events),
      session: () async => _Session(events),
    );
    await output.begin();
    for (var i = 0; i < 2; i++) {
      final started = Completer<void>();
      voice.playingStarted.add(started);
      var finished = false;
      final line = output.speak(['line$i']).then((_) => finished = true);
      await started.future;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      voice.complete();
      await line;
      expect(voice.playing, isFalse);
    }
    expect(events.where((e) => e == 'play').length, 2);
    await output.dispose();
  });

  test('lines asked for in one turn all play in order and report their '
      'real start; a line stopped before its turn never does', () async {
    final events = <String>[];
    final voice = _Player(events, autoComplete: false);
    final output = JustAudioVoiceOutput.forTesting(
      voice: voice,
      chime: _Player(events),
      keepAlive: _Player(events),
      session: () async => _Session(events),
    );
    await output.begin();
    final started = <String>[];
    final firstPlaying = Completer<void>();
    voice.playingStarted.add(firstPlaying);
    final a = output.speakReportingStart(['a'], () => started.add('a'));
    final b = output.speakReportingStart(['b'], () => started.add('b'));
    await firstPlaying.future;
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a'], reason: 'b is asked for but waits behind a');
    final secondPlaying = Completer<void>();
    voice.playingStarted.add(secondPlaying);
    voice.complete();
    await secondPlaying.future;
    await Future<void>.delayed(Duration.zero);
    expect(started, ['a', 'b']);
    final c = output.speakReportingStart(['c'], () => started.add('c'));
    await output.stopSpeech();
    await Future.wait([a, b, c]);
    expect(started, ['a', 'b']);
    expect(events.where((e) => e == 'play').length, 2);
    await output.dispose();
  });

  test('unawaited stop then next line cannot pause the new count', () async {
    final events = <String>[];
    final voice = _Player(events, autoComplete: false);
    final output = JustAudioVoiceOutput.forTesting(
      voice: voice,
      chime: _Player(events),
      keepAlive: _Player(events),
      session: () async => _Session(events),
    );
    await output.begin();
    final firstStarted = Completer<void>();
    voice.playingStarted.add(firstStarted);
    final first = output.speak(['coach']);
    await firstStarted.future;
    final stopping = output.stopSpeech(); // VoiceQueue does not await this.
    final nextStarted = Completer<void>();
    voice.playingStarted.add(nextStarted);
    final next = output.speak(['n.3']);
    await nextStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(voice.playing, isTrue);
    expect(voice.processingState, ProcessingState.ready);
    voice.complete();
    await Future.wait([first, stopping, next]);
    expect(events.where((e) => e == 'play').length, 2);
    await output.dispose();
  });

  test(
    'stop while initialization is pending cancels the waiting line',
    () async {
      final events = <String>[];
      final session = Completer<AudioSession>();
      final player = _Player(events);
      final output = JustAudioVoiceOutput.forTesting(
        voice: player,
        chime: player,
        keepAlive: player,
        session: () => session.future,
      );
      final beginning = output.begin();
      final speech = output.speak(['stale']);
      await Future<void>.delayed(Duration.zero);
      await output.stopSpeech();
      session.complete(_Session(events));
      await Future.wait([beginning, speech]);
      expect(events, isNot(contains('play')));
      expect(events, isNot(contains('active:true')));
      await output.dispose();
    },
  );

  test(
    'coaching session starts on media volume, independent of alert mute',
    () async {
      final events = <String>[];
      final session = _Session(events);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player(events),
        chime: _Player(events),
        keepAlive: _Player(events),
        session: () async => session,
      );
      addTearDown(output.dispose);
      await output.begin();
      expect(session.configurations, hasLength(1));
      expect(
        session.configurations.single.androidAudioAttributes?.usage,
        AndroidAudioUsage.media,
        reason:
            'Training and settings preview are spoken media. Muting ring/'
            'system sounds must not route this audio to the alert stream.',
      );
      expect(
        session.configurations.single.androidAudioAttributes?.contentType,
        AndroidAudioContentType.speech,
      );
    },
  );

  test(
    'ducking, reactivate and end retain media routing and iOS policy',
    () async {
      final events = <String>[];
      final session = _Session(events);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player(events),
        chime: _Player(events),
        keepAlive: _Player(events),
        session: () async => session,
      );
      addTearDown(output.dispose);
      await output.begin();
      await output.speak(['assets/voice/zh/p.welcome.m4a']);
      await output.reactivate();
      await output.end();
      expect(session.configurations, hasLength(4));
      expect(
        session.configurations.map((c) => c.avAudioSessionCategoryOptions),
        [
          AVAudioSessionCategoryOptions.mixWithOthers,
          AVAudioSessionCategoryOptions.duckOthers |
              AVAudioSessionCategoryOptions
                  .interruptSpokenAudioAndMixWithOthers,
          AVAudioSessionCategoryOptions.mixWithOthers,
          AVAudioSessionCategoryOptions.mixWithOthers,
        ],
        reason:
            'Only Android routing changes; iOS playback/mixing stays intact.',
      );
      for (final config in session.configurations) {
        expect(config.androidAudioAttributes?.usage, AndroidAudioUsage.media);
        expect(
          config.androidAudioAttributes?.contentType,
          AndroidAudioContentType.speech,
        );
        expect(
          config.androidAudioFocusGainType,
          AndroidAudioFocusGainType.gainTransientMayDuck,
        );
        expect(config.androidWillPauseWhenDucked, isFalse);
        expect(config.avAudioSessionCategory, AVAudioSessionCategory.playback);
        expect(config.avAudioSessionMode, AVAudioSessionMode.defaultMode);
      }
      expect(events, ['active:true', 'play', 'active:false']);
    },
  );
  group('Android continuous silent playback', () {
    test('begin and long speech gaps keep the loop active without '
        'holding music focus; session end stops it', () async {
      final focus = <String>[];
      final loop = _LoopPlayer([]);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player(focus),
        chime: _Player([]),
        keepAlive: loop,
        session: () async => _Session(focus),
        iOS: false,
      );
      output.volume = .25;
      await output.begin();
      expect(loop.assets, [JustAudioVoiceOutput.defaultKeepAliveAsset]);
      expect(loop.mode, LoopMode.one);
      expect(
        loop.volumes,
        [1],
        reason: 'silent samples must remain active, not client-volume-muted',
      );
      expect(loop.playing, isTrue);
      expect(
        focus,
        isEmpty,
        reason: 'silent playback must not duck other apps',
      );
      await output.speak(['welcome']);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(focus, ['active:true', 'play', 'active:false']);
      expect(
        loop.playing,
        isTrue,
        reason: 'the voice track ended, the loop did not',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        loop.playing,
        isTrue,
        reason: 'a long hold must not look audio-inactive',
      );
      await output.stopSpeech();
      expect(
        loop.playing,
        isTrue,
        reason: 'cancelling a line does not end the training',
      );
      await output.end();
      expect(loop.playing, isFalse);
      expect(loop.stops, 1);
      await output.dispose();
    });

    test('call and unplug pause the loop, while reactivation restarts '
        'only silent playback and keeps focus with other apps', () async {
      final focus = <String>[];
      final interrupts = StreamController<AudioInterruptionEvent>.broadcast(
        sync: true,
      );
      final noisy = StreamController<void>.broadcast(sync: true);
      final loop = _LoopPlayer([]);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player(focus),
        chime: _Player([]),
        keepAlive: loop,
        iOS: false,
        session: () async => _Session(
          focus,
          noisy: noisy.stream,
          interruptions: interrupts.stream,
        ),
      );
      final events = <AudioInterruption>[];
      final subscription = output.interruptions.listen(events.add);
      await output.begin();
      interrupts.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await Future<void>.delayed(Duration.zero);
      expect(loop.playing, isFalse);
      expect(events, [AudioInterruption.began]);
      await output.keepAliveResume();
      expect(
        loop.playing,
        isFalse,
        reason: 'duck release cannot undo a call pause',
      );
      final focusCount = focus.length;
      interrupts.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      expect(loop.playing, isTrue);
      expect(events, [AudioInterruption.began, AudioInterruption.ended]);
      expect(
        focus.length,
        focusCount,
        reason: 'a call ending cannot steal music focus',
      );
      noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(loop.playing, isFalse);
      expect(events.last, AudioInterruption.unplugged);
      await output.reactivate();
      expect(loop.playing, isTrue);
      expect(focus.length, focusCount);
      expect(loop.volumes, everyElement(1));
      await output.end();
      await output.reactivate();
      expect(loop.playing, isFalse, reason: 'an ended owner cannot reactivate');
      await subscription.cancel();
      await output.dispose();
      await interrupts.close();
      await noisy.close();
    });

    test('ending during silent load cannot start stale playback; a '
        'new session reapplies loop mode and volume', () async {
      final gate = Completer<void>();
      final loop = _LoopPlayer([], loading: gate);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player([]),
        chime: _Player([]),
        keepAlive: loop,
        session: () async => _Session([]),
        iOS: false,
      );
      final beginning = output.begin();
      await Future<void>.delayed(Duration.zero);
      expect(loop.assets, hasLength(1));
      final ending = output.end();
      gate.complete();
      await Future.wait([beginning, ending]);
      expect(loop.playing, isFalse);
      expect(loop.events, isEmpty);
      await output.begin();
      expect(loop.mode, LoopMode.one);
      expect(loop.volumes.last, 1);
      expect(loop.playing, isTrue);
      expect(
        loop.assets,
        hasLength(1),
        reason: 'stop retains the already loaded source',
      );
      await output.dispose();
      expect(loop.playing, isFalse);
    });

    testWidgets('the two-hour safety cap does not renew on reactivation', (
      tester,
    ) async {
      final loop = _LoopPlayer([]);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player([]),
        chime: _Player([]),
        keepAlive: loop,
        session: () async => _Session([]),
        iOS: false,
      );
      final beginning = output.begin();
      await tester.pump();
      await beginning;
      await tester.pump(const Duration(hours: 1));
      final reactivating = output.reactivate();
      await tester.pump();
      await reactivating;
      expect(loop.playing, isTrue);
      await tester.pump(const Duration(hours: 1, milliseconds: 1));
      expect(loop.playing, isFalse);
      final expiredReactivation = output.reactivate();
      await tester.pump();
      await expiredReactivation;
      expect(
        loop.playing,
        isFalse,
        reason: 'the expired owner cannot bypass its cap',
      );
      await output.keepAliveResume();
      expect(
        loop.playing,
        isFalse,
        reason: 'duck release also respects the cap',
      );
      final ending = output.end();
      await tester.pump();
      await ending;
      final restarting = output.begin();
      await tester.pump();
      await restarting;
      expect(loop.playing, isTrue, reason: 'a fresh session owns a fresh cap');
      await tester.runAsync(output.dispose);
    });
  });

  test(
    'iOS silent keep-alive retains zero volume through reactivation',
    () async {
      final loop = _LoopPlayer([]);
      final output = JustAudioVoiceOutput.forTesting(
        voice: _Player([]),
        chime: _Player([]),
        keepAlive: loop,
        session: () async => _Session([]),
        iOS: true,
      );
      output.volume = .25;
      await output.begin();
      expect(loop.playing, isTrue);
      expect(loop.volumes, [0]);
      await output.reactivate();
      expect(loop.volumes, [0, 0]);
      await output.dispose();
      expect(loop.playing, isFalse);
    },
  );
}
