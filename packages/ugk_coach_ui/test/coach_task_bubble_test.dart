// Ported from Sport-Helper@13c0bb4:test/coach_task_bubble_test.dart.
// Domain inputs are replaced by ordinary, already translated summary fixtures.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

typedef _Task = ({String stage, bool complete});
typedef _Param = ({String label, bool user});

_Task _task(String stage, {bool complete = false}) =>
    (stage: stage, complete: complete);
_Param _param(String label, String source) =>
    (label: label, user: source == 'user');

Map<String, _Param> _params() => {
  'scene': _param('居家', 'user'),
  'goal': _param('拉伸', 'user'),
  'equipment': _param('徒手', 'default'),
  'level': _param('进阶', 'derived'),
  'limits': _param('无伤痛', 'default'),
};

class _State {
  const _State({this.task, this.params = const {}, this.picks = const []});
  final _Task? task;
  final Map<String, _Param> params;
  final List<String> picks;
  _State copyWith({_Task? task, List<String>? picks}) => _State(
    task: task ?? this.task,
    params: params,
    picks: picks ?? this.picks,
  );
}

class _Palette {
  const _Palette(this.brightness);
  final Brightness brightness;
  static const light = _Palette(Brightness.light);
  static const dark = _Palette(Brightness.dark);
  CoachUiColors get colors =>
      CoachUiColors.fromTheme(ThemeData(brightness: brightness));
  Color get surface => colors.taskCardSurface;
  Color get accent => colors.taskAccent;
  Color get muted => colors.taskMuted;
}

final _image = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);
Map<String, ImageProvider> _cutouts() => {
  'h-catcow-quad': _image,
  'h-banana': _image,
};

