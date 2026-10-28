// Offline public-response replay. This tool never makes HTTP requests or reads
// API credentials. It measures requests composed by the current SDK rather than
// claiming to reproduce the historical HTTP bodies byte for byte.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ugk_coach/ugk_coach.dart';

typedef Json = Map<String, Object?>;

Json _map(Object? value) => (value as Map).cast<String, Object?>();
List<Object?> _list(Object? value) => value is List ? value : const [];
String _encoded(Object? value) => jsonEncode(value);
int _bytes(Object? value) => utf8.encode(_encoded(value)).length;
String _hash(Object? value) =>
    sha256.convert(utf8.encode(_encoded(value))).toString();

int _lcp(List<int> before, List<int> after) {
  var index = 0;
  while (index < before.length &&
      index < after.length &&
      before[index] == after[index]) {
    index++;
  }
  return index;
}

bool _state(Json message) =>
    (message['role'] == 'system' || message['role'] == 'user') &&
    ((message['content'] as String? ?? '').startsWith('当前状态：') ||
        (message['content'] as String? ?? '').startsWith('当前状态（系统生成）：'));

String? _firstDifference(Object? before, Object? after, [String path = r'$']) {
  if (_encoded(before) == _encoded(after)) return null;
  if (before is Map && after is Map) {
    for (final key in {...before.keys, ...after.keys}) {
      if (!before.containsKey(key) || !after.containsKey(key)) {
        return '$path.$key';
      }
      final next = _firstDifference(before[key], after[key], '$path.$key');
      if (next != null) return next;
    }
  } else if (before is List && after is List) {
    for (var i = 0; i < before.length && i < after.length; i++) {
      final next = _firstDifference(before[i], after[i], '$path[$i]');
      if (next != null) return next;
    }
    return '$path.length';
  }
  return path;
}

Json _messageSummary(Json message) => {
  'role': message['role'],
  if (message['tool_call_id'] != null) 'toolCallId': message['tool_call_id'],
  'dynamicState': _state(message),
  'bytes': _bytes(message),
  'sha256': _hash(message),
};

String _mechanism(Json? before, Json? after) {
  if (before == null) return 'new-message-appended';
  if (after == null) return 'previous-message-removed';
  if (_state(before) || _state(after)) {
    return 'front-or-tail-current-state-rebuilt';
  }
  final content = after['content'] as String? ?? '';
  if (content.contains('与当前任务无关的技能 read')) {
    return 'unrelated-skill-read-archived';
  }
  if (content.startsWith('[已归档]') || content.startsWith('[已归档，候选')) {
    return 'consumed-action-batch-archived';
  }
  if (content == '[已归档，见当前状态]') {
    return 'completed-node-or-superseded-failure-archived';
  }
  if (content.contains('sameAsCurrentState') ||
      content.contains('sameAsToolCall')) {
    return 'old-tool-state-or-format-deduplicated';
  }
  if (content.startsWith('已读 ') && content.contains('（')) {
    return 'budget-read-compression';
  }
  if (before['role'] != after['role'] ||
      before['tool_call_id'] != after['tool_call_id']) {
    return 'history-removed-reordered-or-completed-task-cleanup';
  }
  return 'existing-message-content-changed';
}

List<Json> _messages(Json body) => _list(body['messages']).map(_map).toList();

