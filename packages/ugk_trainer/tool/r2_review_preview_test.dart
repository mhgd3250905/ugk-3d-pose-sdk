import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';
import '../test/support.dart';

void main() {
  testWidgets('r2 trainer local review screenshots', (tester) async {
    await (FontLoader('ReviewCjk')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\msyh.ttc').readAsBytesSync())))).load();
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File(r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf').readAsBytesSync())))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'))).load();
    final out = Directory('../../.review-artifacts/smartfit-r2')..createSync(recursive: true);
    final catalog = PoseHubAppTestCatalog.fromBytes(File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync());
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    for (final dark in [false, true]) {
      final trainerTheme = (dark ? TrainerTheme.dark : TrainerTheme.light).copyWith(fontFamily:'ReviewCjk');
      await tester.pumpWidget(MaterialApp(theme:ThemeData(brightness: dark ? Brightness.dark : Brightness.light, fontFamily:'ReviewCjk'), home: RepaintBoundary(key:key, child: TrainerPlayer(plan:planOf([timed('h-squat', 60)]), rhythms:const {}, drillOf:(id)=>TrainerDrill(id:id,name:'深蹲',cue:'保持呼吸平稳'), strings:TrainerStrings.zh(), theme:trainerTheme, keepAlive:false, prepSeconds:0, poseHubCatalog:catalog, onFinished:(_) async {}))));
      await tester.runAsync(() async {for (final element in find.byType(Image).evaluate()) {await precacheImage((element.widget as Image).image, element);}});
      for (var i=0; i<10; i++) {await tester.pump(const Duration(milliseconds: 100));}
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio:2);
        final data = await img.toByteData(format:ui.ImageByteFormat.png);
        File('${out.path}/trainer-${dark ? 'dark' : 'light'}.png').writeAsBytesSync(data!.buffer.asUint8List());
        img.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
