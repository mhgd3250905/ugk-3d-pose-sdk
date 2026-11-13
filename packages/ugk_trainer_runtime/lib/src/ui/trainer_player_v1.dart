part of 'trainer_player.dart';

bool _isPlayerV1Rest(SessionPhase phase) =>
    phase.kind == PhaseKind.rest || phase.kind == PhaseKind.roundRest;

class _PlayerV1Scaffold extends StatefulWidget {
  const _PlayerV1Scaffold({
    super.key,
    required this.theme,
    required this.safe,
    required this.header,
    required this.media,
    required this.mediaStatus,
    required this.cue,
    required this.dock,
    required this.animateEntry,
  });

  final TrainerTheme theme;
  final EdgeInsets safe;
  final Widget header;
  final Widget media;
  final Widget? mediaStatus;
  final Widget cue;
  final Widget dock;
  final bool animateEntry;

  @override
  State<_PlayerV1Scaffold> createState() => _PlayerV1ScaffoldState();
}

class _PlayerV1ScaffoldState extends State<_PlayerV1Scaffold>
    with SingleTickerProviderStateMixin {
  late final _entry = AnimationController(vsync: this);
  bool _entryStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_entryStarted) return;
    _entryStarted = true;
    _entry.duration = !widget.animateEntry
        ? Duration.zero
        : TrainerMotion.reduced(context)
        ? PlayerMotion.reducedFade
        : PlayerMotion.dockDelay + PlayerMotion.slow;
    _entry.forward();
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Widget _appear(Widget child, Duration delay, Duration duration, double dy) {
    final reduced = TrainerMotion.reduced(context);
    return AnimatedBuilder(
      animation: _entry,
      child: child,
      builder: (_, child) {
        final elapsed = _entry.value * (_entry.duration?.inMicroseconds ?? 0);
        final amount = !widget.animateEntry
            ? 1.0
            : reduced
            ? _entry.value
            : PlayerMotion.enter.transform(
                ((elapsed - delay.inMicroseconds) / duration.inMicroseconds)
                    .clamp(0.0, 1.0),
              );
        return Opacity(
          opacity: amount,
          child: reduced
              ? child
              : Transform.translate(
                  offset: Offset(0, (1 - amount) * dy),
                  child: child,
                ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final safe = widget.safe;
    final top = math.max(46.0, safe.top + TrainerSpace.x3);
    final scaler = MediaQuery.textScalerOf(context);
    final headerRow = math.max(
      40.0,
      (scaler.scale(16) + scaler.scale(12)) * 1.3,
    );
    final capsulesBottom = top + headerRow + 12 + 4 + 14 + 36;
    final mediaTop = capsulesBottom + TrainerSpace.x4;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [widget.theme.stageTop, widget.theme.stageBottom],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(left: safe.left, right: safe.right),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The media canvas follows the viewport and insets only. Neither
            // the feedback content nor the dock's animated size can resize it.
            final mediaHeight = math.max(
              0.0,
              constraints.maxHeight -
                  mediaTop -
                  _v1WorkDockHeight -
                  _v1CueHeight -
                  TrainerSpace.x6 -
                  safe.bottom,
            );
            return Stack(
              children: [
                Positioned(
                  top: mediaTop,
                  left: 0,
                  right: 0,
                  height: mediaHeight,
                  child: SizedBox.expand(
                    key: const ValueKey('player-v1-media-viewport'),
                    child: widget.media,
                  ),
                ),
                Positioned(
                  top: top,
                  left: 0,
                  right: 0,
                  child: _appear(
                    widget.header,
                    Duration.zero,
                    PlayerMotion.medium,
                    -PlayerMotion.small,
                  ),
                ),
                if (widget.mediaStatus case final status?)
                  Positioned(
                    top:
                        capsulesBottom +
                        TrainerSpace.x2 -
                        TrainerMediaDownloadIndicator.visualInset,
                    right: TrainerSpace.x5,
                    child: status,
                  ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _appear(
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [widget.cue, widget.dock],
                    ),
                    PlayerMotion.dockDelay,
                    PlayerMotion.slow,
                    PlayerMotion.large,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

const _v1WorkDockHeight = 172.0;
const _v1CueHeight = 64.0;

class _PlayerV1Track extends StatefulWidget {
  const _PlayerV1Track({
    required this.progress,
    required this.index,
    required this.total,
    required this.rest,
    required this.theme,
  });

  final ValueListenable<double> progress;
  final int index;
  final int total;
  final bool rest;
  final TrainerTheme theme;

  @override
  State<_PlayerV1Track> createState() => _PlayerV1TrackState();
}

class _PlayerV1TrackState extends State<_PlayerV1Track>
    with SingleTickerProviderStateMixin {
  late final _fill = AnimationController(
    vsync: this,
    duration: PlayerMotion.trackFill,
    value: 1,
  );
  int? _filling;
  double _from = 0;
  double _lastCurrent = 0;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = TrainerMotion.reduced(context);
  }

  @override
  void didUpdateWidget(_PlayerV1Track oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index && oldWidget.rest == widget.rest) {
      return;
    }
    if (_reduced) {
      _filling = null;
      _fill.value = 1;
    } else if (widget.index > oldWidget.index ||
        widget.rest && !oldWidget.rest) {
      _filling = oldWidget.index;
      _from = _lastCurrent;
      _fill.forward(from: 0);
    } else if (widget.index < oldWidget.index) {
      _filling = null;
      _fill.value = 1;
    }
  }

  @override
  void dispose() {
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('progress'),
    height: 4,
    child: ListenableBuilder(
      listenable: Listenable.merge([widget.progress, _fill]),
      builder: (context, _) {
        final current = widget.rest ? 1.0 : widget.progress.value;
        final amount = PlayerMotion.morph.transform(_fill.value);
        double valueAt(int index) {
          final target = index < widget.index
              ? 1.0
              : index == widget.index
              ? current
              : 0.0;
          if (!_reduced && index == _filling && _fill.isAnimating) {
            return ui.lerpDouble(_from, target, amount)!;
          }
          return target;
        }

        _lastCurrent = valueAt(widget.index);
        Widget segment(double value) => ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: ColoredBox(
            color: widget.theme.track,
            child: FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value,
              child: ColoredBox(color: widget.theme.accent),
            ),
          ),
        );
        if (widget.total > 24) {
          final previous = _filling;
          final elapsed =
              !_reduced &&
                  _fill.isAnimating &&
                  previous != null &&
                  previous < widget.index
              ? widget.index - (1 - valueAt(previous)) + _lastCurrent
              : widget.index + _lastCurrent;
          return segment((elapsed / widget.total).clamp(0.0, 1.0));
        }
        return Row(
          spacing: 4,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < widget.total; i++)
              Expanded(child: segment(valueAt(i))),
          ],
        );
      },
    ),
  );
}

extension _TrainerPlayerV1 on _TrainerPlayerState {
  Widget _sessionViewV1(SessionPhase phase, TrainerDrill? drill) {
    final rest = _isPlayerV1Rest(phase);
    final upcoming = rest || phase.kind == PhaseKind.prep;
    final generation = _engine.generation;
    final manual = _v1NavigationGeneration == generation
        ? _v1NavigationDirection
        : 0;
    final completedPhase = rest ? _lastWorkVisit() : null;
    final displayedPhase = completedPhase ?? phase;
    // The engine points at the next item during a transition rest.
    final index = rest && phase.nextExerciseId != null
        ? math.max(0, phase.itemIndex - 1)
        : phase.itemIndex;
    final total = math.max(1, _occurrences);
    final displayedItem = displayedPhase.item;
    final title = displayedItem == null
        ? drill?.name
        : widget.drillOf(displayedItem.exerciseId)?.name ?? drill?.name;
    final phaseLabel = switch (phase.kind) {
      PhaseKind.prep => _s.prepFirst,
      PhaseKind.rest || PhaseKind.roundRest => _s.restLabel,
      PhaseKind.switchSide => _s.switchTo(phase.side ?? Side.left),
      _ => '',
    };
    final subtitle = [
      if (phase.segment != null) phase.segment!.label ?? drill?.name ?? '',
      _subline(phase, phaseLabel),
    ].where((part) => part.isNotEmpty).join(' · ');
    final next = upcoming ? drill : _nextDrill(phase);
    final steps = drill?.cues.isNotEmpty == true ? drill!.cues : [?drill?.cue];
    final cues = _subtitle == null ? steps : [_subtitle!];
    final safe = MediaQuery.paddingOf(context);
    final controls = _th.copyWith(
      surfaceHigh: _th.ctrl,
      pausedColor: _th.accent,
      onPaused: Colors.white,
      onAccent: Colors.white,
    );
    final cue = cues.isEmpty || upcoming
        ? null
        : _chromeLayer(
            TrainerCueCarousel(
              key: ValueKey('cues-${drill?.id}'),
              cues: cues,
              steps: steps,
              precautions: drill?.precautions ?? const [],
              theme: _th,
              sheetTitle: _s.howTo,
              precautionsTitle: _s.precautions,
              semanticLabel: _s.instructionsLabel,
              closeLabel: _s.closeInstructions,
              onExpandedChanged: _cueSheetChanged,
            ),
            _TrainerChromeLayer.cues,
          );
    final showDiscomfort =
        drill != null && (!upcoming || widget.restFeedbackBuilder == null);

    return _PlayerV1Scaffold(
      key: const ValueKey('player-v1-scaffold'),
      theme: _th,
      safe: safe,
      media: _stageV1(phase, drill, rest, manual),
      animateEntry: widget.chromeAnimation == null,
      mediaStatus: drill == null
          ? null
          : _chromeLayer(
              _mediaDownloadHud(drill),
              _TrainerChromeLayer.hud,
              identity: 'media-download',
            ),
      header: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x5),
            child: _chromeLayer(
              Column(
                children: [
                  Row(
                    children: [
                      _circle(
                        key: const ValueKey('close'),
                        icon: CupertinoIcons.xmark,
                        tooltip: _s.close,
                        size: 40,
                        onPressed: _close,
                        theme: _th.copyWith(surfaceHigh: _th.card),
                      ),
                      const SizedBox(width: TrainerSpace.x3),
                      Expanded(
                        child: TweenAnimationBuilder<Color?>(
                          tween: ColorTween(end: rest ? _th.accent : _th.sub),
                          duration: TrainerMotion.reduced(context)
                              ? PlayerMotion.reducedFade
                              : PlayerMotion.medium,
                          curve: PlayerMotion.morph,
                          builder: (_, color, _) =>
                              TrainerPhaseSwitcher.sequential(
                                key: const ValueKey('player-v1-phase-header'),
                                identity: (title, subtitle),
                                alignment: AlignmentDirectional.centerStart,
                                reserveOutgoingSpace: false,
                                axis: manual == 0
                                    ? Axis.vertical
                                    : Axis.horizontal,
                                enterOffset: manual == 0
                                    ? 4
                                    : manual * PlayerMotion.manualSlide,
                                exitOffset: manual == 0
                                    ? 0
                                    : manual * PlayerMotion.manualSlide,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      title ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _v1Text(16, bold: true),
                                    ),
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _v1Text(12, color: color),
                                    ),
                                  ],
                                ),
                              ),
                        ),
                      ),
                      const SizedBox(width: TrainerSpace.x2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 100),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text.rich(
                            TextSpan(
                              style: _th
                                  .numeral(22)
                                  .copyWith(fontWeight: FontWeight.w700),
                              children: [
                                TextSpan(
                                  text: '${(index + 1).clamp(1, total)}',
                                ),
                                TextSpan(
                                  text: '/$total',
                                  style: _v1Text(13, color: _th.sub),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: TrainerSpace.x3),
                  _PlayerV1Track(
                    progress: _progress,
                    index: index,
                    total: total,
                    rest: rest,
                    theme: _th,
                  ),
                ],
              ),
              _TrainerChromeLayer.info,
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x5),
            child: _chromeLayer(
              TrainerPhaseSwitcher.sequential(
                key: const ValueKey('player-v1-phase-capsules'),
                identity: upcoming,
                alignment: AlignmentDirectional.centerStart,
                child: SizedBox(
                  height: 36,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (upcoming && next != null)
                        Padding(
                          padding: EdgeInsets.only(
                            right: showDiscomfort ? 112 : 0,
                          ),
                          child: _floatingCardV1(
                            padding: const EdgeInsets.symmetric(
                              horizontal: TrainerSpace.x3,
                              vertical: TrainerSpace.x1,
                            ),
                            child: Text(
                              '${_s.upcomingLabel} · ${next.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: _v1Text(12, color: _th.accent, bold: true),
                            ),
                          ),
                        ),
                      Row(
                        key: const ValueKey('top-hud'),
                        children: [
                          Expanded(
                            child: !upcoming && next != null
                                ? _nextCapsuleV1(next)
                                : const SizedBox.shrink(),
                          ),
                          const SizedBox(width: TrainerSpace.x2),
                          if (showDiscomfort)
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 144),
                              child: _discomfortV1(),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              _TrainerChromeLayer.hud,
            ),
          ),
        ],
      ),
      cue: TrainerPhaseSwitcher(
        identity: cue != null,
        enterDuration: PlayerMotion.actionIn,
        enterDelay: widget.restFeedbackBuilder == null
            ? PlayerMotion.ringFade
            : PlayerMotion.phaseCueDelay,
        exitDuration: PlayerMotion.fast,
        enterCurve: PlayerMotion.enter,
        exitCurve: PlayerMotion.exit,
        enterOffset: PlayerMotion.large,
        exitOffset: -PlayerMotion.large,
        child: cue == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: cue,
              ),
      ),
      dock: KeyedSubtree(
        key: _v1Dock,
        child: TrainerPlayerV1Dock(
          key: const ValueKey('player-v1-dock'),
          completionFading: _v1FinalPhase != null,
          theme: _th,
          minHeight: rest ? 300 : _v1WorkDockHeight,
          bottomInset: safe.bottom,
          restFeedback: _restFeedback(phase),
          optionalControls: _hasOptionalControls
              ? _chromeLayer(
                  _optionalControls(phase),
                  _TrainerChromeLayer.transportControls,
                )
              : null,
          countdown: _chromeLayer(
            _digits(phase, _t, template: true),
            _TrainerChromeLayer.transportDigits,
          ),
          previous: _chromeLayer(
            _circle(
              key: const ValueKey('prev'),
              icon: CupertinoIcons.backward_end_fill,
              tooltip: _s.previous,
              onPressed: _previous,
              size: 48,
              theme: controls,
            ),
            _TrainerChromeLayer.previous,
          ),
          primary: _chromeLayer(
            _V1FinishRing(
              active:
                  phase.isWork &&
                  !phase.selfPaced &&
                  !_paused &&
                  _engine.index + 1 < _engine.phases.length &&
                  _engine.phases[_engine.index + 1].kind == PhaseKind.done &&
                  _engine.remainingIn(_t) <= 1,
              accent: _th.accent,
              child: UgkPlayPauseButton(
                key: const ValueKey('pause'),
                isPlaying: _v1FinalPhase != null || !_paused,
                progress: _progress,
                onTap: _togglePause,
                theme: controls,
                strings: _s,
                trackColor: _th.track,
                progressColor: _th.accent,
                size: 64,
                ringSize: 80,
                iconSize: 28,
                ringStrokeWidth: 4,
                ringPhase: generation,
                buttonGlowColor: _th.accent.withValues(alpha: .30),
                remaining: !phase.selfPaced && phase.seconds > 0,
              ),
            ),
            _TrainerChromeLayer.pause,
          ),
          next: _chromeLayer(
            _circle(
              key: const ValueKey('skip'),
              icon: CupertinoIcons.forward_end_fill,
              tooltip: _s.skip,
              onPressed: _skip,
              size: 48,
              theme: controls,
            ),
            _TrainerChromeLayer.next,
          ),
        ),
      ),
    );
  }

  TextStyle _v1Text(double size, {Color? color, bool bold = false}) =>
      TextStyle(
        fontFamily: _th.fontFamily,
        fontSize: size,
        color: color ?? _th.text,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      );

  Widget _floatingCardV1({required Widget child, required EdgeInsets padding}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: _th.card.withValues(alpha: .92),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }

  Widget _nextCapsuleV1(TrainerDrill drill) {
    final poster =
        drill.thumbnailAsset ?? drill.media?.posterFor(light: !_th.isDark);
    final placeholder = Icon(
      CupertinoIcons.forward_end_fill,
      size: 14,
      color: _th.sub,
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: _floatingCardV1(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: SizedBox.square(
                dimension: 28,
                child: TrainerPhaseSwitcher(
                  identity: poster ?? drill.id,
                  enterDuration: PlayerMotion.medium,
                  exitDuration: PlayerMotion.fast,
                  enterDelay: PlayerMotion.fast,
                  enterOffset: 0,
                  exitOffset: 0,
                  exitScale: .9,
                  child: ColoredBox(
                    color: _th.ctrl,
                    child: poster == null
                        ? placeholder
                        : Image.asset(
                            poster,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => placeholder,
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: TrainerSpace.x2),
            Flexible(
              child: Text.rich(
                TextSpan(
                  style: _v1Text(12, color: _th.sub),
                  children: [
                    TextSpan(text: '${_s.nextUp}  '),
                    TextSpan(text: drill.name, style: _v1Text(13, bold: true)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _discomfortV1() => _V1DiscomfortButton(
    label: _s.discomfort,
    onTap: _discomfort,
    theme: _th,
    textStyle: _v1Text(13, color: _th.caution, bold: true),
  );
}

class _V1DiscomfortButton extends StatefulWidget {
  const _V1DiscomfortButton({
    required this.label,
    required this.onTap,
    required this.theme,
    required this.textStyle,
  });

  final String label;
  final VoidCallback onTap;
  final TrainerTheme theme;
  final TextStyle textStyle;

  @override
  State<_V1DiscomfortButton> createState() => _V1DiscomfortButtonState();
}

class _V1DiscomfortButtonState extends State<_V1DiscomfortButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: widget.label,
    onTap: widget.onTap,
    excludeSemantics: true,
    child: SizedBox(
      height: 36,
      child: AnimatedScale(
        scale: _pressed && !TrainerMotion.reduced(context) ? .96 : 1,
        duration: PlayerMotion.fast,
        curve: PlayerMotion.enter,
        child: Material(
          color: widget.theme.cautionBg,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('discomfort'),
            onTap: widget.onTap,
            onHighlightChanged: (value) => setState(() => _pressed = value),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.waveform_path_ecg,
                    size: 16,
                    color: widget.theme.caution,
                  ),
                  const SizedBox(width: TrainerSpace.x1),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: widget.textStyle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

extension _TrainerPlayerV1Stage on _TrainerPlayerState {
  Widget _stageV1(
    SessionPhase phase,
    TrainerDrill? drill,
    bool rest,
    int manual,
  ) {
    final seconds = _engine.secondsLeft(_t);
    final lastKind = _engine.visits.lastOrNull?.phase.kind;
    final starting =
        phase.isWork && lastKind == PhaseKind.prep && _engine.elapsedIn(_t) < 1;
    Widget? media;
    if (drill != null) {
      media = DrillMediaHandoff(
        child: KeyedSubtree(
          key: ValueKey('media-${drill.id}'),
          child: RepaintBoundary(
            key: _mediaHost,
            child: _V1SideTurn(
              switching: phase.kind == PhaseKind.switchSide,
              mirror: phase.side == Side.left,
              builder: (mirror) => _media(
                phase,
                drill,
                _th.copyWith(radius: 0, mediaStage: Colors.transparent),
                mirrored: mirror,
              ),
            ),
          ),
        ),
      );
      if (_th.isDark) {
        media = ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            1.15,
            0,
            0,
            0,
            0,
            0,
            1.15,
            0,
            0,
            0,
            0,
            0,
            1.15,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: media,
        );
      }
      media = AnimatedOpacity(
        opacity: _v1FinalPhase != null
            ? 0
            : rest || phase.kind == PhaseKind.prep
            ? .55
            : 1,
        duration: TrainerMotion.reduced(context)
            ? PlayerMotion.reducedFade
            : _v1FinalPhase != null
            ? PlayerMotion.actionOut
            : rest
            ? PlayerMotion.trackFill
            : phase.kind == PhaseKind.work &&
                  _engine.visits.lastOrNull?.phase.kind == PhaseKind.prep
            ? PlayerMotion.medium
            : PlayerMotion.checkDraw,
        curve: PlayerMotion.enter,
        child: media,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final size = math.min(box.maxWidth, box.maxHeight);
        return Center(
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: .48,
                      colors: [
                        _th.glow.withValues(alpha: _th.isDark ? .16 : .10),
                        _th.glow.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(
                    0,
                    2 * (drill?.floorGeometry?.ground ?? .81) - 1,
                  ),
                  child: Container(
                    width: size * .43,
                    height: size * .06,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.all(
                        Radius.elliptical(size * .215, size * .03),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _th.text.withValues(
                            alpha: _th.isDark ? .08 : .13,
                          ),
                          blurRadius: 14,
                          spreadRadius: -4,
                        ),
                      ],
                    ),
                  ),
                ),
                if (media != null)
                  _V1MediaMotion(
                    action: drill!.id,
                    manual: manual,
                    initialCoverTag: widget.coverHeroTag,
                    initialCoverAsset: widget.coverHeroAsset,
                    poster: drill.media?.posterFor(light: !_th.isDark),
                    mirror: phase.side == Side.left,
                    child: media,
                  ),
                if (starting)
                  _V1StartLabel(theme: _th, label: _s.playerStart)
                else if (phase.kind == PhaseKind.prep && seconds <= 3)
                  _V1PrepMark(
                    key: const ValueKey('player-v1-prep-mark'),
                    label: '$seconds',
                    theme: _th,
                  ),
                if (phase.kind == PhaseKind.switchSide)
                  Align(
                    alignment: Alignment.topCenter,
                    child: _V1SideLabel(
                      label: _s.switchTo(phase.side ?? Side.left),
                      theme: _th,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _V1FinishRing extends StatefulWidget {
  const _V1FinishRing({
    required this.active,
    required this.accent,
    required this.child,
  });

  final bool active;
  final Color accent;
  final Widget child;

  @override
  State<_V1FinishRing> createState() => _V1FinishRingState();
}

class _V1FinishRingState extends State<_V1FinishRing>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.active && _pulse.isDismissed) _start();
  }

  @override
  void didUpdateWidget(_V1FinishRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _start();
    if (!widget.active && oldWidget.active) _pulse.value = 0;
  }

  void _start() {
    _pulse.duration = TrainerMotion.reduced(context)
        ? PlayerMotion.reducedFade
        : PlayerMotion.trackFill;
    _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    clipBehavior: Clip.none,
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, _) => DecoratedBox(
              decoration: ShapeDecoration(
                shape: const CircleBorder(),
                shadows: [
                  BoxShadow(
                    color: widget.accent.withValues(
                      alpha:
                          .6 * math.sin(math.pi * _pulse.value).clamp(0.0, 1.0),
                    ),
                    blurRadius: 12,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      widget.child,
    ],
  );
}

class _V1SideTurn extends StatefulWidget {
  const _V1SideTurn({
    required this.switching,
    required this.mirror,
    required this.builder,
  });

  final bool switching;
  final bool mirror;
  final Widget Function(bool) builder;

  @override
  State<_V1SideTurn> createState() => _V1SideTurnState();
}

class _V1SideTurnState extends State<_V1SideTurn>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: PlayerMotion.sideHalf * 2,
    value: 1,
  );
  bool _previousMirror = false;
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = TrainerMotion.reduced(context);
    if (_reduced) _turn.value = 1;
  }

  @override
  void didUpdateWidget(_V1SideTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mirror != widget.mirror && widget.switching && !_reduced) {
      _previousMirror = _turn.value < .5 ? _previousMirror : oldWidget.mirror;
      _turn.forward(from: 0);
    } else if (!widget.switching && _turn.isAnimating) {
      _turn.value = 1;
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _turn,
    builder: (_, _) {
      final t = _turn.value;
      final before = t < .5;
      final child = widget.builder(before ? _previousMirror : widget.mirror);
      if (_reduced || t == 1) {
        return Opacity(
          opacity: 1,
          child: Transform(transform: Matrix4.identity(), child: child),
        );
      }
      final amount = before
          ? PlayerMotion.exit.transform(t * 2)
          : 1 - PlayerMotion.enter.transform((t - .5) * 2);
      return Opacity(
        opacity: 1 - amount * .6,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, .001)
            ..rotateY((before ? 1 : -1) * amount * math.pi / 2),
          child: child,
        ),
      );
    },
  );
}

class _V1MediaMotion extends StatefulWidget {
  const _V1MediaMotion({
    required this.action,
    required this.manual,
    required this.child,
    required this.initialCoverTag,
    required this.initialCoverAsset,
    required this.poster,
    required this.mirror,
  });

  final String action;
  final int manual;
  final Widget child;
  final String? initialCoverTag;
  final String? initialCoverAsset;
  final String? poster;
  final bool mirror;

  @override
  State<_V1MediaMotion> createState() => _V1MediaMotionState();
}

class _V1MediaMotionState extends State<_V1MediaMotion>
    with TickerProviderStateMixin {
  late final _entrance = AnimationController(vsync: this);
  late final _action = AnimationController(vsync: this, value: 1);
  bool _started = false;
  bool _reduced = false;
  String? _initialAction;
  String? _oldPoster;
  bool _oldMirror = false;
  bool get _cover =>
      _initialAction == widget.action &&
      widget.initialCoverTag != null &&
      widget.initialCoverAsset != null &&
      !_reduced;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = TrainerMotion.reduced(context);
    if (_started) return;
    _started = true;
    _initialAction = widget.action;
    _entrance.duration = _reduced
        ? PlayerMotion.reducedFade
        : _cover
        ? PlayerMotion.heroFlight + PlayerMotion.medium
        : PlayerMotion.medium;
    _entrance.forward();
  }

  @override
  void didUpdateWidget(_V1MediaMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.action == widget.action) return;
    _oldPoster = oldWidget.poster;
    _oldMirror = oldWidget.mirror;
    _action.duration = _reduced
        ? PlayerMotion.reducedFade
        : PlayerMotion.dockDelay + PlayerMotion.actionIn;
    _action.forward(from: 0);
  }

  @override
  void dispose() {
    _action.dispose();
    _entrance.dispose();
    super.dispose();
  }

  Widget _poster(String asset, bool mirrored) =>
      TrainerPoster(asset: asset, mirrored: mirrored);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_entrance, _action]),
    child: widget.child,
    builder: (_, child) {
      final motion = _action.value;
      final elapsed = motion * (_action.duration?.inMicroseconds ?? 0);
      final changed = motion < 1;
      final old = changed
          ? _reduced
                ? motion
                : (elapsed / PlayerMotion.actionOut.inMicroseconds).clamp(
                    0.0,
                    1.0,
                  )
          : 1.0;
      final incoming = !changed
          ? 1.0
          : _reduced
          ? motion
          : ((elapsed - PlayerMotion.dockDelay.inMicroseconds) /
                    PlayerMotion.actionIn.inMicroseconds)
                .clamp(0.0, 1.0);
      final entryElapsed =
          _entrance.value * (_entrance.duration?.inMicroseconds ?? 0);
      final entry = _cover
          ? ((entryElapsed - PlayerMotion.heroFlight.inMicroseconds) /
                    PlayerMotion.medium.inMicroseconds)
                .clamp(0.0, 1.0)
          : _entrance.value;
      final out = _reduced ? old : PlayerMotion.exit.transform(old);
      final enter = _reduced
          ? incoming
          : PlayerMotion.enter.transform(incoming);
      final dx = widget.manual < 0 ? -PlayerMotion.large : PlayerMotion.large;
      Widget frame(double opacity, double offset, Widget child) => Opacity(
        opacity: opacity,
        child: _reduced
            ? child
            : Transform.translate(offset: Offset(offset, 0), child: child),
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_oldPoster case final String asset when changed)
            IgnorePointer(
              child: frame(1 - out, -dx * out, _poster(asset, _oldMirror)),
            ),
          frame(enter * entry, dx * (1 - enter), child!),
          if (_cover && entry < 1)
            IgnorePointer(
              child: Opacity(
                opacity: 1 - PlayerMotion.enter.transform(entry),
                child: Hero(
                  tag: widget.initialCoverTag!,
                  child: _poster(widget.initialCoverAsset!, false),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _V1PrepMark extends StatelessWidget {
  const _V1PrepMark({super.key, required this.label, required this.theme});

  final String label;
  final TrainerTheme theme;

  @override
  Widget build(BuildContext context) {
    final reduced = TrainerMotion.reduced(context);
    const hold = PlayerMotion.prepHold;
    return IgnorePointer(
      child: Center(
        child: TweenAnimationBuilder<double>(
          key: ValueKey(label),
          tween: Tween(begin: 0, end: 1),
          duration: reduced
              ? PlayerMotion.reducedFade
              : hold + PlayerMotion.fast,
          child: Text(
            label,
            style: theme.numeral(64).copyWith(fontWeight: FontWeight.w700),
          ),
          builder: (_, t, child) {
            final elapsed = t * (hold + PlayerMotion.fast).inMilliseconds;
            final inAmount = reduced
                ? t
                : PlayerMotion.enter.transform(
                    (elapsed / PlayerMotion.prepEnter.inMilliseconds).clamp(
                      0.0,
                      1.0,
                    ),
                  );
            final out = reduced
                ? 0.0
                : ((elapsed - hold.inMilliseconds) /
                          PlayerMotion.fast.inMilliseconds)
                      .clamp(0.0, 1.0);
            return Opacity(
              opacity: inAmount * (1 - out),
              child: reduced
                  ? child
                  : Transform.scale(scale: 1.3 - .3 * inAmount, child: child),
            );
          },
        ),
      ),
    );
  }
}

class _V1StartLabel extends StatelessWidget {
  const _V1StartLabel({required this.theme, required this.label});

  final TrainerTheme theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    final reduced = TrainerMotion.reduced(context);
    final fade = reduced ? PlayerMotion.reducedFade : PlayerMotion.fast;
    final total = fade * 2 + PlayerMotion.medium;
    return IgnorePointer(
      child: Center(
        child: TweenAnimationBuilder<double>(
          duration: total,
          tween: Tween(begin: 0, end: 1),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .92),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .1),
                  offset: const Offset(0, 4),
                  blurRadius: 16,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              child: Text(
                label,
                key: const ValueKey('player-v1-start-label'),
                style: theme
                    .numeral(28, color: theme.accent)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          builder: (_, value, child) {
            final elapsed = value * total.inMicroseconds;
            final entered = PlayerMotion.enter.transform(
              (elapsed / fade.inMicroseconds).clamp(0.0, 1.0),
            );
            final exited = PlayerMotion.exit.transform(
              ((elapsed -
                          fade.inMicroseconds -
                          PlayerMotion.medium.inMicroseconds) /
                      fade.inMicroseconds)
                  .clamp(0.0, 1.0),
            );
            return Opacity(
              opacity: entered * (1 - exited),
              child: reduced
                  ? child
                  : Transform.scale(scale: .9 + .1 * entered, child: child),
            );
          },
        ),
      ),
    );
  }
}

class _V1SideLabel extends StatelessWidget {
  const _V1SideLabel({required this.label, required this.theme});

  final String label;
  final TrainerTheme theme;

  @override
  Widget build(BuildContext context) {
    final reduced = TrainerMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: PlayerMotion.fast * 2 + PlayerMotion.sideHold,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: theme.accent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.label.copyWith(
                fontSize: 13,
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      builder: (_, t, child) {
        final fade = reduced ? PlayerMotion.reducedFade : PlayerMotion.fast;
        final elapsed =
            t * (PlayerMotion.fast * 2 + PlayerMotion.sideHold).inMilliseconds;
        final enter = (elapsed / fade.inMilliseconds).clamp(0.0, 1.0);
        final exit =
            ((elapsed -
                        PlayerMotion.fast.inMilliseconds -
                        PlayerMotion.sideHold.inMilliseconds) /
                    fade.inMilliseconds)
                .clamp(0.0, 1.0);
        return Opacity(opacity: enter * (1 - exit), child: child);
      },
    );
  }
}