Json _compare(Json body, Json? previous) {
  final messages = _messages(body);
  final states = [
    for (var i = 0; i < messages.length; i++)
      if (_state(messages[i])) i,
  ];
  final history = messages
      .where((m) => m['role'] != 'system' && !_state(m))
      .toList();
  final systems = messages
      .where((m) => m['role'] == 'system' && !_state(m))
      .toList();
  final projection = <String, Object?>{
    'system': systems,
    'tools': body['tools'],
    'history': history,
  };
  final encoded = utf8.encode(_encoded(body));
  final stateBytes = states.fold(
    0,
    (sum, index) => sum + _bytes(messages[index]),
  );
  final tailStateBytes = states
      .where((index) => index == messages.length - 1)
      .fold(0, (sum, index) => sum + _bytes(messages[index]));
  if (previous == null) {
    return {
      'requestBytes': encoded.length,
      'requestSha256': _hash(body),
      'messageCount': messages.length,
      'fullHttpJsonLcpBytes': null,
      'systemEqualToPrevious': null,
      'toolsEqualToPrevious': null,
      'previousHistoryRetainedVerbatimAsPrefix': null,
      'stableProjectionLcpBytes': null,
      'dynamicStateMessageIndexes': states,
      'dynamicStateMessageBytes': stateBytes,
      'tailDynamicStateMessageBytes': tailStateBytes,
      'dynamicStateCacheMissLowerBoundBytes': stateBytes,
      'firstChangedMessage': null,
      'firstChangedHistoryMessage': null,
      'mechanisms': ['first-request'],
    };
  }
  final oldMessages = _messages(previous);
  final oldHistory = oldMessages
      .where((m) => m['role'] != 'system' && !_state(m))
      .toList();
  final oldSystem = oldMessages
      .where((m) => m['role'] == 'system' && !_state(m))
      .toList();
  final oldProjection = <String, Object?>{
    'system': oldSystem,
    'tools': previous['tools'],
    'history': oldHistory,
  };
  Json? changed(List<Json> before, List<Json> after) {
    for (var i = 0; i < before.length || i < after.length; i++) {
      final old = i < before.length ? before[i] : null;
      final next = i < after.length ? after[i] : null;
      if (_encoded(old) != _encoded(next)) {
        return {
          'index': i,
          'mechanism': _mechanism(old, next),
          'jsonPath': _firstDifference(old, next),
          if (old != null) 'before': _messageSummary(old),
          if (next != null) 'after': _messageSummary(next),
        };
      }
    }
    return null;
  }

  final first = changed(oldMessages, messages);
  final firstHistory = changed(oldHistory, history);
  final retained =
      oldHistory.length <= history.length &&
      List.generate(
        oldHistory.length,
        (i) => _encoded(oldHistory[i]) == _encoded(history[i]),
      ).every((same) => same);
  final mechanisms = <String>{};
  if (_encoded(oldSystem) != _encoded(systems)) {
    mechanisms.add('system-rebuilt-with-different-content');
  }
  if (_encoded(previous['tools']) != _encoded(body['tools'])) {
    mechanisms.add('tools-rebuilt-with-dynamic-schema');
  }
  if (first != null) mechanisms.add(first['mechanism'] as String);
  if (firstHistory != null) mechanisms.add(firstHistory['mechanism'] as String);
  // Match old tool receipts by occurrence as well as ID; repeated IDs from
  // separate real batches must not be confused with one another.
  final pending = <String, List<Json>>{};
  for (final message in history.where((m) => m['role'] == 'tool')) {
    (pending[message['tool_call_id'] as String] ??= []).add(message);
  }
  final alteredTools = <Json>[];
  for (final old in oldHistory.where((m) => m['role'] == 'tool')) {
    final id = old['tool_call_id'] as String;
    final matches = pending[id];
    final next = matches == null || matches.isEmpty
        ? null
        : matches.removeAt(0);
    if (_encoded(old) == _encoded(next)) continue;
    final mechanism = _mechanism(old, next);
    mechanisms.add(mechanism);
    alteredTools.add({
      'toolCallId': id,
      'mechanism': mechanism,
      'beforeBytes': _bytes(old),
      'afterBytes': next == null ? null : _bytes(next),
    });
  }
  return {
    'requestBytes': encoded.length,
    'requestSha256': _hash(body),
    'messageCount': messages.length,
    'fullHttpJsonLcpBytes': _lcp(utf8.encode(_encoded(previous)), encoded),
    'systemEqualToPrevious': _encoded(oldSystem) == _encoded(systems),
    'toolsEqualToPrevious':
        _encoded(previous['tools']) == _encoded(body['tools']),
    'firstToolsDifferencePath': _firstDifference(
      previous['tools'],
      body['tools'],
    ),
    'previousHistoryRetainedVerbatimAsPrefix': retained,
    'stableProjectionLcpBytes': _lcp(
      utf8.encode(_encoded(oldProjection)),
      utf8.encode(_encoded(projection)),
    ),
    'dynamicStateMessageIndexes': states,
    'dynamicStateMessageBytes': stateBytes,
    'tailDynamicStateMessageBytes': tailStateBytes,
    'dynamicStateCacheMissLowerBoundBytes': stateBytes,
    'firstChangedMessage': first,
    'firstChangedHistoryMessage': firstHistory,
    'alteredPriorToolMessages': alteredTools,
    'mechanisms': mechanisms.toList(),
  };
}

