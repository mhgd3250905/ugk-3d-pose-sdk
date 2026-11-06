import 'package:path_provider/path_provider.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../voice/catalog_voice_source.dart';
import '../voice/voice_source.dart';
import 'pose_hub_action_library.dart';

/// The app's own voice ([primary]) with the active Pose-Hub catalogue's
/// recorded lines (name / primaryCue) behind it, downloaded on demand into a
/// verified cache under the app support directory. Pass the result as
/// [TrainerVoice.source]; the player prefetches the plan's lines when a
/// session starts and never waits on them.
///
/// [catalog] defaults to [PoseHubActionLibrary.load] (verified hot-update
/// cache, then the bundled baseline). Any failure (no file system on web,
/// unreadable catalogue) returns [primary] unchanged.
Future<VoiceSource> withPoseHubCatalogVoice(
  VoiceSource primary, {
  PoseHubAppTestCatalog? catalog,
  String? cacheDirectory,
}) async {
  try {
    final c = catalog ?? await PoseHubActionLibrary.load();
    final dir =
        cacheDirectory ??
        '${(await getApplicationSupportDirectory()).path}/ugk_catalog_voice';
    return LayeredVoiceSource(
      primary: primary,
      catalog: CatalogVoiceIndex.fromCatalogJson(
        c.raw,
        baseUrl: PoseHubActionLibrary.mediaBaseUriFor(c),
      ),
      cache: CatalogVoiceCache.files(dir),
    );
  } catch (_) {
    return primary;
  }
}
