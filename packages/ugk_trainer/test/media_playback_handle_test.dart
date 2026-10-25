import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void ready(DrillMediaController controller) {
  controller.receive({'source': 'drill-media', 'type': 'ready'});
  controller.receive({'source': 'drill-media', 'type': 'first-frame'});
}

void main() {
  test(
    'inspection uses decoder time without changing playback or repainting',
    () async {
      final controller = DrillMediaController();
      final handle = DrillMediaPlaybackHandle();
      controller.toggle();
      controller.attach((command) {
        if (command['type'] == 'position') {
          controller.receive({
            'source': 'drill-media',
            'type': 'position',
            'requestId': command['requestId'],
            'time': 1.25,
          });
        }
      });
      ready(controller);
      var notifications = 0;
      controller.addListener(() => notifications++);
      handle.bind(owner: handle, mediaId: 'move-a', controller: controller);
      final value = await handle.capture();
      expect(value!.mediaId, 'move-a');
      expect(value.videoSeconds, 1.25);
      expect(value.ready, isTrue);
      expect(value.capturedAt.isUtc, isTrue);
      expect(controller.wantsPlay, isTrue);
      expect(notifications, 0);
      handle.dispose();
      controller.dispose();
    },
  );

  test(
    'a switch never pairs the old position with the new action id',
    () async {
      final old = DrillMediaController()..attach((_) {});
      ready(old);
      final handle = DrillMediaPlaybackHandle();
      final owner = Object();
      handle.bind(owner: owner, mediaId: 'move-a', controller: old);
      final inFlight = handle.capture();
      old.dispose();
      handle.bind(owner: owner, mediaId: 'move-b', controller: null);
      final value = await inFlight;
      expect(value!.mediaId, 'move-a');
      expect(value.videoSeconds, isNull);
      final waiting = await handle.capture();
      expect(waiting!.mediaId, 'move-b');
      expect(waiting.ready, isFalse);
      expect(waiting.videoSeconds, isNull);
      handle.dispose();
    },
  );

  test(
    'concurrent inspections share one query and stale replies are ignored',
    () async {
      final controller = DrillMediaController();
      Map<String, Object?>? query;
      var count = 0;
      controller.attach((command) {
        if (command['type'] == 'position') {
          query = command;
          count++;
        }
      });
      ready(controller);
      final first = controller.readPosition();
      final second = controller.readPosition();
      expect(count, 1);
      controller.receive({
        'source': 'drill-media',
        'type': 'position',
        'requestId': -1,
        'time': 88,
      });
      controller.receive({
        'source': 'drill-media',
        'type': 'position',
        'requestId': query!['requestId'],
        'time': 2.5,
      });
      expect(await first, 2.5);
      expect(await second, 2.5);
      controller.dispose();
    },
  );

  test('waiting and detached views report unknown rather than zero', () async {
    final handle = DrillMediaPlaybackHandle();
    final owner = Object();
    handle.bind(owner: owner, mediaId: 'move-a', controller: null);
    expect((await handle.capture())!.videoSeconds, isNull);
    handle.unbind(Object());
    expect((await handle.capture())!.mediaId, 'move-a');
    handle.unbind(owner);
    expect(await handle.capture(), isNull);
    handle.dispose();
  });
}
