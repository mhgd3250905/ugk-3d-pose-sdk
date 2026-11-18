import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _downloading = PoseHubDisplayUpdateProgress(
  phase: PoseHubDisplayUpdatePhase.downloading,
  version: 'r2-v18',
  totalFiles: 50,
  completedFiles: 25,
  totalBytes: 4 * 1024 * 1024,
  receivedBytes: 2 * 1024 * 1024,
);

const _provisional = PoseHubDisplayUpdateProgress(
  phase: PoseHubDisplayUpdatePhase.downloading,
  version: 'r2-v18',
  totalFiles: 2,
  completedFiles: 0,
  totalBytes: 1024,
  receivedBytes: 0,
  totalsKnown: false,
);

const _failed = PoseHubDisplayUpdateProgress(
  phase: PoseHubDisplayUpdatePhase.failed,
  version: 'r2-v18',
  totalFiles: 50,
  completedFiles: 25,
  totalBytes: 4 * 1024 * 1024,
  receivedBytes: 2 * 1024 * 1024,
  error: 'offline',
);

const _completed = PoseHubDisplayUpdateProgress(
  phase: PoseHubDisplayUpdatePhase.completed,
  version: 'r2-v18',
  totalFiles: 50,
  completedFiles: 50,
  totalBytes: 4 * 1024 * 1024,
  receivedBytes: 4 * 1024 * 1024,
);

Widget _app(
  Stream<PoseHubDisplayUpdateProgress> stream, {
  Future<void> Function()? onRetry,
  ThemeData? theme,
  bool mountedHost = true,
}) {
  final appTheme = theme ?? ThemeData.light();
  return MaterialApp(
    theme: appTheme,
    home: mountedHost
        ? CoachUiTheme(
            style: CoachUiStyle.fromTheme(appTheme),
            child: PoseHubDisplayUpdateDialogHost(
              progress: stream,
              onRetry: onRetry ?? () async {},
              child: const Scaffold(body: Text('Current catalog')),
            ),
          )
        : const Scaffold(body: Text('Current catalog')),
  );
}

final _dialog = find.byType(PoseHubDisplayUpdateDialog);
final _bar = find.byType(LinearProgressIndicator);
final _close = find.byTooltip('Close');

void main() {
  testWidgets('no advertised download leaves the current catalog usable', (
    tester,
  ) async {
    final updates = StreamController<PoseHubDisplayUpdateProgress>.broadcast();
    addTearDown(updates.close);
    await tester.pumpWidget(_app(updates.stream));
    expect(_dialog, findsNothing);
    expect(find.text('Current catalog').hitTestable(), findsOneWidget);

    updates.add(_completed);
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(find.text('Current catalog').hitTestable(), findsOneWidget);
  });

  testWidgets('shows exact progress once known and closes on activation', (
    tester,
  ) async {
    final updates = StreamController<PoseHubDisplayUpdateProgress>.broadcast();
    addTearDown(updates.close);
    await tester.pumpWidget(_app(updates.stream));

    updates.add(_provisional);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(_dialog, findsOneWidget);
    expect(find.text('r2-v18'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(_bar).value, isNull);
    expect(find.textContaining('KB'), findsNothing);
    expect(find.textContaining('files'), findsNothing);

    updates.add(_downloading);
    await tester.pumpAndSettle();
    expect(find.text('2.0 MB / 4.0 MB'), findsOneWidget);
    expect(find.text('25/50 files'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(_bar).value, .5);

    updates.add(_completed);
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(find.text('Current catalog').hitTestable(), findsOneWidget);
  });

  testWidgets('failure allows one pending retry in a narrow dark dialog', (
    tester,
  ) async {
    final updates = StreamController<PoseHubDisplayUpdateProgress>.broadcast();
    addTearDown(updates.close);
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final theme = ThemeData.dark();
    final retry = Completer<void>();
    var retryCount = 0;
    await tester.pumpWidget(
      _app(
        updates.stream,
        theme: theme,
        onRetry: () async {
          retryCount++;
          await retry.future;
        },
      ),
    );

    updates.add(_downloading);
    await tester.pumpAndSettle();
    expect(
      tester.widget<LinearProgressIndicator>(_bar).color,
      theme.colorScheme.primary,
    );
    updates.add(_failed);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('current assets are still available'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    final button = find.widgetWithText(FilledButton, 'Retry');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(retryCount, 1);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    updates.add(_downloading);
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    expect(_dialog, findsOneWidget);
    retry.complete();

    updates.add(_completed);
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
  });

  testWidgets(
    'dismissing a download does not reopen it for each progress event',
    (tester) async {
      final updates =
          StreamController<PoseHubDisplayUpdateProgress>.broadcast();
      addTearDown(updates.close);
      await tester.pumpWidget(_app(updates.stream));

      updates.add(_downloading);
      await tester.pumpAndSettle();
      await tester.tap(_close);
      await tester.pumpAndSettle();
      updates.add(_failed);
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(find.text('Current catalog').hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'removing the host closes its route and cancels the subscription',
    (tester) async {
      final updates =
          StreamController<PoseHubDisplayUpdateProgress>.broadcast();
      addTearDown(updates.close);
      await tester.pumpWidget(_app(updates.stream));

      updates.add(_downloading);
      await tester.pumpAndSettle();
      expect(_dialog, findsOneWidget);
      expect(updates.hasListener, isTrue);

      await tester.pumpWidget(_app(updates.stream, mountedHost: false));
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);
      expect(updates.hasListener, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
