import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../tool/eval_coach_agent_v2.dart';
import '../tool/eval_context_config.dart';

void main() {
  test(
    'evaluation override leaves production and default evaluation intact',
    () {
      expect(
        evaluationContextBudget().toJson(),
        const ContextBudgetConfig().toJson(),
      );
      final configured = evaluationContextBudget(softOnBytes: '30000');
      expect(configured.softOnBytes, 30000);
      expect(configured.softOffBytes, 40960);
      expect(configured.hardBytes, 65536);
      expect(const ContextBudgetConfig().softOnBytes, 51200);
      for (final value in ['0', '-1', '65537', 'x']) {
        expect(
          () => evaluationContextBudget(softOnBytes: value),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'a real-wire 400 invokes the evaluation stop hook after recording it',
    () async {
      final records = <Map<String, Object?>>[];
      var stopped = false;
      final client =
          EvaluationWireClient(
              MockClient(
                (_) async =>
                    http.Response('{"error":{"message":"bad request"}}', 400),
              ),
              EvaluationRedactor([]),
              records.add,
            )
            ..onBadRequest = () {
              expect(records.last['httpStatus'], 400);
              stopped = true;
            };
      final response = await client.post(
        Uri.https('example.test', '/v1/chat/completions'),
        body: '{"model":"test","messages":[]}',
      );
      expect(response.statusCode, 400);
      expect(stopped, isTrue);
      expect(client.calls, hasLength(1));
      client.close();
    },
  );
}
