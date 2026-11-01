import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../theme/chat_theme.dart';

/// Observes the card's actual still requests and warms the player's poster
/// through the host, using the surrounding route-compatible asset bundle.
class TrainingVisiblePosterPreload extends StatefulWidget {
  const TrainingVisiblePosterPreload({
    super.key,
    required this.assetActionIds,
    required this.child,
  });
  final Map<String, String> assetActionIds;
  final Widget child;
  @override
  State<TrainingVisiblePosterPreload> createState() => _VisiblePosterState();
}

class _VisiblePosterState extends State<TrainingVisiblePosterPreload> {
  AssetBundle? _parent, _observed;
  int? _width;

  void _observe() {
    final parent = DefaultAssetBundle.of(context);
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    if (identical(_parent, parent) && _width == width) return;
    _parent = parent;
    _width = width;
    _observed = _VisibleAssetBundle(parent, (asset) {
      if (!mounted) return;
      final actionId = widget.assetActionIds[asset];
      final preload = ChatTheme.of(context).visual.preloadPoster;
      if (actionId == null || preload == null) return;
      // This context sits outside the observing bundle. The preloader cannot
      // recursively observe itself or create a different route cache key.
      unawaited(preload(context, actionId));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _observe();
  }

  @override
  Widget build(BuildContext context) =>
      DefaultAssetBundle(bundle: _observed!, child: widget.child);
}

class _VisibleAssetBundle extends CachingAssetBundle {
  _VisibleAssetBundle(this.parent, this.onLoaded);
  final AssetBundle parent;
  final ValueChanged<String> onLoaded;
  final _seen = <String>{};
  @override
  Future<ByteData> load(String key) async {
    final bytes = await parent.load(key);
    if (_seen.add(key)) onLoaded(key);
    return bytes;
  }
}
