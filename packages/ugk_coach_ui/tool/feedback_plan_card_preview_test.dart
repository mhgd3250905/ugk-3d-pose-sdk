import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

void main() {
  // Optional local screenshot probe; fonts stay on the machine running it.
  final cjkFont = Platform.environment['COACH_PREVIEW_CJK_FONT'];
  final iconFont = Platform.environment['COACH_PREVIEW_ICON_FONT'];
  testWidgets('local Chinese alpha card feedback preview', (tester) async {
    final font = FontLoader('FeedbackChinese')
      ..addFont(
        Future.value(ByteData.sublistView(File(cjkFont!).readAsBytesSync())),
      );
    await font.load();
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(ByteData.sublistView(File(iconFont!).readAsBytesSync())),
        ))
        .load();
    final ids = [
      'h-squat',
      'chest-A',
      'forearms-A',
      'erectors-A',
      'deltoids-A',
      'abs-A',
      'h-calf-raise',
      'deltoids-B',
    ];
    final names = ['深蹲', '胸部拉伸', '手腕放松', '背部放松', '肩部拉伸', '核心练习', '提踵', '肩部放松'];
    final images = <String, Uint8List>{
      for (final id in ids)
        id: File(
          '../ugk_trainer/assets/pose_hub/app-test-pack-r1/standing/$id.webp',
        ).readAsBytesSync(),
    };
    final output = Directory('../../.review-artifacts/feedback-r1-part1/cards')
      ..createSync(recursive: true);
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final theme = ThemeData(fontFamily: 'FeedbackChinese');
    final colors = CoachUiColors.fromTheme(theme);
    final library = CoachExerciseLibrary([
      for (var i = 0; i < ids.length; i++)
        CoachExercise(
          id: ids[i],
          name: names[i],
          poster: ids[i],
          cutout: ids[i],
          stillCutout: ids[i],
          stage: colors.stage,
        ),
    ]);
    const plan = CoachRoutine(
      id: 'feedback',
      title: '办公室久坐拉伸',
      items: [
        CoachRoutineItem(exerciseId: 'h-squat', dose: '缓慢完成 12 次'),
        CoachRoutineItem(exerciseId: 'chest-A', dose: '保持 45 秒'),
        CoachRoutineItem(exerciseId: 'forearms-A', dose: '每侧 30 秒'),
        CoachRoutineItem(exerciseId: 'erectors-A', dose: '保持 45 秒'),
        CoachRoutineItem(exerciseId: 'deltoids-A', dose: '每侧 30 秒'),
        CoachRoutineItem(exerciseId: 'abs-A', dose: '保持 30 秒'),
        CoachRoutineItem(exerciseId: 'h-calf-raise', dose: '缓慢完成 12 次'),
        CoachRoutineItem(exerciseId: 'deltoids-B', dose: '每侧 30 秒'),
      ],
      durationLabel: '8 分钟',
      gearLabel: '徒手',
      levelLabel: '入门',
      metaLabel: '8 分钟 · 8 个动作 · 徒手',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor,
              child: SizedBox.expand(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 48, 16, 32),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: CoachUiTheme(
                      style: CoachUiStyle(
                        colors: colors,
                        typography: CoachUiTypography.fromTheme(theme),
                        strings: const CoachUiStrings(
                          expand: '展开',
                          collapse: '收起',
                          expandDetails: '展开详情',
                          collapseDetails: '收起详情',
                          save: '保存',
                          saved: '已保存',
                          start: '开始训练',
                        ),
                        builders: CoachUiBuilders(
                          media: (_, request) => Image.memory(
                            images[request.exercise.id]!,
                            fit: request.fit,
                            alignment: request.alignment,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CoachPlanCard(
                            plan: plan,
                            library: library,
                            saved: false,
                            cutoutTopInset: 0,
                            onStart: (_) {},
                            onSave: () {},
                            onOpen: () {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (final bytes in images.values) {
        await precacheImage(MemoryImage(bytes), key.currentContext!);
      }
    });
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${output.path}/$name.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('plan-card-collapsed');
    await tester.tap(find.byKey(const ValueKey('plan-expand-feedback')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await capture('plan-card-expanding-250ms');
    await tester.pumpAndSettle();
    await capture('plan-card-expanded');
    expect(tester.takeException(), isNull);
  }, skip: cjkFont == null || iconFont == null);
}