class _NoNetwork extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw StateError('HTTP is forbidden in the context-prefix audit');
}

class _Replay implements LlmClient {
  _Replay(this.serializer);
  final OpenAiCompatibleClient serializer;
  final captures = <Json>[];
  List<Json> pending = [];
  int turn = 0;
  int consumed = 0;
  Json? previous;
  Json Function()? latestContextDiagnostics;
  @override
  String get model => serializer.model;
  @override
  Pricing? get pricing => null;
  @override
  Future<LlmResponse> complete(
    LlmRequest request, {
    CancelToken? cancel,
  }) async {
    final body = serializer.buildBody(request);
    final source = consumed < pending.length ? pending[consumed++] : null;
    captures.add({
      'request': captures.length + 1,
      'turn': turn,
      'sourceCall': source?['call'],
      'sourceAgentStep': source?['agentStep'],
      'sourceResponsesExhausted': source == null,
      if (latestContextDiagnostics != null)
        'contextDiagnostics': latestContextDiagnostics!(),
      ..._compare(body, previous),
    });
    previous = body;
    if (source == null) throw StateError('No recorded public response remains');
    final response = _map(source['response']);
    final choice = _map(_list(response['choices']).first);
    final message = _map(choice['message']);
    if ((message['reasoningUtf8Bytes'] as int? ?? 0) != 0) {
      throw StateError(
        'Private reasoning is unavailable; refusing to synthesize it',
      );
    }
    return LlmResponse(
      content: message['content'] as String? ?? '',
      model: response['model'] as String?,
      finishReason: choice['finish_reason'] as String?,
      toolCalls: [
        for (var i = 0; i < _list(message['tool_calls']).length; i++)
          LlmToolCall.fromOpenAi(_list(message['tool_calls'])[i], i),
      ],
      usage: TokenUsage.fromOpenAi(response['usage']),
    );
  }
}

Future<String> _git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) throw StateError('Git metadata lookup failed');
  return (result.stdout as String).trim();
}

