import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_media_download_indicator.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  for (final theme in [TrainerTheme.light, TrainerTheme.dark]) {
    testWidgets(
      'iOS HUD download, retry and first-frame completion ${theme.brightness}',
      (tester) async {
        final state = ValueNotifier(
          const CatalogMediaDownloadState(
            phase: CatalogMediaDownloadPhase.downloading,
            receivedBytes: 25,
            totalBytes: 100,
          ),
        );
        final handle = DrillMediaPlaybackHandle();
        final decoder = DrillMediaController();
        var retries = 0;
        handle.bind(owner: decoder, mediaId: 'demo', controller: decoder);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrainerMediaDownloadIndicator(
                state: state,
                actionId: 'demo',
                theme: theme,
                strings: TrainerStrings.zh(),
                playbackHandle: handle,
                onRetry: () {
                  retries++;
                },
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.byKey(const ValueKey('media-download-progress')),
          findsOneWidget,
        );
        state.value = const CatalogMediaDownloadState(
          phase: CatalogMediaDownloadPhase.failed,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('media-download-retry')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('media-download-retry')));
        expect(retries, 1);
        state.value = const CatalogMediaDownloadState(
          phase: CatalogMediaDownloadPhase.ready,
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('media-download-ready')),
          findsNothing,
        );
        decoder.receive({'source': 'drill-media', 'type': 'first-frame'});
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('media-download-ready')),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 201));
        expect(
          find.byKey(const ValueKey('media-download-indicator')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        decoder.dispose();
        handle.dispose();
        state.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
