import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'trainer_theme.dart';

/// The opaque training route shared by hosts, ported from SmartFit 13c0bb4.
///
/// The complete page is built from its first frame. Only horizontal translation
/// is animated: 300 ms easeOutCubic on entry and 280 ms easeInCubic displacement
/// on exit. Reduced motion uses zero-duration transitions.
///
/// Wire [control.startGate] to TrainerPlayer.startGate, [control.beginExit] to
/// TrainerPlayer.onExitStarted, and [control.beforeExitPop] to
/// TrainerPlayer.beforeExitPop. A child may obtain the same control from
/// [TrainerSlideRouteScope.maybeOf]. Saving remains the player's responsibility;
/// a failed save must call [control.exitSaveFailed] before rethrowing the error.
class TrainerSlideRoute<T> extends PageRouteBuilder<T> {
  TrainerSlideRoute({
    required BuildContext context,
    required WidgetBuilder builder,
    this.trainerTheme,
    super.settings,
  }) : reducedMotion = MediaQuery.disableAnimationsOf(context),
       super(
         opaque: true,
         allowSnapshotting: false,
         transitionDuration: MediaQuery.disableAnimationsOf(context)
             ? Duration.zero
             : const Duration(milliseconds: 300),
         reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
             ? Duration.zero
             : const Duration(milliseconds: 280),
         pageBuilder: (context, _, _) => _TrainerSlideRoutePage(
           route: ModalRoute.of(context)! as TrainerSlideRoute,
           builder: builder,
         ),
         transitionsBuilder: (context, animation, _, child) => Stack(
           fit: StackFit.expand,
           children: [
             // Unlike ModalRoute's barrier, this still blocks the source page
             // while the route is dismissed but its durable save is pending.
             const AbsorbPointer(
               key: ValueKey('training-navigation-lock'),
               child: SizedBox.expand(),
             ),
             SlideTransition(
               key: const ValueKey('training-slide'),
               position:
                   (ModalRoute.of(context)! as TrainerSlideRoute)._position,
               child: child,
             ),
           ],
         ),
       );

  /// Supplies the opaque stage and system-bar colors for the whole route.
  /// Null selects [TrainerTheme.light] or [TrainerTheme.dark] from the host.
  final TrainerTheme? trainerTheme;
  final bool reducedMotion;

  /// Route orchestration only; training, records and navigation stay in the
  /// existing player and its host callbacks.
  late final control = TrainerSlideRouteControl._(this);

  Future<void>? _exitFuture;
  bool _disposed = false, _aborted = false;
  int _exitCycle = 0;
  CurvedAnimation? _curve;
  late Animation<Offset> _position;

  @override
  void install() {
    super.install();
    _curve = CurvedAnimation(
      parent: animation!,
      curve: Curves.easeOutCubic,
      // Reverse runs 1 -> 0. Flipping makes the actual rightward displacement
      // easeInCubic(elapsed), rather than its complement.
      reverseCurve: Curves.easeInCubic.flipped,
    );
    _position = Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(_curve!);
    controller!.addStatusListener(_statusChanged);
  }

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  RoutePopDisposition get popDisposition {
    // Leaving before the gate opens must never start or save a session.
    if (!control.entered) return RoutePopDisposition.pop;
    return super.popDisposition;
  }

  void _statusChanged(AnimationStatus status) {
    if (_disposed) return;
    if (status == AnimationStatus.completed && !control.exiting) {
      // Also for a zero-duration route: paint its full poster and chrome once
      // before releasing the SDK gate, never a blank video frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || _aborted || control.exiting) return;
        if (controller!.status != AnimationStatus.completed) return;
        control._entered();
      });
    }
  }

  void _beginExit() {
    if (_disposed || control.exiting) return;
    final cycle = ++_exitCycle;
    control._exiting();
    // A route may remain active with a dismissed controller. Do not pop or
    // dispose the player until its save and completion receipt both succeed.
    _exitFuture = () async {
      try {
        await controller!.reverse().orCancel;
      } on TickerCanceled {
        return;
      }
      if (_disposed || cycle != _exitCycle) return;
      control._retireMedia();
    }();
  }

  Future<void> _beforeExitPop() async {
    _beginExit();
    await _exitFuture;
  }

  void _saveFailed() {
    if (_disposed || !control.exiting) return;
    _exitCycle++;
    _exitFuture = null;
    control._failed();
    // Let the player replace the retained training frame with its existing
    // retry view before sliding that complete view back into sight.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && control.saveFailed && isActive) {
        controller!.forward();
        // Fast failures can reverse then forward at value=1 without a tick.
        changedInternalState();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Cancels entry without opening [TrainerSlideRouteControl.startGate].
  /// The route calls this automatically if the app leaves the foreground
  /// during entry. It never pops another route placed above this one.
  void abortEntrance() {
    if (_disposed || control.entered || _aborted) return;
    _aborted = true;
    if (isCurrent) navigator?.pop();
    controller?.value = 0;
  }

  @override
  bool didPop(T? result) {
    if (!control.entered) {
      _aborted = true;
    } else if (!control.exiting) {
      _beginExit();
    }
    return super.didPop(result);
  }

  @override
  void dispose() {
    _disposed = true;
    controller?.removeStatusListener(_statusChanged);
    control.dispose();
    _curve?.dispose();
    super.dispose();
  }
}

