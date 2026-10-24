import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/context_estimator.dart';

/// Determinism contract of the proxy estimator: the same conversation always
/// yields the same projection (pure function of its input). This is what the
/// compaction design requires of the budget projection.
void main() {
  group('ContextEstimator.estimateTokens', () {
    test('empty text yields at least 1 token', () {
      expect(ContextEstimator.estimateTokens(''), 1);
    });

    test('same input always yields same output (pure function)', () {
      const text = 'The quick brown fox jumps over the lazy dog. @#\$% 中文文本';
      final a = ContextEstimator.estimateTokens(text);
      final b = ContextEstimator.estimateTokens(text);
      expect(a, b);
    });

    test('longer text yields >= as many tokens (monotonic)', () {
      final short = ContextEstimator.estimateTokens('hello');
      final long = ContextEstimator.estimateTokens(
          'hello world, this is a much longer string that should cost more tokens than a short one.');
      expect(long, greaterThan(short));
    });
  });

  group('ContextEstimator.estimateConversation determinism', () {
    test('same message list -> same total', () {
      final msgs = [
        Message(id: '1', sessionId: 's', role: 'user', content: 'Hello there', createdAt: 1),
        Message(id: '2', sessionId: 's', role: 'assistant', content: 'Hi! How can I help?', createdAt: 2),
        Message(
            id: '3',
            sessionId: 's',
            role: 'assistant',
            content: '',
            toolCallsJson:
                '[{"id":"tc1","toolName":"read_file","input":{"path":"/x"},"result":"body"}]',
            createdAt: 3),
      ];
      expect(ContextEstimator.estimateConversation([...msgs]),
          ContextEstimator.estimateConversation([...msgs]));
    });

    test('repeated runs over differently-ordered list still deterministic per list', () {
      final msgs = [
        Message(id: '1', sessionId: 's', role: 'user', content: 'A', createdAt: 1),
        Message(id: '2', sessionId: 's', role: 'user', content: 'B', createdAt: 2),
      ];
      for (var i = 0; i < 3; i++) {
        expect(
          ContextEstimator.estimateConversation(msgs),
          ContextEstimator.estimateConversation(msgs),
        );
      }
    });

    test('tool round adds overhead above a plain text message', () {
      final plain = Message(id: '1', sessionId: 's', role: 'assistant', content: 'x' * 20, createdAt: 1);
      final tool = Message(
          id: '2',
          sessionId: 's',
          role: 'assistant',
          content: 'x' * 20,
          toolCallsJson: '[{"id":"tc1","toolName":"read_file","input":{"path":"/x"}}]',
          createdAt: 2);
      expect(ContextEstimator.estimateMessage(tool),
          greaterThan(ContextEstimator.estimateMessage(plain)));
    });

    // hunks 只给界面画 diff，从不进入请求体；算进预算会让一次大编辑
    // 凭空抬高占用率、提前触发压缩。
    test('stored edit hunks do not change the estimate', () {
      final hunks = List.generate(
        200,
        (i) => '{"start_line":${i + 1},"old_text":"old line $i","new_text":"new line $i"}',
      ).join(',');
      final without = Message(
          id: '1',
          sessionId: 's',
          role: 'assistant',
          content: '',
          toolCallsJson:
              '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (1 replacement)"}]',
          createdAt: 1);
      final withHunks = Message(
          id: '2',
          sessionId: 's',
          role: 'assistant',
          content: '',
          toolCallsJson:
              '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (1 replacement)","hunks":[$hunks]}]',
          createdAt: 2);
      expect(ContextEstimator.estimateMessage(withHunks),
          ContextEstimator.estimateMessage(without));
    });

    test('the omission marker does not change the estimate either', () {
      final base =
          '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (3 replacements)"}]';
      final omitted =
          '[{"id":"tc1","toolName":"edit_file","input":{"path":"/x"},"result":"Edited /x (3 replacements)","hunksOmitted":"too large"}]';
      expect(
        ContextEstimator.estimateMessage(
            Message(id: '1', sessionId: 's', role: 'assistant', content: '', toolCallsJson: omitted, createdAt: 1)),
        ContextEstimator.estimateMessage(
            Message(id: '2', sessionId: 's', role: 'assistant', content: '', toolCallsJson: base, createdAt: 2)),
      );
    });
  });

  group('图片按每张 1024 token 计入（add-image-input 10.1）', () {
    test('用户消息带一张图，恰好比不带图多 1024', () {
      const without = Message(
          id: '1', sessionId: 's', role: 'user', content: '看看这个', createdAt: 1);
      const withImage = Message(
          id: '2',
          sessionId: 's',
          role: 'user',
          content: '看看这个',
          createdAt: 2,
          attachments: ['C:/tmp/a.png']);
      expect(ContextEstimator.estimateMessage(withImage) -
              ContextEstimator.estimateMessage(without),
          ContextEstimator.kImageTokens);
    });

    test('两张图就是 2048，不按字符数也不按文件大小', () {
      const base = Message(
          id: '1', sessionId: 's', role: 'user', content: 'x', createdAt: 1);
      const twoImages = Message(
          id: '2',
          sessionId: 's',
          role: 'user',
          content: 'x',
          createdAt: 2,
          attachments: ['C:/tmp/a.png', 'C:/tmp/b.png']);
      expect(ContextEstimator.estimateMessage(twoImages) -
              ContextEstimator.estimateMessage(base),
          2 * ContextEstimator.kImageTokens);
    });

    test('工具轮里的图片也按张数计（库里只有路径，没字节可数）', () {
      const withoutImage =
          '[{"id":"tc1","toolName":"read_image","input":{"path":"a.png"},"result":"<path>a.png</path>"}]';
      const withImage =
          '[{"id":"tc1","toolName":"read_image","input":{"path":"a.png"},"result":"<path>a.png</path>","image":{"path":"a.png"}}]';
      final diff = ContextEstimator.estimateMessage(const Message(
              id: '2', sessionId: 's', role: 'assistant', content: '', toolCallsJson: withImage, createdAt: 2)) -
          ContextEstimator.estimateMessage(const Message(
              id: '1', sessionId: 's', role: 'assistant', content: '', toolCallsJson: withoutImage, createdAt: 1));
      // 差值是 1024 **加上** `"image":{"path":"a.png"}` 这一小段 JSON 自身的文字成本
      // （几个 token），所以这里断言的是"至少 1024 且多出来的只是那点文字"，
      // 不去钉死一个精确值 —— 精确的那条断言在下面"用户消息带一张图恰好多 1024"里。
      expect(diff, greaterThanOrEqualTo(ContextEstimator.kImageTokens));
      expect(diff - ContextEstimator.kImageTokens,
          lessThan(ContextEstimator.estimateTokens(withImage)));
    });

    test('API 格式消息里的 image 块：base64 正文不计，只按张数计', () {
      // 同一张图，把 base64 换成 100 倍长 —— 估算值必须完全不变（精确相等，这是关键性质）
      Map<String, dynamic> apiImage(String data) => {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '看图'},
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/png', 'data': data},
              },
            ],
          };
      final small = ContextEstimator.estimateApiMessages([apiImage('AAAA')]);
      final huge = ContextEstimator.estimateApiMessages([apiImage('A' * 400)]);
      expect(huge, small,
          reason: 'base64 正文的长度不该影响估算，否则一张大截图会把占用环顶爆');

      final textOnly = ContextEstimator.estimateApiMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图'},
          ],
        }
      ]);
      // 同上的口径：多出来的主要是 1024，另有 `{"type":"image"}` 这一小段文字成本
      expect(small - textOnly, greaterThanOrEqualTo(ContextEstimator.kImageTokens));
    });
  });
}
