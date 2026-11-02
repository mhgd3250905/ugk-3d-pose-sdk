import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'trainer_poster.dart';
import 'trainer_slide_route.dart';
import 'trainer_theme.dart';

/// Optional host policy for the shared training entry. Null selects defaults.
class TrainerExperienceConfig {
  const TrainerExperienceConfig({
    this.posterWarmupTimeout = const Duration(milliseconds: 150),
  });

  final Duration posterWarmupTimeout;
}

/// The shared training entry; business player data and saving stay with hosts.
abstract final class TrainerLauncher {
  static final _openByNavigator = Expando<Object>();

  /// Warms the actual first poster before opening the complete training page.
  ///
  /// Null also means that its poster was absent, failed or timed out, or that
  /// [onStarting] declined. No route or training session starts in those cases.
  static Future<T?> open<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    required String? firstPosterAsset,
    Iterable<String> posterAssets = const [],
    TrainerExperienceConfig? experience,
    TrainerTheme? theme,
    Future<bool> Function()? onStarting,
    VoidCallback Function()? holdTransition,
    RouteSettings? settings,
  }) async {
    final asset = firstPosterAsset;
    if (asset == null || asset.isEmpty) return null;
    final config = experience ?? const TrainerExperienceConfig();
    if (config.posterWarmupTimeout <= Duration.zero) return null;
    final navigator = Navigator.of(context);
    if (_openByNavigator[navigator] != null) return null;
    final bundle = DefaultAssetBundle.of(context);
    final width = TrainingPosterImages.decodeWidth(context);
    final configuration = createLocalImageConfiguration(context);
    final identity = Object();
    _openByNavigator[navigator] = identity;
    final watch = _LaunchLifecycle();
    WidgetsBinding.instance.addObserver(watch);
    TrainingPosterLease? lease;
    VoidCallback? release;
    TrainerSlideRoute<T>? route;
    VoidCallback? listener;
    try {
      release = holdTransition?.call();
      lease = TrainingPosterImages.retain(
        asset,
        width,
        bundle: bundle,
        configuration: configuration,
      );
      if (!await lease.ready.timeout(
            config.posterWarmupTimeout,
            onTimeout: () => false,
          ) ||
          !context.mounted ||
          !navigator.mounted ||
          watch.interrupted) {
        return null;
      }
      if (onStarting != null && !await onStarting()) return null;
      if (!context.mounted || !navigator.mounted || watch.interrupted) {
        return null;
      }
      _prepareSideIcons();
      for (final next in posterAssets.toSet()) {
        if (next.isEmpty || next == asset) continue;
        unawaited(
          TrainingPosterImages.prepareAsset(
            context,
            next,
            timeout: config.posterWarmupTimeout,
          ),
        );
      }
      final opened = route = TrainerSlideRoute<T>(
        context: context,
        trainerTheme: theme,
        settings: settings,
        builder: (context) => DefaultAssetBundle(
          bundle: bundle,
          child: TrainerExperienceScope(
            control: route!.control,
            config: config,
            bundle: bundle,
            decodeWidth: width,
            firstPosterAsset: asset,
            child: Builder(builder: builder),
          ),
        ),
      );
      listener = () {
        final control = opened.control;
        if (control.exiting && !control.mediaRetired && !control.saveFailed) {
          release ??= holdTransition?.call();
        } else if (control.entered ||
            control.mediaRetired ||
            control.saveFailed) {
          release?.call();
          release = null;
        }
      };
      opened.control.addListener(listener);
      final result = await navigator.push<T>(opened);
      await opened.completed;
      return result;
    } finally {
      WidgetsBinding.instance.removeObserver(watch);
      if (listener != null) route?.control.removeListener(listener);
      release?.call();
      lease?.dispose();
      if (identical(_openByNavigator[navigator], identity)) {
        _openByNavigator[navigator] = null;
      }
    }
  }

  // Prepares the actual side-control glyphs on the CPU before the route's
  // first frame. This does not promise a warmed GPU glyph atlas.
  static void _prepareSideIcons() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final icon in const [
      CupertinoIcons.backward_end_fill,
      CupertinoIcons.forward_end_fill,
    ]) {
      final painter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: 56 * .46,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset.zero);
      painter.dispose();
    }
    recorder.endRecording().dispose();
  }
}

class _LaunchLifecycle extends WidgetsBindingObserver {
  bool interrupted = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) interrupted = true;
  }
}

/// Only the shared launcher installs this scope. Existing explicit hosts retain
/// their player, route and media defaults outside it.
class TrainerExperienceScope
    extends InheritedNotifier<TrainerSlideRouteControl> {
  const TrainerExperienceScope({
    super.key,
    required TrainerSlideRouteControl control,
    required this.config,
    required this.bundle,
    required this.decodeWidth,
    required this.firstPosterAsset,
    required super.child,
  }) : super(notifier: control);

  final TrainerExperienceConfig config;
  final AssetBundle bundle;
  final int decodeWidth;
  final String firstPosterAsset;
  TrainerSlideRouteControl get control => notifier!;

  static TrainerExperienceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrainerExperienceScope>();

  static TrainerExperienceScope? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TrainerExperienceScope>();
}
