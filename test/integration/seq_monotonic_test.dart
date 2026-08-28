import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Stable seq column', () {
    late Directory tempDir;
    late MessageRepository msgRepo;
    late SessionRepository sessionRepo;
    late String sessionId;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('seq_test_');
      await DatabaseService.openAt(tempDir.path);
      msgRepo = MessageRepository();
      sessionRepo = SessionRepository();
      final s = await sessionRepo.create();
      sessionId = s.id;
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('seq strictly increasing across rapid same-millisecond inserts', () async {
      // Tight loop — no artificial delays, so created_at for many rows will
      // collide (same millisecond). seq must still be strictly increasing.
      final seqs = <int>[];
      for (var i = 0; i < 6; i++) {
        final m = await msgRepo.insert(
          sessionId: sessionId, role: i.isEven ? 'user' : 'assistant',
          content: 'msg $i',
        );
        expect(m.seq, isNotNull, reason: 'inserted message must carry a seq');
        seqs.add(m.seq!);
      }

      // [OBS] dump the seq sequence before asserting.
      // ignore: avoid_print
      print('  [OBS] seq sequence: $seqs');
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]),
            reason: 'seq must be strictly increasing under same-millisecond inserts');
      }
    });

    test('queryBySession is deterministic (seq tiebreaker) when created_at ties', () async {
      final m1 = await msgRepo.insert(
          sessionId: sessionId, role: 'user', content: 'first');
      final m2 = await msgRepo.insert(
          sessionId: sessionId, role: 'assistant', content: 'second');

      // Force a created_at tie so ordering must fall back to seq.
      final db = await DatabaseService.database;
      await db.update('messages', {'created_at': 0}, where: 'id = ?', whereArgs: [m1.id]);
      await db.update('messages', {'created_at': 0}, where: 'id = ?', whereArgs: [m2.id]);

      final loaded = await msgRepo.queryBySession(sessionId);
      expect(loaded.map((m) => m.id).toList(), [m1.id, m2.id],
          reason: 'with equal created_at, ordering by seq must keep lower seq first');
    });
  });
}