Future<String> _sourceHash() async {
  final files = <File>[];
  for (final name in ['lib', 'skills', 'prompts', 'profiles']) {
    files.addAll(Directory(name).listSync(recursive: true).whereType<File>());
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return _hash({
    for (final file in files)
      file.path.replaceAll('\\', '/'): sha256
          .convert(await file.readAsBytes())
          .toString(),
  });
}

Future<void> main(List<String> args) async {
  String? arg(String flag) {
    final index = args.indexOf(flag);
    if (index < 0) return null;
    if (index + 1 >= args.length) throw ArgumentError('Missing $flag');
    return args[index + 1];
  }

  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/audit_context_prefix.dart [--label before|after] [--source DIR] [--out DIR]',
    );
    return;
  }
  final label = arg('--label') ?? 'before';
  if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(label)) {
    throw ArgumentError('Invalid label');
  }
  final sourceDir = Directory(
    arg('--source') ??
        r'E:\AII-3D\worktree-preserved\coach-v2-quality-deepseek-flash-20261028-off',
  );
  final output = Directory(
    arg('--out') ??
        r'E:\AII-3D\worktree-preserved\coach-info-context-20261028-review',
  );
  await output.create(recursive: true);
  final jsonFile = File('${output.path}/prefix-$label.json');
  final mdFile = File('${output.path}/prefix-$label.md');
  if (jsonFile.existsSync() || mdFile.existsSync()) {
    throw StateError('Refusing to overwrite prefix evidence');
  }
  final productHash = await _sourceHash();
  final revision = await _git(['rev-parse', 'HEAD']);
  final productChanges = (await _git([
    'diff',
    '--name-only',
    'HEAD',
    '--',
    'lib',
    'skills',
    'profiles',
    'prompts',
  ])).split('\n').where((path) => path.isNotEmpty).toList();
  productChanges.addAll(
    (await _git([
      'ls-files',
      '--others',
      '--exclude-standard',
      '--',
      'lib',
      'skills',
      'profiles',
      'prompts',
    ])).split('\n').where((path) => path.isNotEmpty),
  );
  productChanges.sort();
  final sourceRevision = await _git(['rev-parse', '31f0f18']);
  final summary = _map(
    jsonDecode(await File('${sourceDir.path}/summary.json').readAsString()),
  );
  if (summary['thinkingMode'] != 'off') {
    throw StateError('This audit requires public thinking-off responses');
  }
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    await File('$pack/catalog.json').readAsBytes(),
    semanticCatalogBytes: await File(
      '$pack/catalog/catalog.json',
    ).readAsBytes(),
  ).toAiCatalog();
  final profile = CoachProfile.fromJson(
    jsonDecode(await File('profiles/smartfit.json').readAsString()),
  );
  final cases = <Json>[];
  for (final id in ['R1', 'R3', 'R4']) {
    final sourceFile = File('${sourceDir.path}/$id.json');
    final source = _map(jsonDecode(await sourceFile.readAsString()));
    final calls = _list(source['calls']).map(_map).toList();
    final sourceRequest = _map(calls.first['request']);
    final serializer = OpenAiCompatibleClient(
      config: LlmConfig(
        baseUrl: 'https://offline.invalid/v1',
        model: sourceRequest['model'] as String,
        maxTokens: sourceRequest['max_tokens'] as int,
        maxRetries: 0,
        extraBody: {'thinking': sourceRequest['thinking']},
      ),
      httpClient: _NoNetwork(),
    );
    final replay = _Replay(serializer);
    final agent = CoachAgent(
      client: replay,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: true,
      maxRequestRetries: 0,
      clock: () => DateTime.utc(2026, 10, 28),
      requestSizeBytes: (request) =>
          utf8.encode(jsonEncode(serializer.buildBody(request))).length,
    );
    replay.latestContextDiagnostics = () =>
        agent.contextRequestDiagnostics.last.toJson();
    final turns = <Json>[];
    try {
      for (final rawTurn in _list(source['turns'])) {
        final turn = _map(rawTurn);
        replay.turn = turn['turn'] as int;
        replay.pending = calls
            .where(
              (call) =>
                  call['turn'] == replay.turn &&
                  call['response'] is Map &&
                  _list(_map(call['response'])['choices']).isNotEmpty,
            )
            .toList();
        replay.consumed = 0;
        final result = await agent.send(
          turn['user'] as String,
          context: const CoachContext(language: 'zh'),
        );
        turns.add({
          'turn': replay.turn,
          'sourceOrigin': turn['origin'],
          'sourceResponseCount': replay.pending.length,
          'consumedSourceResponses': replay.consumed,
          'unusedSourceCalls': replay.pending
              .skip(replay.consumed)
              .map((call) => call['call'])
              .toList(),
          'status': result.status.name,
          'hasPlan': result.plan != null,
          'hasActions': result.actions != null,
          'hasQuestion': result.question != null,
          'issueCodes': result.records
              .expand((record) => record.issueCodes)
              .toList(),
          'errorType': result.error?.runtimeType.toString(),
        });
      }
    } finally {
      await agent.dispose();
      serializer.close();
    }
    cases.add({
      'id': id,
      'sourcePath': sourceFile.absolute.path,
      'sourceFileSha256': sha256
          .convert(await sourceFile.readAsBytes())
          .toString(),
      'sourceRecordedSnapshotSha256': source['sourceSha256'],
      'turns': turns,
      'requests': replay.captures,
    });
  }
  final report = <String, Object?>{
    'schemaVersion': 1,
    'mode': 'offline-public-response-context-prefix-audit',
    'label': label,
    'sdkRevision': revision,
    'sdkProductSourceSha256': productHash,
    'auditToolSha256': sha256
        .convert(await File('tool/audit_context_prefix.dart').readAsBytes())
        .toString(),
    'sdkUncommittedProductPaths': productChanges,
    'sdkProductSourceUnchangedDuringAudit': productHash == await _sourceHash(),
    'publicCaseSourceRevision': sourceRevision,
    'publicCaseSourceDirectory': sourceDir.absolute.path,
    'publicCaseSourceSnapshotSha256': summary['sourceSha256'],
    'networkRequests': 0,
    'realModelCalls': 0,
    'serializer': 'OpenAiCompatibleClient.buildBody + jsonEncode + UTF-8',
    'clock': 'fixed 2026-10-28T00:00:00Z for deterministic generated IDs',
    'criteria': {
      'literal':
          'Longest common UTF-8 prefix of the complete serialized JSON body, including state.',
      'acceptedStablePrefix':
          'System and tools must remain byte-identical; previously sent non-system history must remain an exact message prefix. Dynamic state is excluded only from this second criterion.',
      'stableProjection':
          'JSON {system,tools,history} with current-state messages excluded; auxiliary LCP is not the literal HTTP body.',
      'dynamicState':
          'Serialized message JSON bytes; position and actual tail bytes are reported separately. State bytes are a conservative cache-miss lower bound, not measured provider cached tokens.',
    },
    'limitations': [
      'Not historical HTTP byte reproduction: public thinking-off assistant/tool-call responses are replayed through the current SDK; current tool results, prompts and state composition are real current implementation output.',
      'No task/ledger/tool result is pre-injected. No private reasoning is available or synthesized; the SDK supplies its normal empty assistant reasoning field.',
      'Historical transport attempts without a public response are not replayed; no latency or token quality result is inferred.',
      'A new implementation can terminate sooner or pause differently; consumed and unused source response IDs are recorded rather than inventing follow-up responses.',
      'No credentials, HTTP headers, system prompt text, full request content or private reasoning are written in this evidence.',
    ],
    'cases': cases,
  };
  await jsonFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  final markdown = StringBuffer()
    ..writeln('# Offline context prefix audit — $label\n')
    ..writeln(
      'SDK `$revision` with product source SHA-256 `$productHash` (${productChanges.length} uncommitted product paths); public R1/R3/R4 source `$sourceRevision`. Network/model calls: **0**.\n',
    )
    ..writeln(
      'This is current-SDK public-response replay, not historical HTTP-byte reproduction. Private reasoning is unavailable and not synthesized.\n',
    )
    ..writeln(
      'Both criteria are retained: complete HTTP JSON LCP; and stable system/tools plus unchanged previously sent history, excluding dynamic state. State bytes below are an estimated cache-miss lower bound, not provider cache measurements.\n',
    );
  for (final item in cases) {
    markdown
      ..writeln('## ${item['id']}\n')
      ..writeln(
        '|Case/request|Source call / turn|Body B|Full JSON LCP B|System same|Tools same|Prior history unchanged prefix|State B / tail B|First changed message|Mechanisms|',
      )
      ..writeln('|---|---|---:|---:|---|---|---|---:|---|---|');
    for (final raw in _list(item['requests'])) {
      final row = _map(raw);
      final first = row['firstChangedMessage'];
      final index = first is Map ? first['index'] : '—';
      markdown.writeln(
        '|${item['id']}/${row['request']}|${row['sourceCall']} / ${row['turn']}|${row['requestBytes']}|${row['fullHttpJsonLcpBytes'] ?? '—'}|${row['systemEqualToPrevious'] ?? '—'}|${row['toolsEqualToPrevious'] ?? '—'}|${row['previousHistoryRetainedVerbatimAsPrefix'] ?? '—'}|${row['dynamicStateMessageBytes']} / ${row['tailDynamicStateMessageBytes']}|$index|${_list(row['mechanisms']).join('; ')}|',
      );
    }
    markdown.writeln('\n${item['id']} turns: `${_encoded(item['turns'])}`\n');
  }
  markdown.writeln(
    '\nEvery changed prior tool receipt, first history difference, tool-schema difference path, state position and source-consumption boundary is in the paired JSON. Stable projection LCP is supplementary and never replaces the literal HTTP LCP.',
  );
  await mdFile.writeAsString(markdown.toString());
  stdout.writeln(
    'Offline prefix audit saved: ${jsonFile.absolute.path}; realModelCalls=0.',
  );
}
