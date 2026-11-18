/// Lifecycle of a confirmed newer display asset revision.
enum PoseHubDisplayUpdatePhase { downloading, failed, completed }

/// Download work for a newer catalogue and the display files it needs.
///
/// The initial event has [totalsKnown] false while the catalogue and disk
/// cache are checked. Once true, totals count the catalogue documents and
/// unique content objects that need a network transfer. Cached objects and
/// training assets are excluded.
final class PoseHubDisplayUpdateProgress {
  const PoseHubDisplayUpdateProgress({
    required this.phase,
    required this.version,
    required this.totalFiles,
    required this.completedFiles,
    required this.totalBytes,
    required this.receivedBytes,
    this.totalsKnown = true,
    this.error,
  });

  final PoseHubDisplayUpdatePhase phase;
  final String version;
  final int totalFiles;
  final int completedFiles;
  final int totalBytes;
  final int receivedBytes;
  final bool totalsKnown;
  final String? error;
}
