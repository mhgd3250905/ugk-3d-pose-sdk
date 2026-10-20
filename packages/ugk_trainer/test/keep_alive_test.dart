// Ported from HipLab@99fcc83 test/hip/hip_training_keepalive_test.dart (the
// Dart half; the player-page case is covered by trainer_player_test.dart).
// PR #24 review F24-3 / F24-4 (docs/pr24-review-2026-10-19.md): the Android
// training keep-alive is owned per session. START / STOP carry a session id,
// a stale STOP is never sent for a session that was replaced, and the CPU
// wake-lock cap follows the planned length. The native side applies the same
// rule (TrainingSessionService.kt); these tests cover the Dart half.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    TrainingKeepAlive.isAndroid = () => true;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
    TrainingKeepAlive.isAndroid = () => true;
  });

  List<String> methods() => [for (final c in calls) c.method];
  Object? sessionOf(MethodCall c) => (c.arguments as Map?)?['session'];

  test('stop carries the session it ends; a stale stop after a quick '
      're-entry is not sent', () async {
    final a = TrainingHold.begin(const Duration(minutes: 10));
    a.release(); // page 1 closed …
    final b = TrainingHold.begin(const Duration(minutes: 10)); // … page 2
    a.release(); // dispose of page 1 again: idempotent
    await pumpEventQueue();
    expect(methods(), ['start', 'stop', 'start']);
    expect(sessionOf(calls[1]), sessionOf(calls[0]));
    expect(sessionOf(calls[2]), isNot(sessionOf(calls[0])));
    b.release();
    await pumpEventQueue();
    expect(methods(), ['start', 'stop', 'start', 'stop']);
    expect(sessionOf(calls[3]), sessionOf(calls[2]));
  });

  test('overlapping pages: the old page releasing does not stop the new '
      'session', () async {
    final a = TrainingHold.begin(const Duration(minutes: 10));
    final b = TrainingHold.begin(const Duration(minutes: 10));
    a.release();
    await pumpEventQueue();
    expect(methods(), ['start', 'start']);
    b.release();
    await pumpEventQueue();
    expect(methods(), ['start', 'start', 'stop']);
    expect(sessionOf(calls[2]), sessionOf(calls[1]));
  });

  test('the wake-lock cap follows the planned length', () async {
    final h = TrainingHold.begin(const Duration(minutes: 12));
    await pumpEventQueue();
    final cap = (calls.single.arguments as Map)['maxMs'] as int;
    expect(cap, greaterThan(const Duration(minutes: 12).inMilliseconds));
    expect(cap, lessThanOrEqualTo(const Duration(minutes: 30).inMilliseconds));
    h.release();
    final long = TrainingHold.begin(const Duration(hours: 5));
    await pumpEventQueue();
    expect(
      (calls.last.arguments as Map)['maxMs'],
      TrainingHold.maxCap.inMilliseconds,
    );
    long.release();
  });

  test('the screen hold alone no longer drives the service', () async {
    ScreenAwake.acquire();
    ScreenAwake.release();
    await pumpEventQueue();
    expect(calls, isEmpty);
  });

  test('not on iOS / web; a missing platform side never throws', () async {
    TrainingKeepAlive.isAndroid = () => false;
    TrainingHold.begin(const Duration(minutes: 5)).release();
    await pumpEventQueue();
    expect(calls, isEmpty);
    TrainingKeepAlive.isAndroid = () => true;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
    TrainingHold.begin(const Duration(minutes: 5)).release();
    await pumpEventQueue();
  });

  test('the notification texts ride along with start', () async {
    final h = TrainingHold.begin(
      const Duration(minutes: 5),
      notice: const TrainingNotice(
        channelName: 'c',
        channelDescription: 'd',
        title: 't',
        text: 'x',
        icon: 'mipmap/ic_launcher',
      ),
    );
    await pumpEventQueue();
    final args = calls.single.arguments as Map;
    expect(args['title'], 't');
    expect(args['channelName'], 'c');
    expect(args['icon'], 'mipmap/ic_launcher');
    h.renew(const Duration(minutes: 3));
    await pumpEventQueue();
    expect((calls.last.arguments as Map)['text'], 'x');
    h.release();
  });
}
