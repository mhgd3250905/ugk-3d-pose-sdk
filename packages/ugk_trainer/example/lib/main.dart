import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() => runApp(
  ShowcaseApp(
    initialState: ShowcaseState.values.firstWhere(
      (state) => state.name == Uri.base.queryParameters['state'],
      orElse: () => ShowcaseState.training,
    ),
    initialLibrary: Uri.base.queryParameters['page'] == 'library',
    initialTheme: switch (Uri.base.queryParameters['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    },
  ),
);

enum ShowcaseState {
  preview('动作演示'),
  training('训练中'),
  rest('休息'),
  transition('换侧'),
  result('结果');

  const ShowcaseState(this.label);
  final String label;
}

class ShowcaseApp extends StatefulWidget {
  const ShowcaseApp({
    super.key,
    this.initialState = ShowcaseState.training,
    this.initialTheme = ThemeMode.system,
    this.fontFamily,
    this.onSaved,
    this.initialLibrary = false,
  });
  final ShowcaseState initialState;
  final ThemeMode initialTheme;
  final String? fontFamily;
  final ValueChanged<SessionResult>? onSaved;
  final bool initialLibrary;
  @override
  State<ShowcaseApp> createState() => _ShowcaseAppState();
}

class _ShowcaseAppState extends State<ShowcaseApp> {
  late ThemeMode _mode = widget.initialTheme;
  ThemeData _theme(Brightness brightness) {
    final palette = brightness == Brightness.dark
        ? TrainerTheme.dark
        : TrainerTheme.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: widget.fontFamily,
      scaffoldBackgroundColor: palette.background,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: palette.accent,
            brightness: brightness,
          ).copyWith(
            surface: palette.background,
            surfaceContainerLow: palette.surface,
            surfaceContainerHigh: palette.surfaceHigh,
            surfaceContainerHighest: palette.surfaceHigh,
            onSurface: palette.text,
            onSurfaceVariant: palette.muted,
            primary: palette.accent,
            onPrimary: palette.onAccent,
            outline: palette.border,
            outlineVariant: palette.border,
            shadow: palette.shadow,
          ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'UGK · 训练播放展示',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: _mode,
    themeAnimationDuration: Duration.zero,
    initialRoute: widget.initialLibrary ? '/library' : '/showcase',
    builder: (_, child) => _ShowcaseSettings(
      mode: _mode,
      onMode: (value) => setState(() => _mode = value),
      child: child!,
    ),
    onGenerateRoute: (settings) => PageRouteBuilder<void>(
      settings: settings,
      pageBuilder: (_, _, _) => switch (settings.name) {
        '/showcase' => ShowcaseScreen(
          initialState: widget.initialState,
          fontFamily: widget.fontFamily,
          onSaved: widget.onSaved,
        ),
        '/library' => const _PoseHubLibraryDemo(),
        _ => const _Launcher(),
      },
      // Never wrap the media route in a full-page Opacity or Clip layer.
      transitionsBuilder: (_, _, _, child) => child,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}

class _ShowcaseSettings extends InheritedWidget {
  const _ShowcaseSettings({
    required this.mode,
    required this.onMode,
    required super.child,
  });
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onMode;
  static _ShowcaseSettings of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShowcaseSettings>()!;
  @override
  bool updateShouldNotify(_ShowcaseSettings oldWidget) =>
      mode != oldWidget.mode;
}

class _Launcher extends StatelessWidget {
  const _Launcher();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton.icon(
        onPressed: () => Navigator.of(context).pushNamed('/showcase'),
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('打开训练展示'),
      ),
    ),
  );
}

class _PoseHubLibraryDemo extends StatelessWidget {
  const _PoseHubLibraryDemo();
  @override
  Widget build(BuildContext context) => FutureBuilder<PoseHubAppTestCatalog>(
    future: PoseHubActionLibrary.load(),
    builder: (context, snapshot) {
      final catalog = snapshot.data;
      if (catalog == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('219 动作库')),
          body: Center(
            child: snapshot.hasError
                ? const Text('动作目录暂时无法加载')
                : const CircularProgressIndicator(),
          ),
        );
      }
      const configuredBase = String.fromEnvironment('POSEHUB_MEDIA_BASE');
      final mediaBase = configuredBase.isEmpty
          ? Uri.base.resolve('/__posehub_pack__/')
          : Uri.parse(configuredBase);
      return PoseHubActionBrowser(catalog: catalog, mediaBaseUri: mediaBase);
    },
  );
}

