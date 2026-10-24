// `Message.attachments` 的解析与写回（add-image-input 任务 7.1）。
//
// 覆盖：attachments 列为 NULL、为合法 JSON、为坏 JSON、为"不是数组"四种形态。
// 规格要求库里的附件记录**只有一个键 `path`**（见 specs/session-persistence），
// 所以这里连"写回的列里到底有哪些键"也一起断言了。
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';

Map<String, dynamic> rowWith(Object? attachmentsColumn) => {
      'id': 'm1',
      'seq': 1,
      'session_id': 's1',
      'role': 'user',
      'content': 'hi',
      'tool_calls': null,
      'thinking_json': null,
      'token_count': null,
      'output_token_count': null,
      'created_at': 1700000000000,
      'attachments': attachmentsColumn,
    };

void main() {
  group('Message.attachments', () {
    test('NULL 列解析成空列表', () {
      final message = Message.fromRow(rowWith(null));
      expect(message.attachments, isEmpty);
    });

    test('合法 JSON 解析成路径列表，且写回只有 path 一个键', () {
      final column = '[{"path":"C:\\\\tmp\\\\a.png"},{"path":"C:\\\\tmp\\\\b.png"}]';
      final message = Message.fromRow(rowWith(column));
      expect(message.attachments, ['C:\\tmp\\a.png', 'C:\\tmp\\b.png']);

      // 写回：列里是 JSON 数组，每个元素只有 path 一个键
      final written = message.toRow()['attachments'] as String;
      expect(written, contains('"path"'));
      expect(written, isNot(contains('"width"')));
      expect(written, isNot(contains('"media_type"')));

      // 回环：从自己写出的列再解析一次，结果一致
      final again = Message.fromRow(rowWith(written));
      expect(again.attachments, message.attachments);
    });

    test('坏 JSON 与"不是数组"都回落成空列表并各打一行日志', () {
      final original = debugPrint;
      final lines = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = original);

      expect(Message.fromRow(rowWith('{not json')).attachments, isEmpty);
      expect(lines, isNotEmpty, reason: '坏数据不能静默吞掉');
      expect(lines.join('\n'), contains('attachments'));

      lines.clear();
      expect(Message.fromRow(rowWith('{"path":"a.png"}')).attachments, isEmpty);
      expect(lines, isNotEmpty, reason: '"不是数组"也算坏数据，要有痕迹');

      lines.clear();
      // 元素缺 path、或 path 是空串，同样算坏数据（不静默跳过那一条）
      expect(Message.fromRow(rowWith('[{"nope":1}]')).attachments, isEmpty);
      expect(lines, isNotEmpty);
      expect(Message.fromRow(rowWith('[{"path":""}]')).attachments, isEmpty);
      expect(lines, isNotEmpty);
    });

    test('没有附件时写回的列是 null', () {
      const message = Message(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: 'hi',
        createdAt: 1,
      );
      expect(message.toRow()['attachments'], isNull);
    });
  });
}
