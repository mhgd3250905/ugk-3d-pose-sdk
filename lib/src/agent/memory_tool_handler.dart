part of 'coach_agent.dart';

String _memoryError(String code) => jsonEncode({
  ...nodeError(code, 'memory', '记忆写入成功且本轮未取消', code, '不要确认保存成功；需要时重新调用记忆工具。'),
  'error': code,
  'message': '记忆未确认保存成功，不要向用户确认已记下或已忘记。',
});

extension _AgentMemoryToolHandler on CoachAgent {
  Future<String> _memoryOp(
    LlmToolCall t, {
    required bool Function() valid,
    required int epoch,
  }) async {
    final kindName = CoachAgent._arg(t, 'kind');
    final kind = MemoryKind.values.where((k) => k.name == kindName).firstOrNull;
    final text = CoachAgent._arg(t, 'text');
    late List<MemoryEntry> Function(List<MemoryEntry>) update;
    if (t.name == AgentTools.remember) {
      if (kind == null || text == null || text.trim().isEmpty) {
        return jsonEncode({
          ...nodeError('invalid_memory', 'kind/text', '合法记忆类别和非空 text', {
            'kind': kindName,
            'text': text,
          }, '提供 schema 中的 kind 以及用户主动表达的 text。'),
          'error':
              'remember 需要 kind（${MemoryKind.values.map((k) => k.name).join('/')}）和 text',
        });
      }
      final at = _clock().toUtc();
      update = (m) => UserMemoryOps.remember(
        m,
        MemoryEntry(kind, text, at: at),
        memoryLimits,
      );
    } else {
      if (kind == null && (text == null || text.trim().isEmpty)) {
        return jsonEncode({
          ...nodeError('invalid_memory', 'kind/text', 'kind 或非空 text', {
            'kind': kindName,
            'text': text,
          }, '提供需要删除的 kind 或 text。'),
          'error': 'forget 需要 kind 或 text',
        });
      }
      update = (m) => UserMemoryOps.forget(m, kind: kind, text: text);
    }
    try {
      return await _queueMemory(() async {
        if (!valid()) return _memoryError('cancelled');
        final before = List<MemoryEntry>.of(await memory());
        if (!valid()) return _memoryError('cancelled');
        final next = update(before);
        await memoryStore.save(next);
        if (!valid()) {
          // store 的 Future 不可取消。迟到写入仍占有队列，恢复未确认前的快照，
          // clearMemory 已递增 epoch 时以当前清空意图为准，再放行后续写入。
          await memoryStore.save(
            epoch == _memEpoch
                ? before
                : List<MemoryEntry>.of(_memory ?? const []),
          );
          return _memoryError('cancelled');
        }
        _memory = next;
        return jsonEncode({'ok': true});
      });
    } on Object {
      return _memoryError('memory_save_failed');
    }
  }
}
