import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';
import 'package:ugk_coach_chat/src/ui/training_visible_poster_preload.dart';

class _PosterBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData(1);
}

void main() {
  testWidgets(
    'visible still warms the player poster with the original bundle',
    (tester) async {
      final parent = _PosterBundle();
      final warmed = <String>[];
      AssetBundle? warmedBundle;
      late AssetBundle observing;
      await tester.pumpWidget(
        MaterialApp(
          home: DefaultAssetBundle(
            bundle: parent,
            child: CoachChatTheme(
              visual: CoachChatVisuals(
                preloadPoster: (context, id) async {
                  warmed.add(id);
                  warmedBundle = DefaultAssetBundle.of(context);
                },
              ),
              child: TrainingVisiblePosterPreload(
                assetActionIds: const {'still.webp': 'action-one'},
                child: Builder(
                  builder: (context) {
                    observing = DefaultAssetBundle.of(context);
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await observing.load('still.webp');
        await observing.load('still.webp');
      });
      expect(warmed, ['action-one']);
      expect(identical(warmedBundle, parent), isTrue);
    },
  );
}
