import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/chat_guide_tokens.dart';
import '../theme/chat_theme.dart';
import '../theme/chat_tokens.dart';

/// Serial ownership of the host's existing preview surfaces.
class GuidePreviewCoordinator extends ChangeNotifier {
  String? _activeSlot;
  String? _requestedSlot;
  Future<void> Function()? _retire;
  Future<void> _tail = Future.value();
  int _intent = 0;
  bool _disposed = false;
  String? get activeSlot => _activeSlot;

  Future<void> stop() {
    if (_disposed) return Future.value();
    ++_intent;
    _requestedSlot = null;
    final result = _tail.then((_) => _retireActive());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> _claim(String slot, Future<void> Function() retire) {
    if (_disposed) return Future.value(false);
    _requestedSlot = slot;
    final intent = ++_intent;
    final result = _tail.then((_) async {
      if (_disposed || intent != _intent) return false;
      await _retireActive();
      if (_disposed || intent != _intent) return false;
      _activeSlot = slot;
      _retire = retire;
      notifyListeners();
      return true;
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _retireActive() async {
    final retire = _retire;
    final changed = _activeSlot != null;
    _activeSlot = null;
    _retire = null;
    if (changed && !_disposed) notifyListeners();
    await retire?.call();
  }

  Future<void> release(String slot) =>
      _activeSlot == slot || _requestedSlot == slot ? stop() : Future.value();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_intent;
    _requestedSlot = null;
    final retire = _retire;
    _retire = null;
    _activeSlot = null;
    if (retire != null) unawaited(retire());
    super.dispose();
  }
}

/// Original guide controls around a host-provided runtime media surface.
class GuideMedia extends StatefulWidget {
  const GuideMedia({
    super.key,
    required this.actionId,
    required this.slot,
    required this.coordinator,
    this.enabled = true,
  });
  final String actionId, slot;
  final GuidePreviewCoordinator coordinator;
  final bool enabled;
  @override
  State<GuideMedia> createState() => _GuideMediaState();
}

class _GuideMediaState extends State<GuideMedia> with WidgetsBindingObserver {
  bool _alive = true, _mountedPlayback = false, _requestedPlay = false;
  bool _failed = false;
  int _intent = 0;
  String? _controlPhase;
  Key _controlTransition = UniqueKey();
  ValueListenable<CoachChatPreviewStatus>? _hostStatus;
  Future<void> Function(BuildContext, String)? _retireHost;
  BuildContext? _surfaceContext;
  String? _surfaceAction;
  bool get _current => _alive && mounted && !widget.coordinator._disposed;
  CoachChatPreviewStatus get _status =>
      _hostStatus?.value ?? const CoachChatPreviewStatus();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindStatus();
    if (!TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.isCurrentOf(context) ?? true)) {
      unawaited(widget.coordinator.release(widget.slot));
    }
  }

  void _bindStatus() {
    final status = ChatTheme.of(
      context,
    ).visual.previewStatusFor?.call(widget.actionId);
    if (identical(status, _hostStatus)) return;
    _hostStatus?.removeListener(_changed);
    _hostStatus = status;
    status?.addListener(_changed);
  }

  @override
  void didUpdateWidget(GuideMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actionId != widget.actionId ||
        (oldWidget.enabled && !widget.enabled)) {
      unawaited(widget.coordinator.release(oldWidget.slot));
      _failed = false;
      _bindStatus();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(widget.coordinator.release(widget.slot));
    }
  }

