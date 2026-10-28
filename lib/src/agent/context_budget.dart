/// Byte budgets and content-free diagnostics for model context preparation.
library;

class ContextBudgetConfig {
  const ContextBudgetConfig({
    this.softOffBytes = 40960,
    this.softOnBytes = 51200,
    this.hardBytes = 65536,
  }) : assert(softOffBytes > 0),
       assert(softOnBytes > 0),
       assert(hardBytes >= softOffBytes),
       assert(hardBytes >= softOnBytes);

  final int softOffBytes;
  final int softOnBytes;
  final int hardBytes;

  int softLimit({required bool thinking}) =>
      thinking ? softOnBytes : softOffBytes;

  Map<String, Object?> toJson() => {
    'softOffBytes': softOffBytes,
    'softOnBytes': softOnBytes,
    'hardBytes': hardBytes,
  };
}

/// Measurements only: this record contains no messages, reasoning or secrets.
class ContextRequestDiagnostics {
  const ContextRequestDiagnostics({
    required this.epoch,
    required this.beforeBytes,
    required this.afterBytes,
    required this.softLimitBytes,
    required this.hardLimitBytes,
    required this.tailStateBytes,
    required this.completedTurnsFolded,
    required this.receiptBodiesFolded,
    required this.measurement,
    required this.fitsHardLimit,
  });

  final int epoch;
  final int beforeBytes;
  final int afterBytes;
  final int softLimitBytes;
  final int hardLimitBytes;

  /// UTF-8 bytes of the serialized trailing state message, including its role.
  /// Provider cache token measurements remain separate from this byte count.
  final int tailStateBytes;
  final int completedTurnsFolded;
  final int receiptBodiesFolded;
  final String measurement;
  final bool fitsHardLimit;

  bool get folded => completedTurnsFolded > 0 || receiptBodiesFolded > 0;

  Map<String, Object?> toJson() => {
    'epoch': epoch,
    'beforeBytes': beforeBytes,
    'afterBytes': afterBytes,
    'softLimitBytes': softLimitBytes,
    'hardLimitBytes': hardLimitBytes,
    'tailStateBytes': tailStateBytes,
    'completedTurnsFolded': completedTurnsFolded,
    'receiptBodiesFolded': receiptBodiesFolded,
    'folded': folded,
    'measurement': measurement,
    'fitsHardLimit': fitsHardLimit,
  };
}
