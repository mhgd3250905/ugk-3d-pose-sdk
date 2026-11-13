part of 'trainer_player.dart';

extension _TrainerPlayerV1 on _TrainerPlayerState {
  Widget _sessionViewV1(SessionPhase phase, TrainerDrill? drill) {
    final rest =
        phase.kind == PhaseKind.rest || phase.kind == PhaseKind.roundRest;
    final upcoming = rest || phase.kind == PhaseKind.prep;
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

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_th.stageTop, _th.stageBottom],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(left: safe.left, right: safe.right),
        child: Column(
          children: [
            SizedBox(height: math.max(46, safe.top + TrainerSpace.x3)),
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                style: _v1Text(
                                  12,
                                  color: rest ? _th.accent : _th.sub,
                                ),
                              ),
                            ],
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
                    _trackV1(index: index, total: total, rest: rest),
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
                          if (showDiscomfort) ...[
                            const SizedBox(width: TrainerSpace.x2),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 144),
                              child: _discomfortV1(),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                _TrainerChromeLayer.hud,
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      top: TrainerSpace.x4,
                      bottom: TrainerSpace.x3,
                    ),
                    child: _stageV1(phase, drill, rest),
                  ),
                  if (drill != null)
                    Positioned(
                      top:
                          TrainerSpace.x2 -
                          TrainerMediaDownloadIndicator.visualInset,
                      right: TrainerSpace.x5,
                      child: _chromeLayer(
                        _mediaDownloadHud(drill),
                        _TrainerChromeLayer.hud,
                        identity: 'media-download',
                      ),
                    ),
                ],
              ),
            ),
            if (cue != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: cue,
              ),
            TrainerPlayerV1Dock(
              key: const ValueKey('player-v1-dock'),
              theme: _th,
              minHeight: rest ? 300 : 172,
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
          ],
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

  Widget _trackV1({
    required int index,
    required int total,
    required bool rest,
  }) {
    return ValueListenableBuilder<double>(
      valueListenable: _progress,
      builder: (context, elapsed, _) {
        final current = rest ? 1.0 : elapsed;
        Widget segment(double value) => ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: ColoredBox(
            color: _th.track,
            child: FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value,
              child: ColoredBox(color: _th.accent),
            ),
          ),
        );
        return SizedBox(
          key: const ValueKey('progress'),
          height: 4,
          child: total > 24
              ? segment(((index + current) / total).clamp(0.0, 1.0))
              : Row(
                  spacing: 4,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < total; i++)
                      Expanded(
                        child: segment(
                          i < index
                              ? 1
                              : i == index
                              ? current
                              : 0,
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }

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
      media = Opacity(opacity: rest ? .55 : 1, child: media);
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
