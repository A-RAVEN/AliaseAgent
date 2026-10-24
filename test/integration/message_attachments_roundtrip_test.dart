// 带图消息的存取回环（add-image-input 任务 7.3）。
//
// 规格要求库里只存路径：`attachments` 列是 `[{"path":"…"}]`，**每个元素只有
// `path` 一个键**（宽高 / 媒体类型 / 字节数不落库）。这里连"写进去的到底是什么
// 形状"也一起断言 —— 只断言"能读回来"会漏掉偷偷多存了几个字段的情况。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/session_repository.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('带图消息的存取回环', () {
    late Directory tempDir;
    late MessageRepository msgRepo;
    late SessionRepository sessionRepo;
    late String sessionId;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('attach_test_');
      await DatabaseService.openAt(tempDir.path);
      msgRepo = MessageRepository();
      sessionRepo = SessionRepository();
      sessionId = (await sessionRepo.create()).id;
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('插入带图消息：库里只存 path，读回来路径一致', () async {
      const path = r'C:\Users\someone\.aliasagent\attachments\paste-1.png';
      final inserted = await msgRepo.insert(
        sessionId: sessionId,
        role: 'user',
        content: '看看这张图',
        attachments: const [path],
      );
      expect(inserted.attachments, [path]);

      // 直接读库，看列里到底是什么形状
      final db = await DatabaseService.database;
      final rows = await db.query('messages',
          where: 'id = ?', whereArgs: [inserted.id]);
      expect(rows, hasLength(1));
      final column = rows.first['attachments'] as String?;
      // ignore: avoid_print
      print('  [OBS] attachments 列原文 => $column');
      expect(column, isNotNull);

      final decoded = jsonDecode(column!) as List<dynamic>;
      expect(decoded, hasLength(1));
      final element = decoded.first as Map<String, dynamic>;
      expect(element.keys.toList(), ['path'],
          reason: '库里只许存路径，多一个键都算违背"历史先只存路径"');
      expect(element['path'], path);

      // 走仓库读回来，路径一致
      final loaded = await msgRepo.queryBySession(sessionId);
      final back = loaded.firstWhere((m) => m.id == inserted.id);
      expect(back.attachments, [path]);
    });

    test('不带图的消息写 NULL，读回来是空列表', () async {
      final inserted = await msgRepo.insert(
        sessionId: sessionId,
        role: 'user',
        content: '纯文字',
      );

      final db = await DatabaseService.database;
      final rows = await db.query('messages',
          where: 'id = ?', whereArgs: [inserted.id]);
      // ignore: avoid_print
      print('  [OBS] 无附件时的列值 => ${rows.first['attachments']}');
      expect(rows.first['attachments'], isNull);

      final loaded = await msgRepo.queryBySession(sessionId);
      expect(loaded.single.attachments, isEmpty);
    });

    test('同一会话里两条消息的附件互不串味', () async {
      final plain = await msgRepo.insert(
          sessionId: sessionId, role: 'user', content: '第一句');
      final withImage = await msgRepo.insert(
        sessionId: sessionId,
        role: 'user',
        content: '第二句',
        attachments: const ['/tmp/x.png', '/tmp/y.png'],
      );

      final loaded = await msgRepo.queryBySession(sessionId);
      expect(loaded.firstWhere((m) => m.id == plain.id).attachments, isEmpty);
      expect(loaded.firstWhere((m) => m.id == withImage.id).attachments,
          ['/tmp/x.png', '/tmp/y.png']);
    });
  });
}
