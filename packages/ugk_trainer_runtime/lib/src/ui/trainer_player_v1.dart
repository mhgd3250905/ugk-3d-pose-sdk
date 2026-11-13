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
  });

  final TrainerTheme theme;
  final EdgeInsets safe;
  final Widget header;
  final Widget media;
  final Widget? mediaStatus;
  final Widget cue;
  final Widget dock;

  @override
  State<_PlayerV1Scaffold> createState() => _PlayerV1ScaffoldState();
}

class _PlayerV1ScaffoldState extends State<_PlayerV1Scaffold> {
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
                Positioned(top: top, left: 0, right: 0, child: widget.header),
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [widget.cue, widget.dock],
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
    duration: const Duration(milliseconds: 300),
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
        final amount = Curves.easeInOutCubic.transform(_fill.value);
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
      media: _stageV1(phase, drill, rest),
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
                              ? const Duration(milliseconds: 150)
                              : const Duration(milliseconds: 240),
                          curve: Curves.easeInOutCubic,
                          builder: (_, color, _) => TrainerPhaseSwitcher(
                            identity: (title, subtitle),
                            alignment: AlignmentDirectional.centerStart,
                            reserveOutgoingSpace: false,
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
              SizedBox(
                height: 36,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    TrainerPhaseSwitcher(
                      identity: upcoming && next != null,
                      enterDuration: const Duration(milliseconds: 220),
                      exitDuration: const Duration(milliseconds: 160),
                      enterOffset: -6,
                      exitOffset: 0,
                      enterScale: .96,
                      exitScale: .96,
                      child: upcoming && next != null
                          ? Padding(
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
                                  style: _v1Text(
                                    12,
                                    color: _th.accent,
                                    bold: true,
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    Row(
                      key: const ValueKey('top-hud'),
                      children: [
                        Expanded(
                          child: TrainerPhaseSwitcher(
                            identity: !upcoming && next != null,
                            alignment: Alignment.centerLeft,
                            enterDuration: const Duration(milliseconds: 220),
                            exitDuration: const Duration(milliseconds: 160),
                            enterDelay: const Duration(milliseconds: 160),
                            enterOffset: -6,
                            exitOffset: 6,
                            child: !upcoming && next != null
                                ? _nextCapsuleV1(next)
                                : const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(width: TrainerSpace.x2),
                        TrainerPhaseSwitcher(
                          identity: showDiscomfort,
                          alignment: Alignment.centerRight,
                          enterDuration: const Duration(milliseconds: 220),
                          exitDuration: const Duration(milliseconds: 160),
                          enterDelay: const Duration(milliseconds: 220),
                          enterOffset: -6,
                          exitOffset: 6,
                          child: showDiscomfort
                              ? ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 144,
                                  ),
                                  child: _discomfortV1(),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _TrainerChromeLayer.hud,
            ),
          ),
        ],
      ),
      cue: TrainerPhaseSwitcher(
        identity: cue != null,
        enterDuration: const Duration(milliseconds: 280),
        enterDelay: Duration(
          milliseconds: widget.restFeedbackBuilder == null ? 120 : 200,
        ),
        exitDuration: const Duration(milliseconds: 160),
        enterCurve: Curves.easeOutCubic,
        exitCurve: Curves.easeIn,
        enterOffset: 16,
        exitOffset: -16,
        child: cue == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: cue,
              ),
      ),
      dock: TrainerPlayerV1Dock(
        key: const ValueKey('player-v1-dock'),
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
          TrainerPhaseSwitcher(
            identity: generation,
            enterOffset: 12,
            exitOffset: 12,
            child: _digits(phase, _t, template: true),
          ),
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
          UgkPlayPauseButton(
            key: const ValueKey('pause'),
            isPlaying: !_paused,
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

  Widget _discomfortV1() => Semantics(
    button: true,
    label: _s.discomfort,
    onTap: _discomfort,
    excludeSemantics: true,
    child: SizedBox(
      height: 36,
      child: Material(
        color: _th.cautionBg,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('discomfort'),
          onTap: _discomfort,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.waveform_path_ecg,
                  size: 16,
                  color: _th.caution,
                ),
                const SizedBox(width: TrainerSpace.x1),
                Flexible(
                  child: Text(
                    _s.discomfort,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _v1Text(13, color: _th.caution, bold: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _stageV1(SessionPhase phase, TrainerDrill? drill, bool rest) {
    Widget? media;
    if (drill != null) {
      media = DrillMediaHandoff(
        child: KeyedSubtree(
          key: ValueKey('media-${drill.id}'),
          child: RepaintBoundary(
            key: _mediaHost,
            child: _media(
              phase,
              drill,
              _th.copyWith(radius: 0, mediaStage: Colors.transparent),
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
        opacity: rest ? .55 : 1,
        duration: Duration(
          milliseconds: TrainerMotion.reduced(context)
              ? 150
              : rest
              ? 300
              : 400,
        ),
        curve: Curves.easeOut,
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
                ?media,
              ],
            ),
          ),
        );
      },
    );
  }
}
