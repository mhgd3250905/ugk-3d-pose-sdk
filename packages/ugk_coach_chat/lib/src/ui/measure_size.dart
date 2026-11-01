import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Reports layout changes so the conversation clears the input dock.
class ChatMeasureSize extends SingleChildRenderObjectWidget {
  const ChatMeasureSize({super.key, required this.onSize, super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureSize(onSize);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderMeasureSize).onSize = onSize;
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onSize);
  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final measured = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(measured));
  }
}
