/// Evaluation-only overrides. The production SDK defaults are never changed.
library;

import 'package:ugk_coach/ugk_coach.dart';

ContextBudgetConfig evaluationContextBudget({String? softOnBytes}) {
  const defaults = ContextBudgetConfig();
  if (softOnBytes == null) return defaults;
  final value = int.tryParse(softOnBytes);
  if (value == null || value <= 0 || value > defaults.hardBytes) {
    throw ArgumentError(
      'Evaluation soft-on bytes must be within the hard limit',
    );
  }
  return ContextBudgetConfig(softOnBytes: value);
}
