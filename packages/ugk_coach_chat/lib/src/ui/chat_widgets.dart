import 'package:flutter/material.dart';

import '../theme/chat_tokens.dart';
import '../theme/chat_theme.dart';
import '../theme/chat_controls.dart';

import 'chat_bubble_adapter.dart';
export 'chat_bubble_adapter.dart';

/// The chips that open a feature (not plan requests) and their glyphs:
/// the shape says what tapping does (§4.3).
const chipGlyphs = <String, ChatGlyph>{
  'Browse moves': ChatGlyph.grid,
  'Moves': ChatGlyph.grid,
  'My last session': ChatGlyph.clock,
  'My plans': ChatGlyph.bookmark,
  'Light mode': ChatGlyph.contrast,
  'Dark mode': ChatGlyph.contrast,
  'What can you do?': ChatGlyph.sparkle,
  'Choose my conditions': ChatGlyph.sliders,
  '看看动作库': ChatGlyph.grid,
  '浏览动作库': ChatGlyph.grid,
  '动作库': ChatGlyph.grid,
  '上次练了什么': ChatGlyph.clock,
  '我的计划': ChatGlyph.bookmark,
  '换浅色': ChatGlyph.contrast,
  '换深色': ChatGlyph.contrast,
  '你能做什么': ChatGlyph.sparkle,
  '自己选条件': ChatGlyph.sliders,
};

