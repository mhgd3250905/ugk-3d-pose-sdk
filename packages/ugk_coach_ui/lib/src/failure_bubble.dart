import 'package:flutter/material.dart';

import 'message_widgets.dart';
import 'primitives.dart';
import 'theme.dart';

/// Presents a failure returned by the host. No retry happens automatically.
class CoachFailureBubble extends StatefulWidget {
  const CoachFailureBubble({
    super.key,
    this.message = '网络不太稳，方案没生成出来',
    this.retryLabel = '重试',
    this.onRetry,
    this.secondaryLabel = '用预设方案',
    this.onSecondary,
    this.presetMatchesFocus = false,
    this.enabled = true,
  });

  final String message;
  final String retryLabel;
  final Future<void> Function()? onRetry;
  final String? secondaryLabel;
  final Future<void> Function()? onSecondary;

  /// Host has verified that the preset matches the current request's focus.
  final bool presetMatchesFocus;
  final bool enabled;

  @override
  State<CoachFailureBubble> createState() => _CoachFailureBubbleState();
}

class _CoachFailureBubbleState extends State<CoachFailureBubble> {
  bool _submitting = false;

  Future<void> _run(Future<void> Function() action) async {
    if (!widget.enabled || _submitting) return;
    setState(() => _submitting = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final enabled = widget.enabled && !_submitting;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .86,
        ),
        child: DecoratedBox(
          key: const ValueKey('coach-failure-bubble'),
          decoration: BoxDecoration(
            color: style.colors.assistantBubble.withValues(alpha: 1),
            borderRadius: bubbleRadius(user: false),
            border: Border.all(color: style.colors.outline),
            boxShadow: [
              BoxShadow(
                color: style.colors.shadow,
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.message,
                  style: style.typography.body.copyWith(
                    color: style.colors.text,
                  ),
                ),
                if (widget.onRetry != null ||
                    (widget.presetMatchesFocus &&
                        widget.onSecondary != null &&
                        widget.secondaryLabel != null)) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      if (widget.onRetry case final retry?)
                        CoachTextAction(
                          key: const ValueKey('coach-failure-retry'),
                          label: widget.retryLabel,
                          onPressed: enabled ? () => _run(retry) : null,
                        ),
                      if (widget.presetMatchesFocus)
                        if (widget.onSecondary case final secondary?)
                          if (widget.secondaryLabel case final label?)
                            CoachTextAction(
                              key: const ValueKey('coach-failure-secondary'),
                              label: label,
                              onPressed: enabled ? () => _run(secondary) : null,
                            ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
