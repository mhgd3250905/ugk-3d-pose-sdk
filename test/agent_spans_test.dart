import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_spans.dart';

void main() {
  test('completed operations carry exact monotonic time and provenance', () {
    var now = 100;
    final spans = <CoachAgentSpan>[];
    final recorder = CoachAgentSpanRecorder(
      onSpan: spans.add,
      elapsedMicros: () => now,
    );
    final operation = recorder.start(
      CoachAgentSpanKind.http,
      'model_attempt',
      turnId: 'turn-2',
      taskId: 'recommend-1',
      epoch: 3,
      toolCallId: 'call-1',
      httpOrdinal: 4,
      attributes: const {'attempt': 1},
    );
    expect(spans, isEmpty);
    now = 640;
    final span = operation.finish(
      ok: false,
      reason: 'transport_failed',
      attributes: const {'httpStatus': 503},
    )!;
    expect(spans.single, same(span));
    expect(span.startedMicros, 100);
    expect(span.elapsedMicros, 540);
    expect(span.toJson(), {
      'schemaVersion': 1,
      'spanId': 1,
      'kind': 'http',
      'name': 'model_attempt',
      'startedMicros': 100,
      'elapsedMicros': 540,
      'ok': false,
      'reason': 'transport_failed',
      'turnId': 'turn-2',
      'taskId': 'recommend-1',
      'epoch': 3,
      'toolCallId': 'call-1',
      'httpOrdinal': 4,
      'attributes': {'attempt': 1, 'httpStatus': 503},
    });
  });

  test('nested spans keep independent durations and explicit parent IDs', () {
    var now = 10;
    final spans = <CoachAgentSpan>[];
    final recorder = CoachAgentSpanRecorder(
      onSpan: spans.add,
      elapsedMicros: () => now,
    );
    final tool = recorder.start(CoachAgentSpanKind.tool, 'draft_plan');
    now = 30;
    final fit = recorder.start(
      CoachAgentSpanKind.fit,
      'duration_fit',
      parentId: tool.id,
    );
    now = 50;
    fit.finish();
    now = 90;
    tool.finish();
    expect(spans.map((span) => span.elapsedMicros), [20, 80]);
    expect(spans.first.parentId, tool.id);
    expect(spans.last.parentId, isNull);
  });

  test('repeated finish emits once and preserves the first outcome', () {
    var now = 0;
    final spans = <CoachAgentSpan>[];
    final recorder = CoachAgentSpanRecorder(
      onSpan: spans.add,
      elapsedMicros: () => now,
    );
    final handle = recorder.start(
      CoachAgentSpanKind.recompile,
      'draft_rejected',
    );
    now = 6;
    final first = handle.finish(ok: false, reason: 'scope_rejected');
    now = 11;
    expect(handle.finish(ok: true), same(first));
    expect(spans.single.elapsedMicros, 6);
    expect(spans.single.reason, 'scope_rejected');
    expect(spans.single.ok, isFalse);
  });

  test('diagnostics callback failure never changes operation control flow', () {
    final recorder = CoachAgentSpanRecorder(
      onSpan: (_) => throw StateError('observer failure'),
    );
    expect(
      () => recorder.start(CoachAgentSpanKind.tool, 'check').finish(),
      returnsNormally,
    );
  });

  test('null observer performs no timing reads and emits nothing', () {
    final recorder = CoachAgentSpanRecorder(
      elapsedMicros: () => throw StateError('must not read clock'),
    );
    final handle = recorder.start(CoachAgentSpanKind.fit, 'fit');
    expect(handle.finish(), isNull);
    expect(handle.finish(), isNull);
  });

  test('attributes are snapshotted and cannot change after end', () {
    final input = <String, Object?>{
      'counts': <Object?>[1, 2],
    };
    final recorder = CoachAgentSpanRecorder(onSpan: (_) {});
    final handle = recorder.start(
      CoachAgentSpanKind.fit,
      'fit',
      attributes: input,
    );
    (input['counts']! as List<Object?>).add(3);
    final end = <String, Object?>{'outcome': 'ok'};
    final span = handle.finish(attributes: end)!;
    end['outcome'] = 'mutated';
    expect(span.attributes, {
      'counts': [1, 2],
      'outcome': 'ok',
    });
    expect(() => span.attributes['x'] = 1, throwsUnsupportedError);
    expect(
      () => (span.attributes['counts']! as List<Object?>).add(7),
      throwsUnsupportedError,
    );
    final json = span.toJson();
    (json['attributes']! as Map<String, Object?>)['outcome'] = 'client copy';
    expect(span.attributes['outcome'], 'ok');
  });

  test('unsupported and nonfinite attributes remain JSON-safe diagnostics', () {
    final span = CoachAgentSpanRecorder(onSpan: (_) {})
        .start(
          CoachAgentSpanKind.tool,
          'search_actions',
          attributes: {'callback': () {}, 'value': double.nan},
        )
        .finish()!;
    final restored =
        jsonDecode(jsonEncode(span.toJson())) as Map<String, dynamic>;
    expect(restored['attributes'], {'callback': null, 'value': null});
  });

  test(
    'lower-level spans inherit context across async work and nested zones',
    () async {
      final spans = <CoachAgentSpan>[];
      final recorder = CoachAgentSpanRecorder(onSpan: spans.add);
      expect(CoachAgentSpanRecorder.current, isNull);
      await recorder.run(
        () async {
          await Future<void>.value();
          final outer = CoachAgentSpanRecorder.startCurrent(
            CoachAgentSpanKind.tool,
            'draft_plan',
          )!;
          recorder.run(
            () => CoachAgentSpanRecorder.startCurrent(
              CoachAgentSpanKind.fit,
              'duration_fit',
            )!.finish(),
            toolCallId: 'call-8',
            parentId: outer.id,
          );
          outer.finish();
        },
        turnId: 'turn-3',
        taskId: 'plan',
        epoch: 7,
        httpOrdinal: 2,
      );
      final fit = spans.first;
      expect(fit.turnId, 'turn-3');
      expect(fit.taskId, 'plan');
      expect(fit.epoch, 7);
      expect(fit.httpOrdinal, 2);
      expect(fit.toolCallId, 'call-8');
      expect(fit.parentId, spans.last.id);
      expect(CoachAgentSpanRecorder.current, isNull);
      expect(CoachAgentSpanRecorder.currentContext.turnId, isNull);
    },
  );

  test('another Agent recorder cannot inherit the first Agent context', () {
    final first = CoachAgentSpanRecorder(onSpan: (_) {});
    final secondSpans = <CoachAgentSpan>[];
    final second = CoachAgentSpanRecorder(onSpan: secondSpans.add);
    first.run(
      () => second.run(
        () => CoachAgentSpanRecorder.startCurrent(
          CoachAgentSpanKind.http,
          'request',
        )!.finish(),
      ),
      turnId: 'private-agent-a',
      taskId: 'plan',
      epoch: 9,
    );
    expect(secondSpans.single.turnId, isNull);
    expect(secondSpans.single.taskId, isNull);
    expect(secondSpans.single.epoch, isNull);
  });

  test('a disabled nested Agent masks an observed outer Agent zone', () {
    final observed = CoachAgentSpanRecorder(onSpan: (_) {});
    final disabled = CoachAgentSpanRecorder();
    observed.run(() {
      disabled.run(() {
        expect(CoachAgentSpanRecorder.current, isNull);
        expect(CoachAgentSpanRecorder.currentContext.turnId, isNull);
        expect(
          CoachAgentSpanRecorder.startCurrent(
            CoachAgentSpanKind.http,
            'request',
          ),
          isNull,
        );
      });
      expect(CoachAgentSpanRecorder.current, same(observed));
    }, turnId: 'observed-outer');
  });

  test(
    'failed work restores outer zone and disabled observations need no zone',
    () {
      final recorder = CoachAgentSpanRecorder(onSpan: (_) {});
      expect(
        () => recorder.run<void>(() => throw StateError('operation failed')),
        throwsStateError,
      );
      expect(CoachAgentSpanRecorder.current, isNull);
      CoachAgentSpanRecorder().run(() {
        expect(CoachAgentSpanRecorder.current, isNull);
        expect(
          CoachAgentSpanRecorder.startCurrent(CoachAgentSpanKind.fit, 'fit'),
          isNull,
        );
      });
    },
  );
}
