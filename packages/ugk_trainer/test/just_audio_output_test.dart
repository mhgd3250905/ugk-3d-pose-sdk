// Ported from HipLab@99fcc83 test/hip/just_audio_output_test.dart. Unchanged
// except the import.
import 'dart:async';

import 'package:audio_session/audio_session.dart';
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
  _Session(this.events, {this.noisy = const Stream.empty()});
  final List<String> events;
  final Stream<void> noisy;
  final configurations = <AudioSessionConfiguration>[];
  @override
  Stream<void> get becomingNoisyEventStream => noisy;
  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      const Stream.empty();
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

void main() {
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
}
