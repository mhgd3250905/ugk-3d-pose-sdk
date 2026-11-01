import 'package:flutter/material.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

import '../theme/chat_tokens.dart';

/// The host owns workout receipts and their list placement. SDK bubbles,
/// cards, theme tokens and normal entry primitives stay unchanged. Owning the
/// row slot lets a receipt grow its layout height, avoiding a one-frame jump
/// before its required rise/fade begins.
class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    super.key,
    required this.entries,
    required this.controller,
    required this.timeMarkBuilder,
    this.initiallySeen = const {},
    this.finishedEntries = const {},
    this.topInset = 0,
    this.clock,
  });

  final List<CoachChatEntry> entries;
  final ScrollController controller;
  final Widget Function(DateTime at, DateTime now) timeMarkBuilder;
  final Set<String> initiallySeen, finishedEntries;
  final double topInset;
  final DateTime Function()? clock;
  bool get fadeTop => false;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  late final _seen = {...widget.initiallySeen};

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    final now = widget.clock?.call() ?? DateTime.now();
    final reduced = ChatMotion.reduced(context);
    var replyIndex = 0;
    for (var index = 0; index < widget.entries.length; index++) {
      final entry = widget.entries[index];
      final previous = index == 0 ? null : widget.entries[index - 1];
      final fresh = !_seen.contains(entry.id);
      final timeMark =
          previous == null ||
          entry.at.difference(previous.at) > const Duration(minutes: 45);
      final spacing = previous != null && previous.isUser == entry.isUser
          ? ChatSpace.x2
          : ChatSpace.x4;
      Widget row = Padding(
        padding: EdgeInsets.only(top: spacing),
        child: RepaintBoundary(child: entry.child),
      );
      if (widget.finishedEntries.contains(entry.id)) {
        // Include the margin and optional time mark in the animated layout
        // slot. Leaving either outside would still shift older rows at t=0.
        row = TrainingFinishedEntry(
          animate: fresh,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (timeMark) widget.timeMarkBuilder(entry.at, now),
              row,
            ],
          ),
        );
      } else {
        final delay = fresh && !entry.greeting && !entry.isUser && !reduced
            ? ChatMotion.replyStagger * replyIndex++ +
                  (entry.isCard ? ChatMotion.replyStagger : Duration.zero)
            : Duration.zero;
        row = CoachAppear(
          animate: fresh && (!entry.greeting || !reduced),
          delay: entry.greeting ? Duration.zero : delay,
          anchor: entry.isUser ? Alignment.bottomRight : Alignment.bottomLeft,
          rise: entry.greeting
              ? 16
              : entry.isUser
              ? 8
              : entry.isCard
              ? 14
              : 10,
          scaleFrom: entry.greeting
              ? 1
              : entry.isUser
              ? .96
              : entry.isCard
              ? .97
              : .98,
          duration: entry.greeting
              ? const Duration(milliseconds: 600)
              : entry.isUser
              ? ChatMotion.medium
              : entry.isCard
              ? const Duration(milliseconds: 520)
              : ChatMotion.appear,
          curve: entry.isUser
              ? ChatMotion.enter
              : entry.isCard
              ? ChatMotion.spring
              : ChatMotion.standard,
          child: row,
        );
        if (timeMark) {
          row = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [widget.timeMarkBuilder(entry.at, now), row],
          );
        }
      }
      rows.add(KeyedSubtree(key: ValueKey(entry.id), child: row));
    }
    final reversed = rows.reversed.toList();
    final rowIndices = {
      for (var index = 0; index < reversed.length; index++)
        reversed[index].key!: index,
    };
    final rendered = widget.entries.map((entry) => entry.id).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seen.addAll(rendered);
    });
    return ListView.builder(
      controller: widget.controller,
      reverse: true,
      padding: EdgeInsets.fromLTRB(
        ChatSpace.x4,
        48 + widget.topInset,
        ChatSpace.x4,
        ChatSpace.x3,
      ),
      itemCount: reversed.length,
      itemBuilder: (_, index) => reversed[index],
      findChildIndexCallback: (key) => rowIndices[key],
    );
  }
}

class TrainingFinishedEntry extends StatefulWidget {
  const TrainingFinishedEntry({
    super.key,
    required this.animate,
    required this.child,
  });
  final bool animate;
  final Widget child;

  @override
  State<TrainingFinishedEntry> createState() => _TrainingFinishedEntryState();
}

class _TrainingFinishedEntryState extends State<TrainingFinishedEntry>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _motion = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  bool _started = false, _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (!widget.animate) {
      _controller.value = 1;
    } else {
      _controller.duration = Duration(milliseconds: _reduced ? 150 : 240);
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    key: const ValueKey('training-finished-size'),
    sizeFactor: _motion,
    alignment: Alignment.bottomCenter,
    child: AnimatedBuilder(
      animation: _motion,
      child: widget.child,
      builder: (_, child) => Opacity(
        key: const ValueKey('training-finished-opacity'),
        opacity: _motion.value,
        child: Transform.translate(
          key: const ValueKey('training-finished-position'),
          offset: Offset(0, _reduced ? 0 : 12 * (1 - _motion.value)),
          child: child,
        ),
      ),
    ),
  );
}
