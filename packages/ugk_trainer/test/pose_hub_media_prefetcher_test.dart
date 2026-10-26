import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _Host implements PoseHubMediaPreparer {
  final actions = <PoseHubPackAction>[];
  final streams = <StreamController<PoseHubMediaPreparationEvent>>[];
  int active = 0, maximum = 0;
  bool cached = false;
  Completer<void>? cancellationBlocker;

  @override
  Stream<PoseHubMediaPreparationEvent> prepareAction(PoseHubPackAction action) {
    actions.add(action);
    late StreamController<PoseHubMediaPreparationEvent> controller;
    controller = StreamController(
      sync: true,
      onListen: () {
        active++;
        if (active > maximum) {
          maximum = active;
        }
        if (cached) {
          controller.add(
            PoseHubMediaReady(mediaBaseUri: Uri.parse('file:///cache/')),
          );
        }
      },
      onCancel: () async {
        await cancellationBlocker?.future;
        active--;
      },
    );
    streams.add(controller);
    return controller.stream;
  }

  void ready(int index) => streams[index].add(
    PoseHubMediaReady(mediaBaseUri: Uri.parse('file:///cache/')),
  );
  void fail(int index) =>
      streams[index].add(const PoseHubMediaFailed(reason: 'offline'));
  void close() {
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync(),
  );
  final actions = catalog.semanticCompleteActions.take(5).toList();
  late _Host host;
  late PoseHubMediaPrefetcher queue;
  setUp(() {
    host = _Host();
    queue = PoseHubMediaPrefetcher(host);
  });
  tearDown(() {
    queue.dispose();
    host.close();
  });

  test(
    'prefetch follows plan order and never exceeds two active hosts',
    () async {
      queue.prioritize(actions);
      expect(host.actions, actions.take(2));
      host.ready(0);
      await Future<void>.delayed(Duration.zero);
      expect(host.actions, actions.take(3));
      host.ready(1);
      await Future<void>.delayed(Duration.zero);
      expect(host.actions, actions.take(4));
      expect(host.maximum, 2);
      queue.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'jump/rest priority preempts only the furthest speculative action',
    () async {
      queue.prioritize(actions);
      queue.prioritize([actions[3], actions[4]]);
      await Future<void>.delayed(Duration.zero);
      expect(host.actions, [actions[0], actions[1], actions[3]]);
      expect(host.active, 2);
      host.ready(1); // retired download: no subscriber and no cache promotion
      await Future<void>.delayed(Duration.zero);
      final received = <PoseHubMediaPreparationEvent>[];
      final subscription = queue.prepareAction(actions[1]).listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<PoseHubMediaReady>(), isEmpty);
      expect(host.maximum, 2);
      await subscription.cancel();
      queue.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'current failure retries after backoff ahead of queued future actions',
    () async {
      queue.prioritize(actions);
      final received = <PoseHubMediaPreparationEvent>[];
      final subscription = queue
          .prepareAction(actions.first)
          .listen(received.add);
      await Future<void>.delayed(Duration.zero);
      host.fail(0);
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<PoseHubMediaFailed>(), isEmpty);
      expect(host.actions, actions.take(3));
      await Future<void>.delayed(const Duration(milliseconds: 1900));
      expect(host.actions, hasLength(3));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(host.actions.last, actions.first);
      expect(host.maximum, 2);
      host.ready(3);
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<PoseHubMediaReady>(), hasLength(1));
      await subscription.cancel();
      queue.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'cached synchronous host completion is delivered once and reused',
    () async {
      host.cached = true;
      final received = <PoseHubMediaPreparationEvent>[];
      queue.prepareAction(actions.first).listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<PoseHubMediaReady>(), hasLength(1));
      queue.prepareAction(actions.first).listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(received.whereType<PoseHubMediaReady>(), hasLength(2));
      expect(host.actions, [actions.first]);
      queue.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('dispose cancels downloads and pending retry timers', () async {
    queue.prioritize(actions);
    host.fail(0);
    queue.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(host.active, 0);
    final count = host.actions.length;
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(host.actions, hasLength(count));
  });
  test(
    'preemption waits for asynchronous cancellation before using the slot',
    () async {
      queue.prioritize(actions);
      final blocker = Completer<void>();
      host.cancellationBlocker = blocker;
      queue.prioritize([actions[3], actions[4]]);
      await Future<void>.delayed(Duration.zero);
      expect(host.actions, actions.take(2));
      expect(host.maximum, 2);
      blocker.complete();
      await Future<void>.delayed(Duration.zero);
      expect(host.actions.last, actions[3]);
      expect(host.maximum, 2);
      queue.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  testWidgets(
    'player reuses same-host queue across callback rebuilds and waits when provider changes',
    (tester) async {
      final replacement = _Host();
      final blocker = Completer<void>();
      final plan = planOf([timed(actions[0].id, 30), timed(actions[1].id, 30)]);
      Widget player(PoseHubMediaPreparer provider) => MaterialApp(
        home: TrainerPlayer(
          plan: plan,
          drillOf: (id) => TrainerDrill(id: id, name: id),
          strings: TrainerStrings.zh(),
          onFinished: (_) async {},
          prepSeconds: 0,
          keepAlive: false,
          poseHubActionOf: catalog.tryGet,
          poseHubMediaPreparer: provider,
          poseHubMediaBaseUri: Uri.parse('file:///cache/'),
        ),
      );
      await tester.pumpWidget(player(host));
      await tester.pump();
      expect(host.actions, actions.take(2));
      await tester.pumpWidget(player(host));
      await tester.pump();
      expect(host.actions, hasLength(2));
      host.cancellationBlocker = blocker;
      await tester.pumpWidget(player(replacement));
      await tester.pump();
      expect(replacement.actions, isEmpty);
      await tester.runAsync(() async {
        blocker.complete();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(replacement.actions, actions.take(2));
      expect(host.active + replacement.active, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      replacement.close();
    },
  );
}