  Future<void> _retire() async {
    ++_intent;
    _mountedPlayback = false;
    _requestedPlay = false;
    if (_current) setState(() {});
    final retire = _retireHost;
    final surfaceContext = _surfaceContext;
    final action = _surfaceAction;
    _surfaceContext = null;
    _surfaceAction = null;
    _retireHost = null;
    if (retire != null && surfaceContext != null && action != null) {
      await retire(surfaceContext, action);
    } else if (_current) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  Future<void> _toggle() async {
    if (!_current || !widget.enabled) return;
    if (_mountedPlayback && !_failed) {
      setState(() => _requestedPlay = !_requestedPlay);
      return;
    }
    final intent = ++_intent;
    setState(() {
      _failed = false;
      _requestedPlay = true;
    });
    final claimed = await widget.coordinator._claim(widget.slot, _retire);
    if (!mounted || !_current || !claimed || intent != _intent) return;
    final visual = ChatTheme.of(context).visual;
    _surfaceContext = context;
    _surfaceAction = widget.actionId;
    _retireHost = visual.retirePreview;
    setState(() => _mountedPlayback = true);
  }

  void _changed() {
    if (!_current) return;
    if (_status.failed && !_failed) {
      _failed = true;
      _requestedPlay = false;
      unawaited(widget.coordinator.release(widget.slot));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '连上网络后可以播放视频',
            style: ChatType.of(
              context,
            ).label.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    setState(() {});
  }

  @override
  void dispose() {
    _alive = false;
    WidgetsBinding.instance.removeObserver(this);
    _hostStatus?.removeListener(_changed);
    unawaited(widget.coordinator.release(widget.slot));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visual = ChatTheme.of(context).visual;
    final canPlay = visual.previewBuilder != null;
    final loading = _status.loading && _requestedPlay;
    final phase = loading
        ? 'loading'
        : _failed
        ? 'offline'
        : _requestedPlay
        ? 'pause'
        : 'play';
    if (_controlPhase != phase) {
      _controlPhase = phase;
      _controlTransition = UniqueKey();
    }
    final stage = Theme.of(context).colorScheme.surfaceContainerHighest;
    final label = _failed
        ? '重试动作示范'
        : _requestedPlay
        ? '暂停动作示范'
        : '播放动作示范';
    final brightness = Theme.of(context).brightness;
    final exercise = visual.exerciseFor?.call(widget.actionId, brightness);
    final asset = exercise?.stillCutout ?? exercise?.poster;
    final poster =
        visual.cutoutFor?.call(widget.actionId, brightness) ??
        (asset == null || asset.isEmpty
            ? null
            : AssetImage(asset, bundle: DefaultAssetBundle.of(context)));
    return GestureDetector(
      key: ValueKey('guide-media-${widget.slot}'),
      behavior: HitTestBehavior.opaque,
      onTap: canPlay ? _toggle : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            key: ValueKey('guide-media-stage-${widget.slot}'),
            color: stage,
            child: Center(
              child: AspectRatio(
                key: ValueKey('guide-media-square-${widget.slot}'),
                aspectRatio: 1,
                child:
                    visual.previewBuilder?.call(
                      context,
                      widget.actionId,
                      _mountedPlayback && _requestedPlay,
                    ) ??
                    (poster == null
                        ? const SizedBox.expand()
                        : Image(image: poster, fit: BoxFit.contain)),
              ),
            ),
          ),
          if (canPlay)
            Positioned(
              top: 8,
              right: 8,
              child: Semantics(
                label: label,
                button: true,
                child: GestureDetector(
                  key: ValueKey('guide-media-control-${widget.slot}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: SizedBox.square(
                    key: ValueKey('article-video-toggle-${widget.slot}'),
                    dimension: 44,
                    child: Center(
                      child: Container(
                        key: ValueKey(
                          'guide-media-control-face-${widget.slot}',
                        ),
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: ChatGuideTokens.previewControlFill(context),
                          boxShadow: ChatGuideTokens.previewControlShadow(
                            context,
                          ),
                        ),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 150),
                            child: KeyedSubtree(
                              key: _controlTransition,
                              child: loading
                                  ? SizedBox.square(
                                      key: ValueKey(
                                        'guide-media-loading-${widget.slot}',
                                      ),
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        value: _status.progress,
                                        strokeWidth: 2,
                                        color: ChatTheme.of(
                                          context,
                                        ).colors.accent,
                                      ),
                                    )
                                  : Icon(
                                      _failed
                                          ? Icons.cloud_off_rounded
                                          : _requestedPlay
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      key: ValueKey(
                                        _failed
                                            ? 'guide-media-offline-${widget.slot}'
                                            : _requestedPlay
                                            ? 'pause'
                                            : 'play',
                                      ),
                                      size: 20,
                                      color: ChatGuideTokens.previewControlInk(
                                        context,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text('此动作暂无视频示范'),
              ),
            ),
        ],
      ),
    );
  }
}
