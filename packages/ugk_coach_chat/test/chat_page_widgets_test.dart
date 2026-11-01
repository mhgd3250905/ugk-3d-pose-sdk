import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';
import 'package:ugk_coach_chat/src/theme/chat_tokens.dart';
import 'package:ugk_coach_chat/src/ui/chat_widgets.dart';

void main() {
  const inputKey = ValueKey('chat-input');

  Future<void> showInput(
    WidgetTester tester, {
    ValueChanged<String>? onSend,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: CoachChatTheme(
          visual: const CoachChatVisuals(),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatInputBar(onSend: onSend ?? (_) {}, onPlans: () {}),
            ),
          ),
        ),
      ),
    );
  }

  Rect capsule(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(ChatInputBar),
      matching: find.byType(Material),
    ),
  );

  EditableText editor(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText));

  testWidgets('the whole input padding focuses the keyboard', (tester) async {
    await showInput(tester);
    final rect = capsule(tester);
    expect(rect.height, ChatComposerTokens.inputHeight);
    final x = tester.getCenter(find.byKey(inputKey)).dx;
    for (final y in [rect.top + 2, rect.bottom - 2]) {
      editor(tester).focusNode.unfocus();
      tester.testTextInput.hide();
      await tester.pump();
      await tester.tapAt(Offset(x, y));
      await tester.pump();
      expect(editor(tester).focusNode.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    }
  });

  testWidgets('a hidden keyboard reopens without losing the draft', (
    tester,
  ) async {
    await showInput(tester);
    await tester.tap(find.byKey(inputKey));
    await tester.pump();
    tester.testTextInput.enterText('办公室 10 分钟');
    await tester.pump();
    tester.testTextInput.hide();
    expect(editor(tester).focusNode.hasFocus, isTrue);
    await tester.tapAt(
      Offset(
        tester.getCenter(find.byKey(inputKey)).dx,
        capsule(tester).bottom - 2,
      ),
    );
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(editor(tester).controller.text, '办公室 10 分钟');
  });

  testWidgets('a draft grows the input to at most four visible lines', (
    tester,
  ) async {
    await showInput(tester);
    final one = capsule(tester).height;
    await tester.enterText(find.byKey(inputKey), '第一行\n第二行');
    await tester.pump();
    final two = capsule(tester).height;
    expect(two, greaterThan(one));
    await tester.enterText(find.byKey(inputKey), '第一行\n第二行\n第三行\n第四行');
    await tester.pump();
    final four = capsule(tester).height;
    expect(four, greaterThan(two));
    await tester.enterText(
      find.byKey(inputKey),
      '第一行\n第二行\n第三行\n第四行\n第五行\n第六行',
    );
    await tester.pump();
    expect(capsule(tester).height, four);
    expect(editor(tester).controller.text, contains('第六行'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the full send target submits one trimmed draft and clears it', (
    tester,
  ) async {
    final sent = <String>[];
    await showInput(tester, onSend: sent.add);
    final sending = find.byKey(const ValueKey('chat-send'));
    expect(tester.getSize(sending).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(sending).height, greaterThanOrEqualTo(44));
    await tester.tap(sending);
    expect(sent, isEmpty);
    await tester.enterText(find.byKey(inputKey), '  办公室 10 分钟  ');
    await tester.pump();
    final rect = tester.getRect(sending);
    await tester.tapAt(Offset(rect.left + 1, rect.center.dy));
    await tester.pumpAndSettle();
    expect(sent, ['办公室 10 分钟']);
    expect(editor(tester).controller.text, isEmpty);
  });
}
