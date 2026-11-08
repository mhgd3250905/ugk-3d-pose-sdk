import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void _ready(DrillMediaController controller) {
  controller.receive({'source': 'drill-media', 'type': 'ready'});
  controller.receive({'source': 'drill-media', 'type': 'first-frame'});
}

void _returned(
  DrillMediaController controller,
  Object? requestId,
  bool success,
) {
  controller.receive({
    'source': 'drill-media',
    'type': 'returned-to-start',
    'requestId': requestId,
    'success': success,
  });
}

class _Platform extends PackedAlphaPlatform {
  final eventsController = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );
  final commands = <(int, String, Object?)>[];
  final returns = <Completer<Object?>>[];
  int creates = 0;
  bool delayReturn = false;
  bool returnThrows = false;
  Object? returnResult = true;

  @override
  bool get isSupported => true;
  @override
  Stream<Map<Object?, Object?>> get events => eventsController.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) async {
    final id = ++creates;
    return (playerId: id, textureId: id + 100);
  }

  void emit(int id, String type) =>
      eventsController.add({'playerId': id, 'type': type});

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) async {
    commands.add((playerId, type, value));
    if (type != 'return-to-start') return null;
    if (returnThrows) throw StateError('Native return unavailable');
    if (delayReturn) {
      final pending = Completer<Object?>();
      returns.add(pending);
      return pending.future;
    }
    return returnResult;
  }
}

Widget _video(DrillMediaController controller) => MaterialApp(
  home: SizedBox.square(
    dimension: 200,
    child: UgkPackedAlphaVideo(asset: 'packed.mp4', controller: controller),
  ),
);

Future<void> _mountReady(
  WidgetTester tester,
  _Platform platform,
  DrillMediaController controller,
) async {
  await tester.pumpWidget(_video(controller));
  await tester.pump();
  platform.emit(platform.creates, 'ready');
  platform.emit(platform.creates, 'first-frame');
  await tester.pump();
  await tester.pump();
  expect(controller.ready, isTrue);
  expect(controller.hasFrame, isTrue);
}

