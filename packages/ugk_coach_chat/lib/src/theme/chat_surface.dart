import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_tokens.dart';
import 'chat_theme.dart';

enum ChatSurfaceLevel { base, card, raised }

/// An opaque painted surface; the layout and interaction remain child-owned.
class ChatSolidSurface extends StatelessWidget {
  const ChatSolidSurface({
    super.key,
    required this.child,
    this.level = ChatSurfaceLevel.card,
    this.radius,
    this.padding,
    this.width,
    this.height,
    this.control = false,
  });

  final Widget child;
  final ChatSurfaceLevel level;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final bool control;

  @override
  Widget build(BuildContext context) {
    final fill = switch (level) {
      ChatSurfaceLevel.base => ChatTheme.of(context).colors.surfaceLow,
      ChatSurfaceLevel.card => ChatTheme.of(context).colors.surface,
      ChatSurfaceLevel.raised => ChatTheme.of(context).colors.surfaceHigh,
    };
    return Container(
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius ?? 999),
        boxShadow: level == ChatSurfaceLevel.card && !control
            ? ChatTheme.of(context).colors.cardShadow
            : null,
      ),
      // Paint the edge without introducing implicit padding or moving hitboxes.
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius ?? 999),
        border: Border.all(color: ChatTheme.of(context).colors.line),
      ),
      child: child,
    );
  }
}

OverlayEntry? _solidToastEntry;

void showChatSolidToast(
  BuildContext context,
  String text, {
  required Widget icon,
  double bottom = 112,
}) => showChatToast(context, text, icon: icon, bottom: bottom);

void showChatToast(
  BuildContext context,
  String text, {
  required Widget icon,
  double bottom = 112,
}) {
  _solidToastEntry?.remove();
  _solidToastEntry = null;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _SolidToastHost(
      text: text,
      icon: icon,
      bottom: bottom,
      onDone: () {
        if (_solidToastEntry == entry) {
          _solidToastEntry = null;
          entry.remove();
        }
      },
      onDisposed: () {
        if (_solidToastEntry == entry) _solidToastEntry = null;
      },
    ),
  );
  _solidToastEntry = entry;
  overlay.insert(entry);
}

class _SolidToastHost extends StatefulWidget {
  const _SolidToastHost({
    required this.text,
    required this.icon,
    required this.bottom,
    required this.onDone,
    required this.onDisposed,
  });

  final String text;
  final Widget icon;
  final double bottom;
  final VoidCallback onDone, onDisposed;

  @override
  State<_SolidToastHost> createState() => _SolidToastHostState();
}

class _SolidToastHostState extends State<_SolidToastHost> {
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _hold = Timer(const Duration(seconds: 2), widget.onDone);
  }

  @override
  void dispose() {
    _hold?.cancel();
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset =
        MediaQuery.viewPaddingOf(context).bottom +
        MediaQuery.viewInsetsOf(context).bottom;
    return Positioned(
      left: 24,
      right: 24,
      bottom: widget.bottom + inset,
      // Informational feedback must not swallow a tap on the plan's start
      // button or another control underneath it.
      child: IgnorePointer(
        child: Semantics(
          liveRegion: true,
          child: Material(
            type: MaterialType.transparency,
            child: ChatSolidSurface(
              level: ChatSurfaceLevel.raised,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  widget.icon,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.text,
                      style: ChatType.of(context).callout,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
