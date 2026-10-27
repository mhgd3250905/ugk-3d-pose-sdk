import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
void main() {
 testWidgets('r2 local confirmation and failure screenshots', (tester) async {
  await (FontLoader('ReviewCjk')..addFont(Future.value(ByteData.sublistView(File(r'C:\Windows\Fonts\msyh.ttc').readAsBytesSync())))).load();
  await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File(r'E:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf').readAsBytesSync())))).load();
  final out = Directory('../../.review-artifacts/smartfit-r2')..createSync(recursive:true);
  tester.view.physicalSize = const Size(390, 844); tester.view.devicePixelRatio = 1; addTearDown(tester.view.reset);
  final key=GlobalKey();
  const fields=[CoachQuestionField(key:'scene',label:'场景',options:['办公室','家里','健身房'],initialSelections:['办公室'],previousSelections:['办公室']), CoachQuestionField(key:'equipment',label:'器械',options:['徒手','瑜伽垫','椅子','哑铃'],multiple:true,initialSelections:['徒手'],previousSelections:['徒手']), CoachQuestionField(key:'minutes',label:'时长',options:['5 分钟','10 分钟','15 分钟','20+ 分钟'],initialSelections:['10 分钟'],previousSelections:['10 分钟'])];
  Future<void> take(String name) async {await tester.runAsync(() async {final b=key.currentContext!.findRenderObject()! as RenderRepaintBoundary; final img=await b.toImage(pixelRatio:2); final data=await img.toByteData(format:ui.ImageByteFormat.png); File('${out.path}/$name.png').writeAsBytesSync(data!.buffer.asUint8List()); img.dispose();});}
  for(final brightness in [Brightness.light,Brightness.dark]) {
   final theme=ThemeData(colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xff008e78),brightness:brightness),fontFamily:'ReviewCjk');
   final style=CoachUiStyle(colors:CoachUiColors.fromTheme(theme),typography:CoachUiTypography.fromTheme(theme),strings:const CoachUiStrings(cancel:'取消',submitAnswer:'确认并生成'));
   Widget shell(Widget child)=>MaterialApp(theme:theme,home:Scaffold(body:RepaintBoundary(key:key,child:ColoredBox(color:style.colors.background,child:Padding(padding:const EdgeInsets.fromLTRB(16,100,16,0),child:CoachUiTheme(style:style,child:Align(alignment:Alignment.topLeft,child:child)))))));
   await tester.pumpWidget(shell(CoachQuestionBubble(question:const CoachQuestionData(id:'preview',question:'帮你排大腿内侧拉伸，确认一下条件',mode:CoachQuestionMode.form,fields:fields,isConfirmation:true,focus:'大腿内侧',submitLabel:'生成方案'),enabled:true,onTextAnswer:(_) async {},onChoiceAnswer:(_) async {},onFormAnswer:(_) async {})));
   await tester.pumpAndSettle(); await take('confirmation-${brightness.name}');
   await tester.pumpWidget(shell(CoachFailureBubble(onRetry:() async {},onSecondary:() async {},presetMatchesFocus:true)));
   await tester.pumpAndSettle(); await take('failure-${brightness.name}');
   expect(tester.takeException(),isNull); await tester.pumpWidget(const SizedBox.shrink());
  }
 });
}