class ShowcaseScreen extends StatefulWidget {
  const ShowcaseScreen({
    super.key,
    required this.initialState,
    this.fontFamily,
    this.onSaved,
  });
  final ShowcaseState initialState;
  final String? fontFamily;
  final ValueChanged<SessionResult>? onSaved;
  @override
  State<ShowcaseScreen> createState() => _ShowcaseScreenState();
}

class _ShowcaseScreenState extends State<ShowcaseScreen> {
  late ShowcaseState _state = widget.initialState;
  int _generation = 0;
  SessionResult? _lastSaved;
  void _select(ShowcaseState state) => setState(() {
    _state = state;
    _generation++;
  });

  @override
  Widget build(BuildContext context) {
    final settings = _ShowcaseSettings.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final theme = (dark ? TrainerTheme.dark : TrainerTheme.light).copyWith(
      fontFamily: widget.fontFamily,
    );
    return Scaffold(
      backgroundColor: theme.background,
      body: Column(
        children: [
          // Demo controls stay outside the SDK viewport and its touch targets.
          SafeArea(
            bottom: false,
            child: Container(
              decoration: BoxDecoration(
                color: theme.background,
                border: Border(bottom: BorderSide(color: theme.track)),
              ),
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'SDK 实色分层 · 模拟人物',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.label.copyWith(fontSize: 12),
                    ),
                  ),
                  PopupMenuButton<ShowcaseState>(
                    key: const ValueKey('showcase-state'),
                    tooltip: '切换展示状态',
                    initialValue: _state,
                    onSelected: _select,
                    itemBuilder: (_) => [
                      for (final state in ShowcaseState.values)
                        CheckedPopupMenuItem(
                          value: state,
                          checked: _state == state,
                          child: Text(state.label),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                        height: 48,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_state.label, style: theme.callout),
                            const SizedBox(width: 4),
                            Icon(Icons.expand_more_rounded, color: theme.muted),
                          ],
                        ),
                      ),
                    ),
                  ),
                  PopupMenuButton<ThemeMode>(
                    key: const ValueKey('showcase-theme'),
                    tooltip: '浅色、深色或跟随系统',
                    initialValue: settings.mode,
                    onSelected: settings.onMode,
                    icon: Icon(switch (settings.mode) {
                      ThemeMode.system => Icons.brightness_auto_rounded,
                      ThemeMode.light => Icons.light_mode_rounded,
                      ThemeMode.dark => Icons.dark_mode_rounded,
                    }, color: theme.text),
                    constraints: const BoxConstraints(minWidth: 168),
                    itemBuilder: (_) => [
                      for (final entry in const {
                        ThemeMode.system: '跟随系统',
                        ThemeMode.light: '浅色',
                        ThemeMode.dark: '深色',
                      }.entries)
                        CheckedPopupMenuItem(
                          value: entry.key,
                          checked: settings.mode == entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                  ),
                  IconButton(
                    key: const ValueKey('showcase-library'),
                    tooltip: '219 动作库',
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/library'),
                    icon: Icon(Icons.grid_view_rounded, color: theme.text),
                  ),
                  IconButton(
                    key: const ValueKey('showcase-restart'),
                    tooltip: '重播当前展示',
                    onPressed: () => _select(_state),
                    icon: Icon(Icons.replay_rounded, color: theme.muted),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: RepaintBoundary(
                key: const ValueKey('showcase-player-capture'),
                child: TrainerPlayer(
                  key: ValueKey('showcase-player-${_state.name}-$_generation'),
                  plan: demoPlan,
                  drillOf: demoDrill,
                  strings: TrainerStrings.zh(),
                  theme: theme,
                  sessionId: 'showcase-${_state.name}-$_generation',
                  sessionBuilder: DemoSessionBuilder(_state),
                  startMode: _state == ShowcaseState.preview
                      ? TrainerStartMode.preview
                      : TrainerStartMode.training,
                  keepAlive: false,
                  voice: TrainerVoice.silent,
                  showExtendRest: true,
                  showCompleteTimedPhase: true,
                  showSoundToggle: true,
                  mediaBuilder: (_, request) => DemoFigure(
                    dark: request.theme.isDark,
                    mirrored: request.mirrored,
                  ),
                  onFinished: (result) async {
                    // In memory only; no host app account or storage.
                    _lastSaved = result;
                    widget.onSaved?.call(result);
                  },
                  feedbackBuilder: (_, result) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _lastSaved?.sessionId == result.sessionId
                          ? '展示记录已保存在内存，退出即清除'
                          : '模拟训练 · 仅供界面验收',
                      textAlign: TextAlign.center,
                      style: theme.label,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _lunge = PlanItem(
  exerciseId: 'lunge',
  mode: DoseMode.time,
  sets: 1,
  workSeconds: 45,
  perSide: true,
  restSeconds: 30,
);
const _reach = PlanItem(
  exerciseId: 'reach',
  mode: DoseMode.time,
  sets: 1,
  workSeconds: 40,
  perSide: false,
  restSeconds: 30,
);

final demoPlan = TrainingPlan(
  id: 'showcase-plan',
  source: 'template',
  title: '舒展全身',
  goal: 'mobility',
  scene: 'home',
  level: 1,
  targetMinutes: 3,
  blocks: [
    PlanBlock(
      id: 'mobility',
      name: '全身舒展',
      type: BlockType.main,
      items: const [_lunge, _reach],
    ),
  ],
);

TrainerDrill? demoDrill(String id) => switch (id) {
  'lunge' => const TrainerDrill(
    id: 'lunge',
    name: '弓步伸展',
    cues: ['放松肩颈，保持均匀呼吸', '双脚站稳，缓慢移向前侧', '保持身体稳定，不要憋气'],
    precautions: ['不强迫手触地'],
    targetMuscles: '髋部',
    equipment: '徒手',
  ),
  'reach' => const TrainerDrill(
    id: 'reach',
    name: '站姿侧向伸展',
    cues: ['双脚站稳，感受身体侧面伸展', '保持均匀呼吸', '缓慢回到起始位置'],
    targetMuscles: '躯干',
    equipment: '徒手',
  ),
  _ => null,
};

/// Demo-only authored phases; production engine and public API stay unchanged.
class DemoSessionBuilder extends SessionBuilder {
  DemoSessionBuilder(this.state);
  final ShowcaseState state;
  SessionPhase _work(PlanItem item, int index, {Side? side, double? seconds}) =>
      SessionPhase(
        kind: PhaseKind.work,
        seconds: seconds ?? item.workSeconds!.toDouble(),
        exerciseId: item.exerciseId,
        item: item,
        itemIndex: index,
        blockIndex: 0,
        itemInBlock: index,
        set: 1,
        sets: 1,
        blockName: '全身舒展',
        side: side,
      );
  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    final right = _work(_lunge, 0, side: Side.right);
    final left = _work(_lunge, 0, side: Side.left);
    final reach = _work(_reach, 1);
    const change = SessionPhase(
      kind: PhaseKind.switchSide,
      seconds: 12,
      exerciseId: 'lunge',
      item: _lunge,
      itemIndex: 0,
      blockIndex: 0,
      itemInBlock: 0,
      set: 1,
      sets: 1,
      side: Side.left,
      blockName: '全身舒展',
    );
    const rest = SessionPhase(
      kind: PhaseKind.rest,
      seconds: 30,
      exerciseId: 'reach',
      item: _reach,
      itemIndex: 1,
      blockIndex: 0,
      itemInBlock: 1,
      nextExerciseId: 'reach',
      nextItem: _reach,
      doneExerciseId: 'lunge',
      set: 1,
      sets: 1,
      blockName: '全身舒展',
    );
    const done = SessionPhase(kind: PhaseKind.done, seconds: 0);
    return switch (state) {
      ShowcaseState.training => [right, change, left, rest, reach, done],
      ShowcaseState.preview => [
        const SessionPhase(
          kind: PhaseKind.prep,
          seconds: 10,
          exerciseId: 'lunge',
          item: _lunge,
          itemIndex: 0,
          blockIndex: 0,
          itemInBlock: 0,
          set: 1,
          sets: 1,
          blockName: '全身舒展',
        ),
        right,
        change,
        left,
        rest,
        reach,
        done,
      ],
      ShowcaseState.rest => [rest, reach, done],
      ShowcaseState.transition => [change, left, rest, reach, done],
      // Short genuine engine visits produce a result; no invented statistics.
      ShowcaseState.result => [
        _work(_lunge, 0, side: Side.right, seconds: .12),
        _work(_lunge, 0, side: Side.left, seconds: .12),
        _work(_reach, 1, seconds: .12),
        done,
      ],
    };
  }
}

/// Original vector mannequin with a transparent background. This is a layout
/// fixture, never evidence that native alpha-video playback has been verified.
class DemoFigure extends StatelessWidget {
  const DemoFigure({super.key, required this.dark, required this.mirrored});
  final bool dark;
  final bool mirrored;
  @override
  Widget build(BuildContext context) => Semantics(
    label: '透明背景模拟人物，非真实训练视频',
    image: true,
    child: CustomPaint(
      painter: _FigurePainter(dark: dark, mirrored: mirrored),
    ),
  );
}

class _FigurePainter extends CustomPainter {
  const _FigurePainter({required this.dark, required this.mirrored});
  final bool dark;
  final bool mirrored;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height);
    canvas.save();
    canvas.translate((size.width - scale) / 2, (size.height - scale) / 2);
    canvas.scale(scale);
    if (mirrored) {
      canvas.translate(1, 0);
      canvas.scale(-1, 1);
    }
    final skin = dark ? const Color(0xFFDFC9B8) : const Color(0xFFC0A18A);
    final suit = dark ? const Color(0xFF78A89C) : const Color(0xFF396F62);
    final shade = dark ? const Color(0xFF3E655D) : const Color(0xFF204D43);
    void limb(Offset a, Offset b, double width, Color color) => canvas.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    limb(const Offset(.48, .53), const Offset(.35, .68), .082, shade);
    limb(const Offset(.35, .68), const Offset(.28, .85), .065, shade);
    limb(const Offset(.51, .53), const Offset(.63, .69), .085, suit);
    limb(const Offset(.63, .69), const Offset(.76, .84), .061, suit);
    limb(const Offset(.27, .86), const Offset(.20, .87), .035, skin);
    limb(const Offset(.76, .85), const Offset(.82, .86), .035, skin);
    final torso = Path()
      ..moveTo(.425, .31)
      ..quadraticBezierTo(.49, .285, .55, .32)
      ..lineTo(.555, .48)
      ..quadraticBezierTo(.56, .565, .49, .575)
      ..quadraticBezierTo(.425, .56, .425, .49)
      ..close();
    canvas.drawPath(
      torso,
      Paint()
        ..shader = LinearGradient(
          colors: [shade, suit, Color.lerp(suit, Colors.white, .2)!],
        ).createShader(const Rect.fromLTWH(.42, .3, .14, .28)),
    );
    limb(const Offset(.43, .33), const Offset(.34, .43), .047, skin);
    limb(const Offset(.34, .43), const Offset(.27, .52), .037, skin);
    limb(const Offset(.55, .33), const Offset(.64, .25), .046, skin);
    limb(const Offset(.64, .25), const Offset(.71, .16), .036, skin);
    limb(const Offset(.49, .32), const Offset(.49, .27), .043, skin);
    canvas.drawOval(
      const Rect.fromLTWH(.447, .17, .083, .112),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(skin, Colors.white, .17)!, skin],
        ).createShader(const Rect.fromLTWH(.447, .17, .083, .112)),
    );
    final hair = Path()
      ..moveTo(.446, .225)
      ..quadraticBezierTo(.431, .165, .49, .165)
      ..quadraticBezierTo(.535, .165, .533, .211)
      ..quadraticBezierTo(.49, .194, .454, .218)
      ..close();
    canvas.drawPath(hair, Paint()..color = const Color(0xFF34383A));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FigurePainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.mirrored != mirrored;
}
