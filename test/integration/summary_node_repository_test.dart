import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('SummaryNodeRepository (compaction tree persistence)', () {
    late Directory tempDir;
    late SummaryNodeRepository repo;
    late String sessionId;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('summnode_test_');
      await DatabaseService.openAt(tempDir.path);
      repo = SummaryNodeRepository();
      sessionId = (await SessionRepository().create()).id;
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('materialize persists a node + bumps tree_version atomically', () async {
      await repo.materialize(
        sessionId: sessionId,
        level: 1,
        startSeq: 1,
        endSeq: 10,
        nodeType: 'summary',
        summaryJson: '{"role":"user","content":[{"type":"text","text":"## 更早上下文"}]}',
        tokenCost: 120,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: 1,
        coveredMaxSeq: 10,
      );

      final nodes = await repo.queryBySession(sessionId);
      // [OBS] dump the persisted tree before asserting (test observability).
      // ignore: avoid_print
      print('  [OBS] nodes after materialize: ${nodes.length} node(s) => '
          '${nodes.map((n) => 'lvl${n.level}:${n.nodeType}:[${n.startSeq},${n.endSeq}]').join(' | ')}'
          ' | tree_version=${await repo.treeVersion(sessionId)}');
      expect(nodes.length, 1);
      expect(nodes.first.level, 1);
      expect(nodes.first.nodeType, 'summary');
      expect(await repo.treeVersion(sessionId), 1,
          reason: 'tree_version must be bumped in the same transaction');

      final covering = await repo.findCovering(sessionId, 1, 10);
      expect(covering, isNotNull);
      expect(covering!.summaryJson, contains('## 更早上下文'));
    });

    test('original messages are preserved (compaction never deletes them)', () async {
      // Insert real messages into the session, then materialize a summary over
      // their span. The contract (spec "Original conversation retained on disk"):
      // materializing a summary node must NEVER delete or mutate the underlying
      // messages — they stay on disk, row count and content unchanged.
      final msgRepo = MessageRepository();
      final u = await msgRepo.insert(
        sessionId: sessionId, role: 'user', content: 'original user text', tokenCount: 5);
      final a = await msgRepo.insert(
        sessionId: sessionId, role: 'assistant', content: 'original assistant', tokenCount: 3);

      await repo.materialize(
        sessionId: sessionId,
        level: 1,
        startSeq: u.seq!,
        endSeq: a.seq!,
        nodeType: 'summary',
        summaryJson: '{"role":"user","content":[{"type":"text","text":"## 更早上下文"}]}',
        tokenCost: 120,
        summaryPromptVersion: 1,
        model: 'test-model',
        coveredMinSeq: u.seq!,
        coveredMaxSeq: a.seq!,
      );

      final msgs = await msgRepo.queryBySession(sessionId);
      // [OBS] dump the actual rows before asserting, so a failure is attributable.
      // ignore: avoid_print
      print('  [OBS] messages after materialize: ${msgs.length} rows => '
          '${msgs.map((m) => '${m.role}:${m.content}').join(' | ')}');

      expect(msgs.length, 2, reason: 'compaction must never delete original messages');
      expect(msgs.first.content, 'original user text',
          reason: 'original message content must be byte-identical after materialize');
      expect(msgs.last.content, 'original assistant',
          reason: 'original message content must be byte-identical after materialize');
    });

    test('materialize is an upsert: same covered span -> one row, latest content wins', () async {
      // R0-H-BUG: re-materializing the same covered span must REPLACE, not
      // accumulate duplicates. Direct, non-vacuous — fails on insert-only, passes
      // on upsert.
      Future<void> materializeSpan(String summaryJson) => repo.materialize(
            sessionId: sessionId,
            level: 1,
            startSeq: 1,
            endSeq: 10,
            nodeType: 'summary',
            summaryJson: summaryJson,
            tokenCost: 120,
            summaryPromptVersion: 1,
            model: 'test-model',
            coveredMinSeq: 1,
            coveredMaxSeq: 10,
          );
      await materializeSpan('{"role":"user","content":[{"type":"text","text":"OLD"}]}');
      await materializeSpan('{"role":"user","content":[{"type":"text","text":"NEW"}]}');

      final nodes = await repo.queryBySession(sessionId);
      // [OBS] dump the actual rows before asserting.
      // ignore: avoid_print
      print('  [OBS] nodes after re-materializing same span: ${nodes.length} row(s) => '
          '${nodes.map((n) => n.summaryJson).join(' | ')}');
      expect(nodes.length, 1,
          reason: 're-materializing the same covered span must override, not duplicate');
      final covering = await repo.findCovering(sessionId, 1, 10);
      expect(covering, isNotNull);
      expect(covering!.summaryJson, contains('NEW'),
          reason: 'findCovering must return the freshest summary for the span');
    });

    test('dirty-since-seq watermark: markDirty lowers to MIN, clearDirty resets', () async {
      expect(await repo.dirtySinceSeq(sessionId), 0, reason: 'clean session starts at 0');
      await repo.markDirty(sessionId, 10);
      expect(await repo.dirtySinceSeq(sessionId), 10, reason: 'first mutation sets the watermark');
      await repo.markDirty(sessionId, 3);
      expect(await repo.dirtySinceSeq(sessionId), 3,
          reason: 'an older (lower) seq mutation lowers the watermark');
      await repo.markDirty(sessionId, 7);
      expect(await repo.dirtySinceSeq(sessionId), 3,
          reason: 'a newer seq mutation does NOT raise the min watermark');
      await repo.clearDirty(sessionId);
      expect(await repo.dirtySinceSeq(sessionId), 0, reason: 'clearDirty resets to clean');
    });

    test('bumpTreeVersion increments the tree_version counter', () async {
      final before = await repo.treeVersion(sessionId);
      await repo.bumpTreeVersion(sessionId);
      final after = await repo.treeVersion(sessionId);
      // [OBS] dump the version delta before asserting (test observability).
      // ignore: avoid_print
      print('  [OBS] tree_version: before=$before after=$after (delta=${after - before})');
      expect(after, before + 1,
          reason: 'bumpTreeVersion increments the per-session materialization counter');
    });
  });
}