Future<void> _show(
  WidgetTester tester, {
  _Task? task,
  _State? state,
  Map<String, ImageProvider>? cutouts,
  bool waiting = true,
  bool reduced = false,
  bool tickers = true,
  bool visualComplete = false,
  double width = 390,
  double textScale = 1,
  VoidCallback? onCancel,
  _Palette palette = _Palette.light,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final current = task ?? state?.task;
  final phase = current?.complete == true
      ? 4
      : switch (current?.stage) {
          'actions' => 1,
          'planning' => 2,
          'review' => 3,
          'output' => 4,
          _ => 0,
        };
  final picks = state?.picks ?? const <String>[];
  final params = state?.params ?? const <String, _Param>{};
  final scene = params['scene']?.label;
  final goal = params['goal']?.label;
  final title = scene != null && goal != null ? '为你准备 · $scene$goal' : null;
  final status = switch (phase) {
    1 when picks.isNotEmpty => '挑好了 ${picks.length} 个动作',
    2 => '安排顺序和时长',
    3 => '最后检查一遍',
    4 => '马上就好',
    _ => null,
  };
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: palette.brightness),
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => CoachUiTheme(
        style: CoachUiStyle(
          colors: palette.colors,
          typography: CoachUiTypography.fromTheme(
            ThemeData(brightness: palette.brightness),
          ),
        ),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduced,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: TickerMode(
          enabled: tickers,
          child: CoachTaskBubble(
            title: title,
            status: status,
            phase: phase,
            complete: current?.complete ?? false,
            parameters: [
              for (final entry in params.entries)
                (
                  field: entry.key,
                  label: entry.value.label,
                  user: entry.value.user,
                ),
            ],
            picks: picks,
            cutoutFor: cutouts == null ? null : (id) => cutouts[id],
            waiting: waiting,
            visualComplete: visualComplete,
            onCancel: onCancel,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _face(String field) =>
    find.byKey(ValueKey('generation-chip-face-$field'));
Finder _fill(int index) =>
    find.byKey(ValueKey('generation-progress-fill-$index'));

void main() {
  for (final palette in [_Palette.light, _Palette.dark]) {
    testWidgets(
      '${palette.brightness.name} sourced capsules and approved card values',
      (tester) async {
        var cancelled = false;
        await _show(
          tester,
          state: _State(task: _task('parameters'), params: _params()),
          reduced: true,
          onCancel: () => cancelled = true,
          palette: palette,
        );
        expect(find.text('为你准备 · 居家拉伸'), findsOneWidget);
        expect(find.text('读懂你的需求'), findsOneWidget);
        final card = tester.widget<Container>(
          find.byKey(const ValueKey('generation-card')),
        );
        expect(card.padding, const EdgeInsets.fromLTRB(16, 14, 16, 16));
        final decoration = card.decoration! as BoxDecoration;
        final outline = card.foregroundDecoration! as BoxDecoration;
        final dark = palette.brightness == Brightness.dark;
        expect(decoration.color, palette.surface);
        expect(decoration.borderRadius, BorderRadius.circular(20));
        expect((outline.border! as Border).top.width, .5);
        expect(
          (outline.border! as Border).top.color,
          (dark ? Colors.white : Colors.black).withValues(
            alpha: dark ? .08 : .06,
          ),
        );
        if (dark) {
          expect(decoration.boxShadow, isEmpty);
        } else {
          expect(decoration.boxShadow, [
            BoxShadow(
              color: Colors.black.withValues(alpha: .04),
              offset: const Offset(0, 1),
              blurRadius: 2,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: .06),
              offset: const Offset(0, 6),
              blurRadius: 20,
            ),
          ]);
        }
        expect(
          tester.getSize(find.byKey(const ValueKey('generation-animation'))),
          const Size(44, 44),
        );
        expect(
          tester.getSize(
            find.byKey(const ValueKey('generation-cancel-target')),
          ),
          const Size(44, 44),
        );
        for (final field in ['scene', 'goal', 'equipment', 'level', 'limits']) {
          expect(tester.getSize(_face(field)).height, 24);
          expect(tester.getSize(_face(field)).width, lessThan(130));
        }
        final scene =
            tester.widget<Container>(_face('scene')).decoration!
                as BoxDecoration;
        expect(scene.color, palette.accent.withValues(alpha: dark ? .18 : .10));
        expect(scene.border, isNull);
        final inferredContainer = tester.widget<Container>(_face('level'));
        final inferred = inferredContainer.decoration! as BoxDecoration;
        final inferredOutline =
            inferredContainer.foregroundDecoration! as BoxDecoration;
        expect(inferred.color, Colors.transparent);
        expect((inferredOutline.border! as Border).top.width, 1);
        expect(
          (inferredOutline.border! as Border).top.color,
          (dark ? Colors.white : Colors.black).withValues(
            alpha: dark ? .12 : .10,
          ),
        );
        expect(
          tester.widget<Text>(find.text('进阶')).style!.color,
          palette.muted,
        );
        for (final internal in ['教练待办', '交付卡片', '核对方案', '（你说的）', '（默认）']) {
          expect(find.textContaining(internal), findsNothing);
        }
        final title = tester.widget<Text>(find.text('为你准备 · 居家拉伸')).style!;
        expect(title.fontSize, 15);
        expect(title.fontWeight, FontWeight.w600);
        expect(title.height, 1.35);
        final status = tester.widget<Text>(find.text('读懂你的需求')).style!;
        expect(status.fontSize, 13);
        expect(status.fontWeight, FontWeight.w500);
        expect(status.height, 18 / 13);
        expect(tester.widget<Text>(find.text('取消')).style!.fontSize, 13);
        await tester.tap(find.text('取消'));
        expect(cancelled, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('unknown parameters do not invent default tags or leak codes', (
    tester,
  ) async {
    await _show(tester, reduced: true);
    expect(find.text('正在想怎么练'), findsOneWidget);
    expect(find.text('居家'), findsNothing);
    expect(find.text('徒手'), findsNothing);
    expect(find.text('无伤痛'), findsNothing);
    expect(find.byKey(const ValueKey('generation-dots')), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('generation-core'))),
      const Size(10, 10),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('generation-halo'))),
      const Size(20, 20),
    );
    await _show(
      tester,
      state: _State(
        // The pure-Dart summary omits unknown parameter codes.
        params: const {},
      ),
      reduced: true,
    );
    expect(find.textContaining('internal_unknown'), findsNothing);
    expect(find.text('正在想怎么练'), findsOneWidget);
  });

  testWidgets(
    'summary phases retain status sentences and four measured segments',
    (tester) async {
      const stages = [
        ('actions', '挑好了 2 个动作', 1),
        ('planning', '安排顺序和时长', 2),
        ('review', '最后检查一遍', 3),
        ('output', '马上就好', 4),
      ];
      for (final (stage, sentence, completed) in stages) {
        await _show(
          tester,
          state: _State(
            task: _task(stage),
            picks: ['h-catcow-quad', 'h-banana'],
          ),
          reduced: true,
        );
        expect(find.text(sentence), findsOneWidget);
        for (var index = 0; index < 4; index++) {
          final segment = find.byKey(ValueKey('generation-progress-$index'));
          expect(tester.getSize(segment).height, 3);
          final first = tester.getRect(
            find.byKey(const ValueKey('generation-progress-0')),
          );
          expect(tester.getRect(segment).width, closeTo(first.width, .001));
          if (index > 0) {
            final previous = tester.getRect(
              find.byKey(ValueKey('generation-progress-${index - 1}')),
            );
            expect(
              tester.getRect(segment).left - previous.right,
              closeTo(4, .001),
            );
          }
          final fill = tester.widget<FractionallySizedBox>(_fill(index));
          expect(fill.widthFactor, index < completed ? 1 : 0);
          expect(
            tester.widget<ClipRRect>(segment).borderRadius,
            BorderRadius.circular(1.5),
          );
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'completed segment fills in 400ms and status uses staggered 160/220ms motion',
    (tester) async {
      await _show(tester, task: _task('understand'));
      await _show(tester, task: _task('actions'));
      expect(tester.widget<FractionallySizedBox>(_fill(0)).widthFactor, 0);
      expect(tester.widget<FractionallySizedBox>(_fill(1)).widthFactor, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<FractionallySizedBox>(_fill(0)).widthFactor,
        closeTo(Curves.easeOutCubic.transform(.5), .001),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<FractionallySizedBox>(_fill(0)).widthFactor, 1);
      expect(tester.widget<FractionallySizedBox>(_fill(1)).widthFactor, 0);
      await _show(tester, task: _task('planning'));
      expect(find.text('读懂你的需求'), findsOneWidget);
      expect(find.text('安排顺序和时长'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 80));
      final old = find
          .ancestor(of: find.text('读懂你的需求'), matching: find.byType(Transform))
          .first;
      final next = find
          .ancestor(of: find.text('安排顺序和时长'), matching: find.byType(Transform))
          .first;
      expect(
        tester.widget<Transform>(old).transform.storage[13],
        closeTo(-6 * Curves.easeInCubic.transform(.5), .001),
      );
      expect(
        tester.widget<Transform>(next).transform.storage[13],
        closeTo(6 * (1 - Curves.easeOutCubic.transform(20 / 220)), .001),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('读懂你的需求'), findsNothing);
      expect(find.text('安排顺序和时长'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rotation is linear and stops for reduced motion and TickerMode',
    (tester) async {
      await _show(tester);
      await tester.pump(const Duration(milliseconds: 350));
      final rotation = find.byKey(const ValueKey('generation-rotation'));
      expect(
        tester.widget<RotationTransition>(rotation).turns.value,
        closeTo(.25, .001),
      );
      await _show(tester, tickers: false);
      final mutedValue = tester
          .widget<RotationTransition>(rotation)
          .turns
          .value;
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.widget<RotationTransition>(rotation).turns.value,
        mutedValue,
      );
      await _show(tester, reduced: true);
      final value = tester.widget<RotationTransition>(rotation).turns.value;
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.widget<RotationTransition>(rotation).turns.value, value);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('trusted picked thumbnails hold 900ms and crossfade for 250ms', (
    tester,
  ) async {
    final cutouts = _cutouts();
    final state = _State(
      task: _task('actions'),
      picks: ['h-catcow-quad', 'h-banana'],
    );
    await _show(tester, state: state, cutouts: cutouts);
    expect(find.byKey(const ValueKey('generation-dots')), findsNothing);
    expect(
      find.byKey(const ValueKey('generation-thumbnail-h-catcow-quad')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('generation-thumbnail-h-banana')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(
      find.byKey(const ValueKey('generation-thumbnail-h-banana')),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 125));
    for (final id in state.picks) {
      final image = find.byKey(ValueKey('generation-thumbnail-$id'));
      expect(image, findsOneWidget);
      final opacity = find
          .ancestor(of: image, matching: find.byType(Opacity))
          .first;
      expect(tester.widget<Opacity>(opacity).opacity, closeTo(.5, .001));
    }
    await tester.pump(const Duration(milliseconds: 125));
    expect(
      find.byKey(const ValueKey('generation-thumbnail-h-catcow-quad')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('generation-thumbnail-h-banana')),
      findsOneWidget,
    );
    await _show(
      tester,
      state: state.copyWith(picks: ['h-catcow-quad']),
      cutouts: cutouts,
    );
    expect(
      find.byKey(const ValueKey('generation-thumbnail-h-catcow-quad')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'parameter changes use sourced capsules with 60ms stagger and 200ms entrance',
    (tester) async {
      await _show(tester, reduced: true);
      await _show(tester, state: _State(params: _params()));
      FadeTransition fade(String field) => tester.widget<FadeTransition>(
        find
            .ancestor(of: _face(field), matching: find.byType(FadeTransition))
            .first,
      );
      expect(fade('scene').opacity.value, 0);
      expect(fade('goal').opacity.value, 0);
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        fade('scene').opacity.value,
        closeTo(Curves.easeOutCubic.transform(.3), .001),
      );
      expect(fade('goal').opacity.value, 0);
      await tester.pump(const Duration(milliseconds: 200));
      expect(fade('scene').opacity.value, 1);
      expect(fade('goal').opacity.value, 1);
      final source = _State(
        params: {..._params(), 'equipment': _param('椅子', 'user')},
      );
      await _show(tester, state: source, reduced: true);
      expect(find.text('椅子'), findsOneWidget);
      expect(find.text('墙'), findsNothing);
      expect(find.text('徒手'), findsNothing);
      expect(
        (tester.widget<Container>(_face('equipment')).decoration!
                as BoxDecoration)
            .border,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'completion shows check and reserves cancel space without changing height',
    (tester) async {
      final state = _State(task: _task('review'), params: _params());
      await _show(tester, state: state, reduced: true, onCancel: () {});
      final card = find.byKey(const ValueKey('generation-card'));
      final previousHeight = tester.getSize(card).height;
      final cancelRect = tester.getRect(
        find.byKey(const ValueKey('generation-cancel-target')),
      );
      expect(find.text('取消'), findsOneWidget);
      await _show(
        tester,
        state: state.copyWith(task: _task('output', complete: true)),
        waiting: false,
        reduced: true,
        onCancel: () {},
      );
      expect(tester.getSize(card).height, previousHeight);
      expect(
        tester.getRect(find.byKey(const ValueKey('generation-cancel-target'))),
        cancelRect,
      );
      expect(find.text('取消'), findsNothing);
      // Prototype stroke check (2.4 px path), not a font glyph.
      expect(
        tester.getSize(find.byKey(const ValueKey('generation-check'))),
        const Size(20, 20),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.text('马上就好'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('SDK output done while waiting does not announce reply success', (
    tester,
  ) async {
    final state = _State(task: _task('output', complete: true));
    await _show(tester, state: state, onCancel: () {});
    expect(find.text('马上就好'), findsOneWidget);
    expect(find.byKey(const ValueKey('generation-check')), findsNothing);
    expect(find.text('取消'), findsOneWidget);
    await _show(tester, state: state, visualComplete: true, onCancel: () {});
    expect(find.byKey(const ValueKey('generation-check')), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    await tester.pump(const Duration(milliseconds: 240));
    final rotation = find.byKey(const ValueKey('generation-rotation'));
    final stopped = tester.widget<RotationTransition>(rotation).turns.value;
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<RotationTransition>(rotation).turns.value, stopped);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('success check preserves the completed segment 400ms fill', (
    tester,
  ) async {
    await _show(tester, task: _task('review'));
    await tester.pump(const Duration(milliseconds: 450));
    await _show(
      tester,
      task: _task('output', complete: true),
      visualComplete: true,
    );
    expect(tester.widget<FractionallySizedBox>(_fill(3)).widthFactor, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<FractionallySizedBox>(_fill(3)).widthFactor,
      closeTo(Curves.easeOutCubic.transform(.5), .001),
    );
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(const ValueKey('generation-check')), findsOneWidget);
    final rotation = find.byKey(const ValueKey('generation-rotation'));
    final turn = tester.widget<RotationTransition>(rotation).turns.value;
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.widget<FractionallySizedBox>(_fill(3)).widthFactor, 1);
    expect(tester.widget<RotationTransition>(rotation).turns.value, turn);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'switching to reduced motion stops all in-flight tickers and pins first image',
    (tester) async {
      final state = _State(
        task: _task('actions'),
        params: _params(),
        picks: ['h-catcow-quad', 'h-banana'],
      );
      final cutouts = _cutouts();
      await _show(tester);
      await _show(tester, state: state, cutouts: cutouts);
      await tester.pump(const Duration(milliseconds: 75));
      await _show(
        tester,
        state: state.copyWith(task: _task('planning')),
        cutouts: cutouts,
        reduced: true,
      );
      await tester.pump();
      expect(find.text('挑好了 2 个动作'), findsNothing);
      expect(find.text('安排顺序和时长'), findsOneWidget);
      expect(find.byType(ShaderMask), findsNothing);
      expect(
        find.byKey(const ValueKey('generation-progress-band-2')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('generation-thumbnail-h-catcow-quad')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('generation-thumbnail-h-banana')),
        findsNothing,
      );
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets(
    'visual completion closes the ring at 240ms and settles the check at 260ms',
    (tester) async {
      await _show(tester, task: _task('review'), onCancel: () {});
      final card = find.byKey(const ValueKey('generation-card'));
      final height = tester.getSize(card).height;
      await _show(
        tester,
        task: _task('review'),
        visualComplete: true,
        onCancel: () {},
      );
      expect(find.byKey(const ValueKey('generation-check')), findsOneWidget);
      expect(find.text('取消'), findsNothing);
      expect(tester.getSize(card).height, height);
      // Prototype .check: 260 ms back-out scale; ring closes at 240 ms.
      await tester.pump(const Duration(milliseconds: 260));
      final rotation = find.byKey(const ValueKey('generation-rotation'));
      final turn = tester.widget<RotationTransition>(rotation).turns.value;
      final check = find.byKey(const ValueKey('generation-check'));
      final opacity = find
          .ancestor(of: check, matching: find.byType(Opacity))
          .first;
      final scale = find
          .ancestor(of: check, matching: find.byType(Transform))
          .first;
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      expect(
        tester.widget<Transform>(scale).transform.storage[0],
        closeTo(1, .001),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.widget<RotationTransition>(rotation).turns.value, turn);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 1.5]) {
    testWidgets('320px Chinese title stays within one line at ${scale}x', (
      tester,
    ) async {
      await _show(
        tester,
        state: _State(
          task: _task('planning'),
          params: {..._params(), 'scene': _param('办公室', 'user')},
        ),
        reduced: true,
        width: 320,
        textScale: scale,
        onCancel: () {},
      );
      final title = find.text('为你准备 · 办公室拉伸');
      expect(title, findsOneWidget);
      expect(tester.widget<Text>(title).maxLines, 1);
      expect(tester.widget<Text>(title).overflow, TextOverflow.ellipsis);
      final rect = tester.getRect(title);
      final cancel = tester.getRect(
        find.byKey(const ValueKey('generation-cancel-target')),
      );
      expect(rect.right, lessThanOrEqualTo(cancel.left));
      expect(rect.left, greaterThanOrEqualTo(72));
      expect(
        tester.getRect(find.byKey(const ValueKey('generation-card'))).right,
        lessThanOrEqualTo(320),
      );
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });
  }
}
