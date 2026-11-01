import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_budget.dart';

void main() {
  test(
    'approved off and on byte thresholds are configurable independently',
    () {
      const standard = ContextBudgetConfig();
      expect(standard.softLimit(thinking: false), 163840);
      expect(standard.softLimit(thinking: true), 204800);
      expect(standard.hardBytes, 262144);
      const custom = ContextBudgetConfig(
        softOffBytes: 1000,
        softOnBytes: 2000,
        hardBytes: 3000,
      );
      expect(custom.softLimit(thinking: false), 1000);
      expect(custom.softLimit(thinking: true), 2000);
      expect(custom.hardBytes, 3000);
    },
  );

  test(
    'diagnostics preserve actual before and after sizes without payloads',
    () {
      const unchanged = ContextRequestDiagnostics(
        epoch: 1,
        beforeBytes: 1000,
        afterBytes: 1000,
        softLimitBytes: 163840,
        hardLimitBytes: 262144,
        tailStateBytes: 200,
        completedTurnsFolded: 0,
        receiptBodiesFolded: 0,
        measurement: 'exact OpenAI-compatible JSON',
        fitsHardLimit: true,
      );
      expect(unchanged.folded, isFalse);
      const folded = ContextRequestDiagnostics(
        epoch: 1,
        beforeBytes: 280000,
        afterBytes: 204000,
        softLimitBytes: 204800,
        hardLimitBytes: 262144,
        tailStateBytes: 300,
        completedTurnsFolded: 2,
        receiptBodiesFolded: 1,
        measurement: 'exact OpenAI-compatible JSON',
        fitsHardLimit: true,
      );
      expect(folded.folded, isTrue);
      expect(folded.toJson()['beforeBytes'], 280000);
      expect(folded.toJson()['afterBytes'], 204000);
      expect(folded.toJson()['tailStateBytes'], 300);
      expect(folded.toJson().keys, isNot(contains('messages')));
    },
  );
}
