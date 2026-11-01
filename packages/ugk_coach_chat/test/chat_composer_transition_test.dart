import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/ui/chat_composer_dock.dart';
import 'package:ugk_coach_chat/src/ui/training_transition_activity.dart';
import 'package:ugk_coach_chat/src/ui/chat_widgets.dart';
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';

class _DockHost extends StatefulWidget {
  const _DockHost({super.key, this.reduced = false});
  final bool reduced;

  @override
  State<_DockHost> createState() => _DockHostState();
}

class _DockHostState extends State<_DockHost> {
  final extent = ValueNotifier<double>(112);
  final focus = FocusNode();
  final activity = TrainingTransitionActivity();
  bool open = false;

  void setPanel(bool value) => setState(() => open = value);

  @override
  void dispose() {
    focus.dispose();
    activity.dispose();
    extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      resizeToAvoidBottomInset: false,
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: widget.reduced),
          child: CoachChatTheme(
            visual: const CoachChatVisuals(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: extent,
                  child: const ColoredBox(color: Colors.transparent),
                  builder: (context, value, child) =>
                      Positioned.fill(bottom: value, child: child!),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ChatComposerDock(
                    panelOpen: open,
                    activity: activity,
                    focusNode: focus,
                    extent: extent,
                    suggestions: const SizedBox(height: 52),
                    input: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        height: 54,
                        child: TextField(focusNode: focus),
                      ),
                    ),
                    panel: ChatFeaturePanel(
                      actions: [
                        for (var index = 0; index < 4; index++)
                          ChatPanelAction(
                            key: ValueKey('action-$index'),
                            label: '功能$index',
                            icon: ChatGlyph.grid,
                            onTap: () {},
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'reduced-motion dock can publish beside its viewport during updates',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = GlobalKey<_DockHostState>();
      await tester.pumpWidget(_DockHost(key: host, reduced: true));
      await tester.pumpAndSettle();
      final collapsed = host.currentState!.extent.value;
      host.currentState!.setPanel(true);
      await tester.pumpAndSettle();
      expect(host.currentState!.extent.value, greaterThan(collapsed));
      expect(tester.takeException(), isNull);
      host.currentState!.setPanel(false);
      await tester.pumpAndSettle();
      expect(host.currentState!.extent.value, collapsed);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shorter IME releases retained handoff without a one-frame drop',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = GlobalKey<_DockHostState>();
      await tester.pumpWidget(_DockHost(key: host));
      await tester.pumpAndSettle();
      final state = host.currentState!;
      state.focus.requestFocus();
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      state.setPanel(true);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      final oldExtent = state.extent.value;
      state.focus.requestFocus();
      await tester.pump();
      state.setPanel(false);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pump();
      final target = oldExtent - 100;
      var previous = state.extent.value;
      var sawIntermediateExtent = false;
      final motion =
          tester
                  .widget<SizeTransition>(
                    find.byKey(const ValueKey('chat-panel-transition')),
                  )
                  .sizeFactor
              as CurvedAnimation;
      final driver = motion.parent;
      for (var frame = 0; frame < 36; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final current = state.extent.value;
        expect(current, lessThanOrEqualTo(previous + .01));
        expect(
          previous - current,
          lessThan(40),
          reason:
              'The 100dp handoff difference must not disappear in one frame.',
        );
        if (current < oldExtent - .01 && current > target + .01) {
          sawIntermediateExtent = true;
          expect(
            tester
                .getSize(find.byKey(const ValueKey('chat-panel-transition')))
                .height,
            0,
            reason: 'Retiring the spare slot must not reveal the closed menu.',
          );
        }
        final nextMotion =
            tester
                    .widget<SizeTransition>(
                      find.byKey(const ValueKey('chat-panel-transition')),
                    )
                    .sizeFactor
                as CurvedAnimation;
        expect(nextMotion.parent, same(driver));
        previous = current;
      }
      expect(sawIntermediateExtent, isTrue);
      expect(state.extent.value, closeTo(oldExtent - 100, .01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopening during spare-slot settling preserves the current extent',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final host = GlobalKey<_DockHostState>();
      await tester.pumpWidget(_DockHost(key: host));
      await tester.pumpAndSettle();
      final state = host.currentState!;
      state.focus.requestFocus();
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      state.setPanel(true);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      state.focus.requestFocus();
      await tester.pump();
      state.setPanel(false);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pump();
      for (var frame = 0; frame < 19; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-panel-transition')))
            .height,
        0,
      );
      final before = state.extent.value;
      state.setPanel(true);
      await tester.pump();
      expect(
        state.extent.value,
        closeTo(before, .01),
        reason: 'A reversal must start from the visible spare-slot extent.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
