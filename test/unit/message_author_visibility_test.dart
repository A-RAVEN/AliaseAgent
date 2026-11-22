// `messages.author` / `messages.visibility` 的纯模型读写（change `agent-group-chat`
// 任务 1.2 / design D1、D17、D20）。
//
// 只测 `lib/models/message.dart` 的 `fromRow` / `toRow`（仓储断言在 integration 层）：
//   - ① round-trip：写出去再读回来，两列一字不差；
//   - ② 缺省等于变更前行为：没有作者/可见性的旧行读成 author=NULL、visibility=public，
//        写出去的新行也默认 public（缺省不是"空串"、不是"private"）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';

void main() {
  group('Message 的作者与可见性列', () {
    test('round-trip：author / visibility 写出去再读回来一字不差', () {
      final message = Message(
        id: 'm-1',
        seq: 7,
        sessionId: 'g-1',
        role: 'assistant',
        content: '甲说它改完了',
        author: 'member-a',
        visibility: 'private-to-author',
        createdAt: 1700000000000,
      );

      final row = message.toRow();
      // ignore: avoid_print
      print('[OBS] toRow author=${row['author']} visibility=${row['visibility']}');

      final back = Message.fromRow(row);
      expect(back.author, 'member-a');
      expect(back.visibility, 'private-to-author');
      expect(back.content, '甲说它改完了');
      expect(back.seq, 7);
    });

    test('缺省等于变更前行为：旧行无这两列 ⇒ author=NULL、visibility=public', () {
      // 变更前写出的行形状（没有 author / visibility 两个键）。
      final legacyRow = <String, dynamic>{
        'id': 'm-old',
        'seq': 1,
        'session_id': 's-1',
        'role': 'user',
        'content': '老消息',
        'tool_calls': null,
        'thinking_json': null,
        'token_count': null,
        'created_at': 1,
      };

      final message = Message.fromRow(legacyRow);
      // ignore: avoid_print
      print('[OBS] legacy fromRow author=${message.author} '
          'visibility=${message.visibility} isUserAuthor=${message.isUserAuthored}');

      expect(message.author, isNull,
          reason: '旧数据的作者必须是 NULL（用户消息的表示），不是空串');
      expect(message.visibility, 'public',
          reason: '旧数据的可见性必须回落成 public（缺省可见）');
      expect(message.isUserAuthored, isTrue,
          reason: 'author 为 NULL 就是"用户写的"（用户消息没有成员作者）');

      // 新写出的行：没显式给作者/可见性时，默认 public + author NULL。
      final fresh = Message(
        id: 'm-new',
        sessionId: 's-1',
        role: 'user',
        content: '新消息',
        createdAt: 2,
      );
      final freshRow = fresh.toRow();
      // ignore: avoid_print
      print('[OBS] fresh toRow author=${freshRow['author']} '
          'visibility=${freshRow['visibility']}');
      expect(freshRow['author'], isNull);
      expect(freshRow['visibility'], 'public');
    });

    test('用户消息没有成员作者：public 且 author 为 NULL', () {
      final user = Message(
        id: 'u-1',
        seq: 3,
        sessionId: 'g-1',
        role: 'user',
        content: '你们两个都看一下',
        createdAt: 3,
      );
      expect(user.toRow()['visibility'], 'public');
      expect(user.toRow()['author'], isNull);
      expect(user.isUserAuthored, isTrue);
    });

    test('visibility 只接受 public / private-to-author 两个取值', () {
      // 这不是风格问题：未知可见性会让投影的过滤规则无从判断，构造期就拒绝。
      // 用 assert（构造期守卫，debug 下必触发）：取值来自内部代码而非用户输入。
      expect(
        () => Message(
          id: 'x',
          sessionId: 's',
          role: 'assistant',
          content: 'x',
          visibility: 'secret',
          createdAt: 1,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
