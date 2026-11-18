import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart'
    show PoseHubDisplayUpdatePhase, PoseHubDisplayUpdateProgress;

import 'theme.dart';

/// Localized controls for the display asset update dialog.
@immutable
class PoseHubDisplayUpdateDialogStrings {
  const PoseHubDisplayUpdateDialogStrings({
    required this.title,
    required this.progress,
    required this.failure,
    required this.retry,
    required this.fileCount,
  });

  final String title;
  final String progress;
  final String failure;
  final String retry;
  final String Function(int completed, int total) fileCount;

  static const zh = PoseHubDisplayUpdateDialogStrings(
    title: '更新展示素材',
    progress: '下载进度',
    failure: '下载未完成。仍可使用当前素材。',
    retry: '重试',
    fileCount: _zhFileCount,
  );

  static const en = PoseHubDisplayUpdateDialogStrings(
    title: 'Update display assets',
    progress: 'Download progress',
    failure: 'Download interrupted. Your current assets are still available.',
    retry: 'Retry',
    fileCount: _enFileCount,
  );

  static String _zhFileCount(int completed, int total) => '$completed/$total 项';
  static String _enFileCount(int completed, int total) =>
      '$completed/$total files';

  static PoseHubDisplayUpdateDialogStrings of(BuildContext context) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;
}

/// Shows asset download progress and keeps retry in the host's control.
///
/// Use [PoseHubDisplayUpdateDialogHost] to present and dismiss the dialog based
/// on the SDK update stream.
class PoseHubDisplayUpdateDialog extends StatefulWidget {
  const PoseHubDisplayUpdateDialog({
    super.key,
    required this.progress,
    required this.onRetry,
    this.strings,
  });

  final PoseHubDisplayUpdateProgress progress;
  final Future<void> Function() onRetry;
  final PoseHubDisplayUpdateDialogStrings? strings;

  @override
  State<PoseHubDisplayUpdateDialog> createState() =>
      _PoseHubDisplayUpdateDialogState();
}

