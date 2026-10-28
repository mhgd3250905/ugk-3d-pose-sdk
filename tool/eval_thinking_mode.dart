/// Explicit protocol configuration for future thinking on/off evaluations.
library;

enum EvaluationThinkingMode {
  on,
  off;

  String get protocolType => this == on ? 'enabled' : 'disabled';
  Map<String, Object?> get extraBody => {
    'thinking': {'type': protocolType},
  };
}

EvaluationThinkingMode parseEvaluationThinkingMode(String? value) =>
    switch (value) {
      null || 'on' => EvaluationThinkingMode.on,
      'off' => EvaluationThinkingMode.off,
      _ => throw ArgumentError('--thinking must be on or off'),
    };

String evaluationRequestThinkingMode(Map<String, Object?> body) {
  final thinking = body['thinking'];
  final type = thinking is Map ? thinking['type'] : null;
  return switch (type) {
    'enabled' => 'on',
    'disabled' => 'off',
    _ => 'unknown',
  };
}
