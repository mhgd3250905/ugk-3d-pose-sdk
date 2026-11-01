import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'training_transition_activity.dart';

/// Keeps the source route's real retained layer and scroll position. Updates
/// remain in the model and are rendered once after the short transition ends.
class TrainingTransitionFreeze extends StatefulWidget {
  const TrainingTransitionFreeze({
    super.key,
    required this.listenable,
    required this.builder,
    required this.activity,
    this.pauseTickers = true,
  });
  final Listenable listenable;
  final WidgetBuilder builder;
  final TrainingTransitionActivity activity;
  final bool pauseTickers;
  @override
  State<TrainingTransitionFreeze> createState() =>
      _TrainingTransitionFreezeState();
}

class _TrainingTransitionFreezeState extends State<TrainingTransitionFreeze> {
  TrainingTransitionActivity get _activity => widget.activity;
  Widget? _child;
  var _dirty = true;
  var _frozen = false;

  @override
  void initState() {
    super.initState();
    _frozen = _activity.active;
    widget.listenable.addListener(_dataChanged);
    _activity.addListener(_activityChanged);
  }

  void _dataChanged() {
    _dirty = true;
    if (!_activity.active) setState(() {});
  }

  void _activityChanged() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _activityChanged();
      });
      return;
    }
    if (_frozen == _activity.active) return;
    setState(() => _frozen = _activity.active);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_activity.active || _child == null) _dirty = true;
  }

  @override
  void didUpdateWidget(TrainingTransitionFreeze oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.activity, widget.activity)) {
      oldWidget.activity.removeListener(_activityChanged);
      widget.activity.addListener(_activityChanged);
      _frozen = widget.activity.active;
    }
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_dataChanged);
      widget.listenable.addListener(_dataChanged);
    }
    if (!_activity.active) _dirty = true;
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_dataChanged);
    _activity.removeListener(_activityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_child == null || (_dirty && !_frozen)) {
      _dirty = false;
      _child = RepaintBoundary(child: Builder(builder: widget.builder));
    }
    return TickerMode(
      enabled: !widget.pauseTickers || !_frozen,
      child: _child!,
    );
  }
}