class _PoseHubDisplayUpdateDialogState
    extends State<PoseHubDisplayUpdateDialog> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } catch (_) {
      // A failed retry leaves the retry control available.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final colors = style.colors;
    final type = style.typography;
    final strings =
        widget.strings ?? PoseHubDisplayUpdateDialogStrings.of(context);
    final progress = widget.progress;
    final failed = progress.phase == PoseHubDisplayUpdatePhase.failed;
    final fraction = _fraction(progress);
    final percent = fraction == null ? null : '${(100 * fraction).floor()}%';
    final meta = type.caption.copyWith(
      color: colors.muted,
      fontFeatures: CoachUiTypography.tabular,
    );

    return Dialog(
      elevation: 0,
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      constraints: const BoxConstraints(maxWidth: 408),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.outline),
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: colors.shadow,
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: colors.accentSoft,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Icon(
                      Icons.download_rounded,
                      color: colors.accentText,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            strings.title,
                            style: type.callout.copyWith(
                              color: colors.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(progress.version, style: meta),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.maybeOf(context)?.maybePop(),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: Icon(Icons.close_rounded, color: colors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 23),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.progress,
                      style: type.label.copyWith(color: colors.text),
                    ),
                  ),
                  if (percent != null)
                    Text(
                      percent,
                      style: type.label.copyWith(
                        color: colors.accentText,
                        fontWeight: FontWeight.w700,
                        fontFeatures: CoachUiTypography.tabular,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: failed ? fraction ?? 0 : fraction,
                color: colors.accent,
                backgroundColor: colors.taskProgressTrack,
                minHeight: 6,
                borderRadius: BorderRadius.circular(8),
                semanticsLabel: strings.progress,
                semanticsValue: percent,
              ),
              if (progress.totalsKnown) ...[
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      '${_formatBytes(progress.receivedBytes)} / ${_formatBytes(progress.totalBytes)}',
                      style: meta,
                    ),
                    Text(
                      strings.fileCount(
                        progress.completedFiles,
                        progress.totalFiles,
                      ),
                      style: meta,
                    ),
                  ],
                ),
              ],
              if (failed) ...[
                const SizedBox(height: 18),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    strings.failure,
                    style: type.caption.copyWith(color: colors.text),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _retrying ? null : _retry,
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(strings.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  double? _fraction(PoseHubDisplayUpdateProgress progress) {
    if (!progress.totalsKnown) return null;
    if (progress.totalBytes > 0) {
      return (progress.receivedBytes / progress.totalBytes).clamp(0, 1);
    }
    if (progress.totalFiles > 0) {
      return (progress.completedFiles / progress.totalFiles).clamp(0, 1);
    }
    return null;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Presents an update only when the stream identifies a version to download.
///
/// Place this below the app's Navigator and keep it mounted while checking for
/// updates. A successful update closes its dialog. Dismissing a dialog leaves
/// the update running and does not change the displayed catalog.
class PoseHubDisplayUpdateDialogHost extends StatefulWidget {
  const PoseHubDisplayUpdateDialogHost({
    super.key,
    required this.progress,
    required this.onRetry,
    required this.child,
    this.strings,
  });

  final Stream<PoseHubDisplayUpdateProgress> progress;
  final Future<void> Function() onRetry;
  final Widget child;
  final PoseHubDisplayUpdateDialogStrings? strings;

  @override
  State<PoseHubDisplayUpdateDialogHost> createState() =>
      _PoseHubDisplayUpdateDialogHostState();
}

class _PoseHubDisplayUpdateDialogHostState
    extends State<PoseHubDisplayUpdateDialogHost> {
  StreamSubscription<PoseHubDisplayUpdateProgress>? _subscription;
  PoseHubDisplayUpdateProgress? _latest;
  String? _dismissedVersion;
  DialogRoute<void>? _route;
  ValueNotifier<PoseHubDisplayUpdateProgress>? _routeProgress;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(PoseHubDisplayUpdateDialogHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress == widget.progress) return;
    unawaited(_subscription?.cancel());
    _latest = null;
    _dismissedVersion = null;
    _listen();
    _scheduleRouteSync();
  }

  void _listen() {
    _subscription = widget.progress.listen((progress) {
      _latest = progress;
      if (progress.phase == PoseHubDisplayUpdatePhase.completed) {
        _dismissedVersion = null;
      }
      _scheduleRouteSync();
    });
  }

  void _scheduleRouteSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _syncRoute();
    });
    binding.ensureVisualUpdate();
  }

  void _syncRoute() {
    final progress = _latest;
    if (progress == null ||
        progress.phase == PoseHubDisplayUpdatePhase.completed) {
      final route = _route;
      _route = null;
      _routeProgress = null;
      _close(route);
      return;
    }
    if (_dismissedVersion == progress.version) return;
    if (_routeProgress case final current?) {
      current.value = progress;
      return;
    }

    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null) return;
    final inherited = CoachUiTheme.contains(context)
        ? CoachUiTheme.of(context)
        : null;
    final colors = (inherited ?? CoachUiTheme.of(context)).colors;
    final value = ValueNotifier(progress);
    final strings = widget.strings;
    final route = DialogRoute<void>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: Theme.of(
        context,
      ).colorScheme.scrim.withValues(alpha: colors.isDark ? .58 : .40),
      builder: (context) => ValueListenableBuilder(
        valueListenable: value,
        builder: (context, progress, _) {
          final dialog = PoseHubDisplayUpdateDialog(
            progress: progress,
            onRetry: () async {
              if (mounted) await widget.onRetry();
            },
            strings: strings,
          );
          return inherited == null
              ? dialog
              : CoachUiTheme(style: inherited, child: dialog);
        },
      ),
    );
    _route = route;
    _routeProgress = value;
    unawaited(
      navigator.push(route).then((_) {
        if (!identical(_route, route)) return;
        _route = null;
        _routeProgress = null;
        _dismissedVersion = value.value.version;
      }),
    );
    unawaited(route.completed.whenComplete(value.dispose));
  }

  static void _close(DialogRoute<void>? route) {
    if (route == null || !route.isActive) return;
    final navigator = route.navigator;
    if (route.isCurrent) {
      navigator?.pop();
    } else {
      navigator?.removeRoute(route);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    final route = _route;
    _route = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _close(route));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