void main() {
  test(
    'an unbound playback control cannot return an unavailable decoder',
    () async {
      final control = DrillMediaPlaybackControl();
      expect(await control.returnToStart(), isFalse);
      control.dispose();
      expect(await control.returnToStart(), isFalse);
    },
  );

  test(
    'a bound control without a ready decoded frame sends no return command',
    () async {
      final commands = <Map<String, Object?>>[];
      final controller = DrillMediaController()..attach(commands.add);
      final control = DrillMediaPlaybackControl();
      control.bind(owner: control, controller: controller);
      expect(await control.returnToStart(), isFalse);
      controller.receive({'source': 'drill-media', 'type': 'ready'});
      commands.clear();
      expect(await control.returnToStart(), isFalse);
      expect(commands, isEmpty);
      control.dispose();
      controller.dispose();
    },
  );

  test(
    'return sends its duration and only its matching native result completes it',
    () async {
      final commands = <Map<String, Object?>>[];
      final controller = DrillMediaController()..attach(commands.add);
      _ready(controller);
      commands.clear();
      final pending = controller.returnToStart(
        duration: const Duration(milliseconds: 650),
      );
      final command = commands.single;
      expect(command['type'], 'return-to-start');
      expect(command['durationMs'], 650);
      expect(command['requestId'], isA<int>());
      _returned(controller, command['requestId'], true);
      expect(await pending, isTrue);
      expect(controller.failed, isFalse);
      controller.dispose();
    },
  );

  test(
    'concurrent returns share one bounded request rather than restarting it',
    () async {
      final commands = <Map<String, Object?>>[];
      final controller = DrillMediaController()..attach(commands.add);
      _ready(controller);
      commands.clear();
      final first = controller.returnToStart();
      final second = controller.returnToStart(
        duration: const Duration(milliseconds: 200),
      );
      expect(second, same(first));
      expect(commands, hasLength(1));
      expect(commands.single['durationMs'], 400);
      _returned(controller, commands.single['requestId'], true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      controller.dispose();
    },
  );

  testWidgets('a retired request reply cannot finish a later return', (
    tester,
  ) async {
    final commands = <Map<String, Object?>>[];
    final controller = DrillMediaController()..attach(commands.add);
    _ready(controller);
    commands.clear();
    final old = controller.returnToStart();
    final oldRequest = commands.last['requestId'];
    controller.cancelReturnToStart();
    expect(await old, isFalse);
    final current = controller.returnToStart();
    final currentRequest = commands.last['requestId'];
    expect(currentRequest, isNot(oldRequest));
    var completed = false;
    unawaited(current.then((_) => completed = true));
    _returned(controller, oldRequest, true);
    await tester.pump();
    expect(completed, isFalse);
    _returned(controller, currentRequest, true);
    expect(await current, isTrue);
    controller.dispose();
  });

  testWidgets(
    'a missing return acknowledgement times out and cancels the native job',
    (tester) async {
      final commands = <Map<String, Object?>>[];
      final controller = DrillMediaController()..attach(commands.add);
      _ready(controller);
      commands.clear();
      final pending = controller.returnToStart();
      await tester.pump(const Duration(milliseconds: 1401));
      expect(await pending, isFalse);
      expect(
        commands.where((c) => c['type'] == 'cancel-return-to-start'),
        hasLength(1),
      );
      expect(controller.failed, isFalse);
      expect(controller.hasFrame, isTrue);
      controller.dispose();
    },
  );

  for (final reason in [
    'pause',
    'inactive',
    'detach',
    'dispose',
    'decoder-error',
  ]) {
    test('a $reason cancels a pending return immediately', () async {
      final commands = <Map<String, Object?>>[];
      final controller = DrillMediaController();
      final MediaCommandSink sink = commands.add;
      controller.attach(sink);
      _ready(controller);
      final pending = controller.returnToStart();
      switch (reason) {
        case 'pause':
          controller.pause();
        case 'inactive':
          controller.setActive(false);
        case 'detach':
          controller.detach(sink);
        case 'dispose':
          controller.dispose();
        case 'decoder-error':
          controller.reportError();
      }
      expect(await pending, isFalse);
      if (reason != 'dispose') controller.dispose();
    });
  }

  test(
    'replacing a control binding cancels the previous decoder and ignores its old owner',
    () async {
      final firstCommands = <Map<String, Object?>>[];
      final secondCommands = <Map<String, Object?>>[];
      final first = DrillMediaController()..attach(firstCommands.add);
      final second = DrillMediaController()..attach(secondCommands.add);
      _ready(first);
      _ready(second);
      firstCommands.clear();
      secondCommands.clear();
      final control = DrillMediaPlaybackControl();
      final oldOwner = Object();
      final currentOwner = Object();
      control.bind(owner: oldOwner, controller: first);
      final retired = control.returnToStart();
      control.bind(owner: currentOwner, controller: second);
      expect(await retired, isFalse);
      control.unbind(oldOwner);
      final current = control.returnToStart();
      expect(secondCommands.single['type'], 'return-to-start');
      _returned(second, secondCommands.single['requestId'], true);
      expect(await current, isTrue);
      control.unbind(currentOwner);
      expect(await control.returnToStart(), isFalse);
      control.dispose();
      first.dispose();
      second.dispose();
    },
  );

  group('packed surface return bridge', () {
    late _Platform platform;
    setUp(() {
      platform = _Platform();
      UgkPackedAlphaVideo.debugPlatform = platform;
      UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
    });
    tearDown(() async {
      UgkPackedAlphaVideo.debugPlatform = null;
      UgkPackedAlphaVideo.debugFilterBuilder = null;
      await platform.eventsController.close();
    });

    testWidgets(
      'native bool success acknowledges the requested return duration',
      (tester) async {
        final controller = DrillMediaController();
        await _mountReady(tester, platform, controller);
        final returned = controller.returnToStart(
          duration: const Duration(milliseconds: 600),
        );
        await tester.pump();
        await tester.pump();
        expect(await returned, isTrue);
        expect(
          platform.commands.where((c) => c.$2 == 'return-to-start').single,
          (1, 'return-to-start', 600),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );

    testWidgets('native false leaves the existing decoded frame healthy', (
      tester,
    ) async {
      platform.returnResult = false;
      final controller = DrillMediaController();
      await _mountReady(tester, platform, controller);
      expect(await controller.returnToStart(), isFalse);
      expect(controller.failed, isFalse);
      expect(controller.hasFrame, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets(
      'native return errors do not retire otherwise healthy playback',
      (tester) async {
        platform.returnThrows = true;
        final controller = DrillMediaController();
        await _mountReady(tester, platform, controller);
        expect(await controller.returnToStart(), isFalse);
        expect(controller.failed, isFalse);
        expect(controller.hasFrame, isTrue);
        expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );

    testWidgets(
      'a late native reply from a replaced surface cannot finish the new decoder return',
      (tester) async {
        platform.delayReturn = true;
        final first = DrillMediaController();
        final second = DrillMediaController();
        await _mountReady(tester, platform, first);
        final retired = first.returnToStart();
        expect(platform.returns, hasLength(1));
        await _mountReady(tester, platform, second);
        expect(await retired, isFalse);
        final current = second.returnToStart();
        expect(platform.returns, hasLength(2));
        var currentCompleted = false;
        unawaited(current.then((_) => currentCompleted = true));
        platform.returns.first.complete(true);
        await tester.pump();
        expect(currentCompleted, isFalse);
        expect(second.failed, isFalse);
        platform.returns.last.complete(true);
        await tester.pump();
        await tester.pump();
        expect(await current, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        first.dispose();
        second.dispose();
      },
    );
  });
}
