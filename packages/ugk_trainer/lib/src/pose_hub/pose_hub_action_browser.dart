import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_surface.dart';
import '../ui/trainer_theme.dart';
import 'pose_hub_pack_image.dart';
import 'pose_hub_pack_media.dart';

enum PoseHubActionFilter { all, semanticComplete, pending }

/// Browses every original action, including entries whose training definition
/// is incomplete. AI selection is a separate, stricter catalog interface.
class PoseHubActionBrowser extends StatefulWidget {
  const PoseHubActionBrowser({
    super.key,
    required this.catalog,
    required this.mediaBaseUri,
    this.theme,
    this.onPracticeFinished,
  });
  final PoseHubAppTestCatalog catalog;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;

  @override
  State<PoseHubActionBrowser> createState() => _PoseHubActionBrowserState();
}

class _PoseHubActionBrowserState extends State<PoseHubActionBrowser> {
  String _query = '';
  PoseHubActionFilter _filter = PoseHubActionFilter.all;

  @override
  Widget build(BuildContext context) {
    final theme = _themeOf(context, widget.theme);
    final source = switch (_filter) {
      PoseHubActionFilter.all => widget.catalog.allActions,
      PoseHubActionFilter.semanticComplete =>
        widget.catalog.semanticCompleteActions,
      PoseHubActionFilter.pending => widget.catalog.pendingActions,
    };
    final query = _query.trim().toLowerCase();
    final actions = source
        .where((a) => '${a.id} ${a.nameZh}'.toLowerCase().contains(query))
        .toList(growable: false);
    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: Text('动作库 · ${widget.catalog.allActions.length}'),
        backgroundColor: theme.surface,
        foregroundColor: theme.text,
        surfaceTintColor: theme.surface,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                key: const ValueKey('posehub-search'),
                style: theme.body,
                cursorColor: theme.accent,
                decoration: InputDecoration(
                  hintText: '搜索动作名称或 ID',
                  hintStyle: theme.body.copyWith(color: theme.muted),
                  prefixIcon: Icon(CupertinoIcons.search, color: theme.muted),
                  filled: true,
                  fillColor: theme.surface,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.radius),
                    borderSide: BorderSide(color: theme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(theme.radius),
                    borderSide: BorderSide(color: theme.accent),
                  ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final (filter, title) in [
                    (
                      PoseHubActionFilter.all,
                      '全部 ${widget.catalog.allActions.length}',
                    ),
                    (
                      PoseHubActionFilter.semanticComplete,
                      '说明完整 ${widget.catalog.semanticCompleteActions.length}',
                    ),
                    (
                      PoseHubActionFilter.pending,
                      '待补 ${widget.catalog.pendingActions.length}',
                    ),
                  ])
                    ChoiceChip(
                      key: ValueKey('posehub-filter-${filter.name}'),
                      label: Text(title),
                      labelStyle: theme.label.copyWith(
                        color: _filter == filter
                            ? theme.accentText
                            : theme.text,
                      ),
                      selected: _filter == filter,
                      selectedColor: theme.surfaceHigh,
                      backgroundColor: theme.surface,
                      side: BorderSide(color: theme.border),
                      checkmarkColor: theme.accent,
                      onSelected: (_) => setState(() => _filter = filter),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('显示 ${actions.length} 个动作', style: theme.label),
              ),
            ),
            Expanded(
              child: ListView.separated(
                key: const ValueKey('posehub-action-list'),
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: actions.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final action = actions[index];
                  return Semantics(
                    button: true,
                    label: '${action.nameZh}，${action.trainingStatusLabel}',
                    child: GestureDetector(
                      key: ValueKey('posehub-action-${action.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => PoseHubActionDetail(
                            action: action,
                            mediaBaseUri: widget.mediaBaseUri,
                            theme: theme,
                            onPracticeFinished: widget.onPracticeFinished,
                          ),
                        ),
                      ),
                      child: TrainerSurface(
                        theme: theme,
                        radius: theme.radius,
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            SizedBox.square(
                              dimension: 88,
                              child: PoseHubPackImage(
                                file: action.thumbnail,
                                baseUri: widget.mediaBaseUri,
                                semanticLabel: action.nameZh,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(action.nameZh, style: theme.callout),
                                  const SizedBox(height: 4),
                                  Text(action.id, style: theme.label),
                                  const SizedBox(height: 6),
                                  Text(
                                    action.trainingStatusLabel,
                                    style: theme.label.copyWith(
                                      color: action.trainingDefinitionComplete
                                          ? theme.accentText
                                          : theme.caution,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              CupertinoIcons.chevron_right,
                              color: theme.muted,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PoseHubActionDetail extends StatelessWidget {
  const PoseHubActionDetail({
    super.key,
    required this.action,
    required this.mediaBaseUri,
    this.theme,
    this.onPracticeFinished,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;

  @override
  Widget build(BuildContext context) {
    final th = _themeOf(context, theme);
    return Scaffold(
      backgroundColor: th.background,
      appBar: AppBar(
        title: Text(action.nameZh),
        backgroundColor: th.surface,
        surfaceTintColor: th.surface,
        foregroundColor: th.text,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: PoseHubPackImage(
                file: action.cover,
                baseUri: mediaBaseUri,
                semanticLabel: '${action.nameZh}动作封面',
              ),
            ),
            Text(action.nameZh, style: th.title),
            Text(action.id, style: th.label),
            const SizedBox(height: 12),
            Text(
              action.trainingStatusLabel,
              style: th.callout.copyWith(
                color: action.trainingDefinitionComplete
                    ? th.accentText
                    : th.caution,
              ),
            ),
            if (!action.trainingDefinitionComplete)
              Text('可浏览与自主单练；次数、组数和时长由你决定。', style: th.body),
            const SizedBox(height: 16),
            _information(action, th),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('posehub-practice'),
              style: FilledButton.styleFrom(
                backgroundColor: th.accent,
                foregroundColor: th.onAccent,
                minimumSize: const Size(80, 52),
              ),
              icon: const Icon(CupertinoIcons.play_fill),
              label: const Text('单练'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => PoseHubSinglePracticePage(
                    action: action,
                    mediaBaseUri: mediaBaseUri,
                    theme: th,
                    onFinished: onPracticeFinished,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class PoseHubPracticeResult {
  const PoseHubPracticeResult({
    required this.actionId,
    required this.activeDuration,
    required this.trainingDefinitionComplete,
  });
  final String actionId;
  final Duration activeDuration;
  final bool trainingDefinitionComplete;
}

/// Manual single-action practice works for all 219 entries. No unknown dose,
/// rep timing or safety instruction is inferred from video duration.
class PoseHubSinglePracticePage extends StatefulWidget {
  const PoseHubSinglePracticePage({
    super.key,
    required this.action,
    required this.mediaBaseUri,
    this.theme,
    this.onFinished,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onFinished;
  @override
  State<PoseHubSinglePracticePage> createState() => _PoseHubPracticeState();
}

class _PoseHubPracticeState extends State<PoseHubSinglePracticePage>
    with WidgetsBindingObserver {
  final _clock = Stopwatch();
  Timer? _ticker;
  bool _started = false;
  bool _finished = false;
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _clock.isRunning) setState(() {});
    });
  }

  void _toggle() {
    if (_finished) return;
    setState(() {
      _started = true;
      _paused = _clock.isRunning;
      if (_paused) {
        _clock.stop();
      } else {
        _clock.start();
      }
    });
  }

  void _finish() {
    if (_finished || !_started) return;
    _clock.stop();
    setState(() {
      _finished = true;
      _paused = true;
    });
    widget.onFinished?.call(
      PoseHubPracticeResult(
        actionId: widget.action.id,
        activeDuration: _clock.elapsed,
        trainingDefinitionComplete: widget.action.trainingDefinitionComplete,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _clock.isRunning) {
      _clock.stop();
      setState(() => _paused = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final th = _themeOf(context, widget.theme);
    final elapsed = _clock.elapsed.inSeconds;
    return Scaffold(
      backgroundColor: th.background,
      appBar: AppBar(
        title: Text(widget.action.nameZh),
        backgroundColor: th.surface,
        surfaceTintColor: th.surface,
        foregroundColor: th.text,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.action.trainingStatusLabel,
              style: th.callout.copyWith(
                color: widget.action.trainingDefinitionComplete
                    ? th.accentText
                    : th.caution,
              ),
            ),
            AspectRatio(
              aspectRatio: 1,
              child: PoseHubPackMedia(
                key: ValueKey('posehub-practice-media-${widget.action.id}'),
                action: widget.action,
                baseUri: widget.mediaBaseUri,
                playing: _started && !_finished,
                paused: _paused,
                theme: th,
              ),
            ),
            Center(
              child: Text(
                '${elapsed ~/ 60}:${(elapsed % 60).toString().padLeft(2, '0')}',
                key: const ValueKey('posehub-elapsed'),
                style: th.numeral(40),
              ),
            ),
            Center(
              child: Text(_finished ? '单练已结束' : '自主单练 · 实际用时', style: th.label),
            ),
            const SizedBox(height: 16),
            if (!_finished)
              FilledButton(
                key: const ValueKey('posehub-practice-toggle'),
                style: FilledButton.styleFrom(
                  backgroundColor: th.accent,
                  foregroundColor: th.onAccent,
                  minimumSize: const Size(80, 52),
                ),
                onPressed: _toggle,
                child: Text(
                  !_started
                      ? '开始单练'
                      : _paused
                      ? '继续'
                      : '暂停',
                ),
              ),
            if (_started && !_finished)
              TextButton(
                key: const ValueKey('posehub-practice-finish'),
                style: TextButton.styleFrom(foregroundColor: th.text),
                onPressed: _finish,
                child: const Text('结束单练'),
              ),
            const SizedBox(height: 16),
            _information(widget.action, th),
          ],
        ),
      ),
    );
  }
}

TrainerTheme _themeOf(BuildContext context, TrainerTheme? supplied) =>
    supplied ??
    (Theme.of(context).brightness == Brightness.dark
        ? TrainerTheme.dark
        : TrainerTheme.light);

Widget _information(PoseHubPackAction action, TrainerTheme theme) {
  final raw = action.raw;
  final cues = raw['cues'];
  final zh = cues is Map ? cues['zh'] : null;
  final dose = raw['defaultDose'];
  final values = <Widget>[];
  void line(String label, Object? value) {
    if (value is String && value.trim().isNotEmpty) {
      values.add(Text('$label$value', style: theme.body));
    }
  }

  line('用途：', raw['purpose']);
  line('器械：', raw['equipmentZh']);
  if (action.trainingDefinitionComplete && dose is Map) {
    final amount = dose['mode'] == 'reps'
        ? '${dose['reps']} 次'
        : '${dose['seconds']} 秒';
    values.add(
      Text(
        '原始建议：${dose['sets']} 组 × $amount · 组间 ${dose['restSeconds']} 秒',
        style: theme.callout,
      ),
    );
  }
  if (zh is List) {
    for (final cue in zh) {
      line('· ', cue);
    }
  }
  final errors = raw['commonErrors'];
  final errorZh = errors is Map ? errors['zh'] : null;
  if (errorZh is List) {
    for (final error in errorZh) {
      line('常见问题：', error);
    }
  }
  final cautionNotes = raw['cautionNotes'];
  final cautionZh = cautionNotes is Map ? cautionNotes['zh'] : null;
  if (cautionZh is String) line('注意：', cautionZh);
  if (cautionZh is List) {
    for (final note in cautionZh) {
      line('注意：', note);
    }
  }
  for (final (field, label) in [
    ('cautions', '原始注意部位：'),
    ('contraindications', '原始禁忌记录：'),
  ]) {
    final value = raw[field];
    if (value is List && value.isNotEmpty) {
      line(label, value.whereType<String>().join('、'));
    }
  }
  if (!action.trainingDefinitionComplete) {
    values.add(
      Text(
        '训练说明待补；未预设次数、组数、时长或计次节奏。',
        key: const ValueKey('posehub-pending-label'),
        style: theme.body.copyWith(color: theme.caution),
      ),
    );
  }
  return TrainerSurface(
    theme: theme,
    radius: theme.radius,
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: values,
    ),
  );
}
