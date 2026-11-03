import 'package:flutter/material.dart';
import 'primitives.dart';
import 'theme.dart';

/// An immutable row description; the host provides admitted content widgets.
@immutable
class CoachChatEntry {
  const CoachChatEntry({
    required this.id,
    required this.at,
    required this.isUser,
    required this.child,
    this.isCard = false,
    this.greeting = false,
  });
  final String id;
  final DateTime at;
  final bool isUser, isCard, greeting;
  final Widget child;
}

/// Reverse conversation viewport with stable row keys and established reply
/// choreography. Scroll controller ownership stays with its caller.
class CoachChatList extends StatefulWidget {
  const CoachChatList({
    super.key,
    required this.entries,
    required this.controller,
    required this.timeMarkBuilder,
    this.dockHeight = 112,
    this.topInset = 0,
    this.fadeTop = true,
    this.typing,
    this.initiallySeen = const {},
    this.anchorTopWhenShort = false,
    this.emptyBuilder,
  });
  final List<CoachChatEntry> entries;
  final ScrollController controller;
  final Widget Function(DateTime at, DateTime now) timeMarkBuilder;
  final double dockHeight;

  /// Host-supplied safe inset added inside the scrollable content. The viewport
  /// stays full height so rows can scroll behind transparent system chrome.
  final double topInset;

  /// Keep the established 48 px top fade, or let content paint unobscured to
  /// the viewport edge. The host owns system-bar styling and safe-area policy.
  final bool fadeTop;
  final Widget? typing;
  final Set<String> initiallySeen;

  /// When the rows are shorter than the viewport, start them under the top
  /// inset instead of resting on the dock (the reverse list's default).
  /// Long conversations scroll exactly as before. Default false.
  final bool anchorTopWhenShort;

  /// Shown, top-anchored inside the same insets, when there are no entries
  /// and no typing row. Null (default) keeps the empty list.
  final WidgetBuilder? emptyBuilder;
  @override
  State<CoachChatList> createState() => _CoachChatListState();
}

class _CoachChatListState extends State<CoachChatList> {
  late final _seen = <String>{...widget.initiallySeen};
  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    final now = DateTime.now();
    final still = CoachMotion.reduced(context);
    var queued = 0;
    for (var i = 0; i < widget.entries.length; i++) {
      final m = widget.entries[i];
      final prev = i == 0 ? null : widget.entries[i - 1];
      if (prev == null ||
          m.at.difference(prev.at) > const Duration(minutes: 45)) {
        rows.add(widget.timeMarkBuilder(m.at, now));
      }
      final fresh = !_seen.contains(m.id);
      final sameSide = prev != null && prev.isUser == m.isUser;
      rows.add(
        Padding(
          key: ValueKey(m.id),
          padding: EdgeInsets.only(
            top: sameSide ? CoachSpace.x2 : CoachSpace.x4,
          ),
          child: m.greeting
              ? CoachAppear(
                  animate: fresh && !still,
                  duration: const Duration(milliseconds: 600),
                  rise: 16,
                  scaleFrom: 1,
                  child: m.child,
                )
              : CoachAppear(
                  animate: fresh,
                  delay: fresh && !m.isUser && !still
                      ? CoachMotion.replyStagger * queued++ +
                            (m.isCard
                                ? CoachMotion.replyStagger
                                : Duration.zero)
                      : Duration.zero,
                  anchor: m.isUser
                      ? Alignment.bottomRight
                      : Alignment.bottomLeft,
                  rise: m.isUser ? 8 : (m.isCard ? 14 : 10),
                  scaleFrom: m.isUser ? .96 : (m.isCard ? .97 : .98),
                  duration: m.isUser
                      ? CoachMotion.medium
                      : (m.isCard
                            ? const Duration(milliseconds: 520)
                            : CoachMotion.appear),
                  curve: m.isUser
                      ? CoachMotion.enter
                      : (m.isCard ? CoachMotion.spring : CoachMotion.standard),
                  child: RepaintBoundary(child: m.child),
                ),
        ),
      );
    }
    if (widget.typing case final typing?) {
      rows.add(
        Padding(
          key: const ValueKey('typing'),
          padding: const EdgeInsets.only(top: CoachSpace.x4),
          child: typing,
        ),
      );
    }
    final reversed = rows.reversed.toList();
    final renderedIds = widget.entries.map((m) => m.id).toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seen.addAll(renderedIds);
    });
    final padding = EdgeInsets.fromLTRB(
      CoachSpace.x4,
      48 + widget.topInset,
      CoachSpace.x4,
      widget.dockHeight + CoachSpace.x3,
    );
    final empty = widget.emptyBuilder;
    final Widget list;
    if (rows.isEmpty && empty != null) {
      list = ListView(
        key: const ValueKey('coach-chat-list-empty'),
        controller: widget.controller,
        padding: padding,
        children: [Builder(builder: empty)],
      );
    } else {
      final view = ListView.builder(
        controller: widget.controller,
        reverse: true,
        shrinkWrap: widget.anchorTopWhenShort,
        padding: padding,
        itemCount: reversed.length,
        itemBuilder: (_, i) => reversed[i],
        findChildIndexCallback: (key) {
          final i = reversed.indexWhere((w) => w.key == key);
          return i < 0 ? null : i;
        },
      );
      list = widget.anchorTopWhenShort
          ? Align(alignment: Alignment.topCenter, child: view)
          : view;
    }
    return Stack(
      children: [
        list,
        if (widget.fadeTop)
          IgnorePointer(
            child: SizedBox(
              height: 48,
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      CoachUiTheme.of(context).colors.background,
                      CoachUiTheme.of(
                        context,
                      ).colors.background.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