/// Quick replies above the input: quiet tonal pills.
class SuggestionStrip extends StatelessWidget {
  const SuggestionStrip({
    super.key,
    required this.items,
    required this.onTap,
    this.glyphFor,
  });
  final List<String> items;
  final void Function(String) onTap;
  final ChatGlyph? Function(String text)? glyphFor;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox(height: ChatSpace.x1);
    return SizedBox(
      height: ChatComposerTokens.suggestionStripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: ChatComposerTokens.suggestionStripPadding,
        itemCount: items.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: ChatComposerTokens.suggestionGap),
        // M6: a new batch arrives chip by chip (40 ms apart), sliding 8 px
        // left as it fades in.
        itemBuilder: (_, i) => Appear(
          key: ValueKey('suggestion-in-${items.join('|')}-$i'),
          animate: true,
          delay: ChatMotion.stagger * i,
          duration: ChatMotion.medium,
          rise: 0,
          shift: 8,
          scaleFrom: 1,
          child: ChatPressable(
            key: ValueKey('suggestion-$i'),
            semanticLabel: items[i],
            haptic: ChatHaptic.selection,
            onTap: () => onTap(items[i]),
            child: Center(
              child: Container(
                height: ChatComposerTokens.suggestionFaceHeight,
                padding: ChatComposerTokens.suggestionPadding,
                decoration: BoxDecoration(
                  color: ChatComposerTokens.of(context).suggestionFill,
                  borderRadius: BorderRadius.circular(
                    ChatComposerTokens.suggestionRadius,
                  ),
                ),
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    ChatComposerTokens.suggestionRadius,
                  ),
                  border: Border.all(
                    color: ChatComposerTokens.of(context).suggestionEdge,
                    width: ChatComposerTokens.suggestionEdgeWidth,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((glyphFor?.call(items[i]) ?? chipGlyphs[items[i]])
                        case final g?) ...[
                      ChatIcon(
                        g,
                        size: ChatComposerTokens.suggestionIconSize,
                        color: ChatComposerTokens.of(context).suggestionIcon,
                      ),
                      const SizedBox(
                        width: ChatComposerTokens.suggestionIconGap,
                      ),
                    ],
                    Text(
                      items[i],
                      style: TextStyle(
                        color: ChatComposerTokens.of(context).suggestionInk,
                        fontSize: ChatComposerTokens.suggestionTextSize,
                        height: ChatComposerTokens.suggestionTextHeight,
                        fontWeight: ChatComposerTokens.suggestionTextWeight,
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
}

/// The capsule at the bottom: plans · text · send. The send disc is the
/// accent only when there is something to send.
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.onSend,
    this.onPlans,
    this.enabled = true,
    this.focusNode,
    this.panelOpen = false,
    this.onTextTap,
    this.hint = '说说想怎么练…',
    this.sendLabel = '发送',
    this.openPanelLabel = '打开功能面板',
    this.closePanelLabel = '收起面板',
  });

  /// Lets an explicit compose action put the cursor here.
  final FocusNode? focusNode;
  final void Function(String) onSend;
  final VoidCallback? onPlans;
  final bool enabled;
  final bool panelOpen;
  final VoidCallback? onTextTap;
  final String hint, sendLabel, openPanelLabel, closePanelLabel;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final _text = TextEditingController();
  final _ownFocus = FocusNode();
  FocusNode get _focus => widget.focusNode ?? _ownFocus;

  @override
  void dispose() {
    _text.dispose();
    _ownFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _text.text.trim();
    if (t.isEmpty || !widget.enabled) return;
    widget.onSend(t);
    _text.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ready = _text.text.trim().isNotEmpty && widget.enabled;
    return Padding(
      padding: ChatComposerTokens.outerPadding,
      child: Container(
        key: const ValueKey('chat-composer-face'),
        decoration: BoxDecoration(
          gradient: ChatComposerTokens.of(context).inputGradient,
          borderRadius: BorderRadius.circular(ChatComposerTokens.inputRadius),
          boxShadow: ChatComposerTokens.of(context).inputShadow,
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ChatComposerTokens.inputRadius),
          border: Border.all(
            color: ChatComposerTokens.of(context).inputEdge,
            width: ChatComposerTokens.edgeWidth,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: ChatComposerTokens.inputHeight,
            ),
            child: Padding(
              padding: ChatComposerTokens.inputInnerPadding,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (widget.onPlans != null)
                    SizedBox(
                      width: ChatComposerTokens.actionWidth,
                      height: ChatComposerTokens.inputHeight,
                      child: ChatPressable(
                        key: const ValueKey('chat-panel-toggle'),
                        tooltip: widget.panelOpen
                            ? widget.closePanelLabel
                            : widget.openPanelLabel,
                        semanticLabel: widget.panelOpen
                            ? widget.closePanelLabel
                            : widget.openPanelLabel,
                        onTap: widget.onPlans,
                        child: Center(
                          child: Icon(
                            widget.panelOpen
                                ? Icons.keyboard_outlined
                                : Icons.grid_view_rounded,
                            size: ChatComposerTokens.bookmarkSize,
                            color: ChatComposerTokens.of(context).bookmark,
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(
                      width: ChatComposerTokens.inputInsetWithoutLeading,
                    ),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('chat-input'),
                      controller: _text,
                      focusNode: _focus,
                      onTap: widget.onTextTap,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      style: TextStyle(
                        color: ChatTheme.of(context).colors.text,
                        fontSize: ChatComposerTokens.inputTextSize,
                        height: ChatComposerTokens.inputTextHeight,
                      ),
                      decoration: InputDecoration(
                        // Keep the whole capsule's input area tappable,
                        // including the space above and below the text.
                        isDense: true,
                        contentPadding: ChatComposerTokens.inputTextPadding,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: widget.hint,
                        hintStyle: TextStyle(
                          color: ChatComposerTokens.of(context).hint,
                          fontSize: ChatComposerTokens.inputTextSize,
                          height: ChatComposerTokens.inputTextHeight,
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  SizedBox(
                    width: ChatComposerTokens.actionWidth,
                    height: ChatComposerTokens.inputHeight,
                    child: Tooltip(
                      message: widget.sendLabel,
                      child: ChatPressable(
                        key: const ValueKey('chat-send'),
                        semanticLabel: widget.sendLabel,
                        onTap: ready ? _submit : null,
                        scale: ChatComposerTokens.pressScale,
                        child: Center(
                          child: Container(
                            width: ChatComposerTokens.sendSize,
                            height: ChatComposerTokens.sendSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: ready
                                  ? ChatTheme.of(context).colors.accent
                                  : ChatComposerTokens.of(
                                      context,
                                    ).inactiveSendFill,
                            ),
                            child: Center(
                              child: ChatIcon(
                                ChatGlyph.arrowUp,
                                size: ChatComposerTokens.sendIconSize,
                                strokeWidth: ChatComposerTokens.sendStrokeWidth,
                                color: ready
                                    ? ChatTheme.of(context).colors.onAccent
                                    : ChatComposerTokens.of(
                                        context,
                                      ).inactiveSendInk,
                              ),
                            ),
                          ),
                        ),
                      ),
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

class ChatPanelAction {
  const ChatPanelAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final Key key;
  final String label;
  final ChatGlyph icon;
  final VoidCallback onTap;
}

/// A content-sized tools grid. Narrow screens and large text add rows instead
/// of keeping the old keyboard-sized empty space.
class ChatFeaturePanel extends StatelessWidget {
  const ChatFeaturePanel({super.key, required this.actions});

  final List<ChatPanelAction> actions;

  /// Fixed for a viewport/text configuration; never measures an animating
  /// panel. The existing grid remains scrollable at accessibility sizes.
  static double heightFor({
    required double width,
    required double viewportHeight,
    required TextScaler textScaler,
    required int actionCount,
  }) {
    final style = ChatType.labelMetrics;
    final scale = textScaler.scale(style.fontSize!) / style.fontSize!;
    final columns =
        ((width - ChatFeaturePanelTokens.padding.horizontal) /
                (ChatFeaturePanelTokens.minTileWidth * scale))
            .floor()
            .clamp(1, ChatFeaturePanelTokens.maxColumns);
    final rows = (actionCount / columns).ceil();
    final labelHeight = textScaler.scale(style.fontSize!) * style.height!;
    final height =
        ChatFeaturePanelTokens.padding.vertical +
        rows *
            (ChatFeaturePanelTokens.tileSize +
                ChatFeaturePanelTokens.labelGap +
                labelHeight) +
        (rows - 1).clamp(0, rows) * ChatFeaturePanelTokens.rowGap;
    return height.clamp(
      0,
      viewportHeight * ChatFeaturePanelTokens.maxHeightFraction,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final labelStyle = ChatType.of(context).label;
    final labelSize = labelStyle.fontSize!;
    final textScale = media.textScaler.scale(labelSize) / labelSize;
    return ColoredBox(
      color: ChatFeaturePanelTokens.of(context).background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth =
              constraints.maxWidth - ChatFeaturePanelTokens.padding.horizontal;
          final columns =
              (contentWidth / (ChatFeaturePanelTokens.minTileWidth * textScale))
                  .floor()
                  .clamp(1, ChatFeaturePanelTokens.maxColumns);
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  media.size.height * ChatFeaturePanelTokens.maxHeightFraction,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: ChatFeaturePanelTokens.padding,
                child: Wrap(
                  runSpacing: ChatFeaturePanelTokens.rowGap,
                  children: [
                    for (final action in actions)
                      SizedBox(
                        width: contentWidth / columns,
                        child: ChatPressable(
                          key: action.key,
                          semanticLabel: action.label,
                          onTap: action.onTap,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: ChatFeaturePanelTokens.tileSize,
                                height: ChatFeaturePanelTokens.tileSize,
                                decoration: BoxDecoration(
                                  color: ChatFeaturePanelTokens.of(
                                    context,
                                  ).tileFill,
                                  borderRadius: BorderRadius.circular(
                                    ChatFeaturePanelTokens.tileRadius,
                                  ),
                                  border: Border.all(
                                    color: ChatFeaturePanelTokens.of(
                                      context,
                                    ).tileEdge,
                                  ),
                                ),
                                child: Center(
                                  child: ChatIcon(
                                    action.icon,
                                    size: ChatFeaturePanelTokens.iconSize,
                                    color: ChatTheme.of(context).colors.text,
                                  ),
                                ),
                              ),
                              const SizedBox(
                                height: ChatFeaturePanelTokens.labelGap,
                              ),
                              Text(
                                action.label,
                                style: labelStyle,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
