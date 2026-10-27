import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

void main() {
  testWidgets('r2 local review screenshots', (tester) async {
    await (FontLoader('ReviewCjk')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\msyh.ttc').readAsBytesSync())))).load();
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File(r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf').readAsBytesSync())))).load();
    final out = Directory('../../.review-artifacts/smartfit-r2')..createSync(recursive: true);
    final ids = ['h-squat', 'chest-A', 'forearms-A', 'erectors-A', 'deltoids-A'];
    final names = ['深蹲', '胸部拉伸', '手腕放松', '背部放松', '肩部拉伸'];
    final images = <String, Uint8List>{for (final id in ids) id: File('../ugk_trainer/assets/pose_hub/app-test-pack-r1/standing/$id.webp').readAsBytesSync()};
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundaryKey = GlobalKey();
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${out.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final theme = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff008e78), brightness: brightness), fontFamily: 'ReviewCjk');
      final colors = CoachUiColors.fromTheme(theme);
      final stage = CoachMediaPalette(mediaStage: Colors.transparent, onStage: colors.text, onStageMuted: colors.muted);
      final library = CoachExerciseLibrary([for (var i=0; i<ids.length; i++) CoachExercise(id: ids[i], name: names[i], poster: 'poster/${ids[i]}', cutout: 'still/${ids[i]}', stillCutout: 'still/${ids[i]}', stage: stage)]);
      const plan = CoachRoutine(id: 'review', title: '办公室久坐拉伸', durationLabel: '8 分钟', gearLabel: '徒手', levelLabel: '入门', metaLabel: '8 分钟 · 5 个动作 · 徒手', items: [CoachRoutineItem(exerciseId:'h-squat', dose:'12 次'), CoachRoutineItem(exerciseId:'chest-A', dose:'45 秒'), CoachRoutineItem(exerciseId:'forearms-A', dose:'30 秒'), CoachRoutineItem(exerciseId:'erectors-A', dose:'45 秒'), CoachRoutineItem(exerciseId:'deltoids-A', dose:'30 秒')]);
      final style = CoachUiStyle(colors: colors, typography: CoachUiTypography.fromTheme(theme), strings: const CoachUiStrings(expand:'展开', collapse:'收起', expandDetails:'展开详情', collapseDetails:'收起详情', cancel:'取消'), builders: CoachUiBuilders(media: (_, request) {
        final image = Image.memory(images[request.exercise.id]!, fit: request.fit, alignment: request.alignment, gaplessPlayback: true);
        return request.asset.startsWith('poster/') ? ColoredBox(color: Colors.black, child: image) : image;
      }));
      final mode = brightness.name;
      await tester.pumpWidget(MaterialApp(theme:theme, home: Scaffold(body: RepaintBoundary(key:boundaryKey, child: ColoredBox(color:colors.background, child: Padding(padding:const EdgeInsets.fromLTRB(16,48,16,20), child: CoachUiTheme(style:style, child: Align(alignment:Alignment.topCenter, child: CoachPlanCard(plan:plan, library:library, saved:false, cutoutTopInset:0, onStart:(_){}, onSave:(){}, onOpen:(){})))))))));
      await tester.runAsync(() async {for (final bytes in images.values) {await precacheImage(MemoryImage(bytes), boundaryKey.currentContext!);}});
      await tester.pumpAndSettle();
      await capture('card-$mode-collapsed');
      await tester.tap(find.byKey(const ValueKey('plan-expand-review')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await capture('card-$mode-expanded');
      await tester.pumpWidget(MaterialApp(theme:theme, home: Scaffold(body: RepaintBoundary(key:boundaryKey, child: ColoredBox(color:colors.background, child: Padding(padding:const EdgeInsets.fromLTRB(16,90,16,0), child: CoachUiTheme(style:style, child: Align(alignment:Alignment.topLeft, child: CoachTypingBubble(progressLabel:'正在查动作库', onCancel:(){})))))))));
      await tester.pump(const Duration(milliseconds: 400));
      await capture('waiting-$mode');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