/// Host-visible route state. The player still owns clocks, confirmation,
/// result persistence and the eventual pop.
class TrainerSlideRouteControl extends ChangeNotifier {
  TrainerSlideRouteControl._(this._route);
  final TrainerSlideRoute<dynamic> _route;
  final _gate = Completer<void>();
  bool _hasEntered = false,
      _isExiting = false,
      _mediaRetired = false,
      _saveFailed = false;

  bool get entered => _hasEntered;
  bool get exiting => _isExiting;
  bool get mediaRetired => _mediaRetired;
  bool get saveFailed => _saveFailed;

  /// Opens after the complete entry frame has painted; never opens for an
  /// aborted entry. Pass this to TrainerPlayer.startGate.
  Future<void> get startGate => _gate.future;

  /// Allows host media to stay on its preloaded poster until entry completes,
  /// and to return to that poster after the exit slide.
  bool get canPlay => entered && !mediaRetired;

  /// Starts the exit slide at confirmation, overlapping it with persistence.
  /// Pass this to TrainerPlayer.onExitStarted. Repeated calls are ignored.
  void beginExit() => _route._beginExit();

  /// Waits for the same exit slide without popping. Pass this to the player's
  /// beforeExitPop; the player then pops its receipt after its successful save.
  Future<void> beforeExitPop() => _route._beforeExitPop();

  /// Restores the route when a host save or completion callback fails.
  /// Call this from the callback's catch block, then rethrow for the player's
  /// existing completion/retry view. It leaves media on its poster.
  void exitSaveFailed() => _route._saveFailed();

  /// Resets the host media state for the player's replay flow.
  void replay() {
    _isExiting = false;
    _mediaRetired = false;
    _saveFailed = false;
    notifyListeners();
  }

  void _entered() {
    if (entered) return;
    _hasEntered = true;
    if (!_gate.isCompleted) _gate.complete();
    notifyListeners();
  }

  void _exiting() {
    _isExiting = true;
    _saveFailed = false;
    notifyListeners();
  }

  void _retireMedia() {
    _mediaRetired = true;
    notifyListeners();
  }

  void _failed() {
    _isExiting = false;
    _mediaRetired = true;
    _saveFailed = true;
    notifyListeners();
  }
}

/// Makes a route's control available below its page builder.
class TrainerSlideRouteScope
    extends InheritedNotifier<TrainerSlideRouteControl> {
  const TrainerSlideRouteScope({
    super.key,
    required TrainerSlideRouteControl control,
    required super.child,
  }) : super(notifier: control);

  static TrainerSlideRouteControl? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TrainerSlideRouteScope>()
      ?.notifier;
}

class _TrainerSlideRoutePage extends StatefulWidget {
  const _TrainerSlideRoutePage({required this.route, required this.builder});
  final TrainerSlideRoute<dynamic> route;
  final WidgetBuilder builder;

  @override
  State<_TrainerSlideRoutePage> createState() => _TrainerSlideRoutePageState();
}

class _TrainerSlideRoutePageState extends State<_TrainerSlideRoutePage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !widget.route.control.entered) {
      widget.route.abortEntrance();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme =
        widget.route.trainerTheme ??
        (Theme.of(context).brightness == Brightness.dark
            ? TrainerTheme.dark
            : TrainerTheme.light);
    final dark = theme.isDark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: theme.mediaStage,
        systemNavigationBarColor: theme.mediaStage,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
      child: ColoredBox(
        key: const ValueKey('training-route-background'),
        color: theme.mediaStage,
        child: TrainerSlideRouteScope(
          control: widget.route.control,
          child: ListenableBuilder(
            listenable: widget.route.control,
            child: Builder(builder: widget.builder),
            builder: (_, child) => IgnorePointer(
              ignoring:
                  !widget.route.control.entered || widget.route.control.exiting,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
