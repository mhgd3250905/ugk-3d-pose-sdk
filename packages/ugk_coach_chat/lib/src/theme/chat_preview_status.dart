/// The current state reported by the host's existing media implementation.
class CoachChatPreviewStatus {
  const CoachChatPreviewStatus({
    this.loading = false,
    this.failed = false,
    this.revealed = true,
    this.progress,
  });

  final bool loading, failed, revealed;
  final double? progress;
}
