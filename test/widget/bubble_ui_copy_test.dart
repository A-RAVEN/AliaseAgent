import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/message_bubble.dart';

/// 16.4：文档里标成「界面文案：」的那句提示，必须在**渲染出来的气泡上**原样出现。
///
/// 为什么要单独一条：`test/unit/user_docs_test.dart` 是拿文档里的句子去 **grep 全部 lib 源码**，
/// 而这句文案在 `chat_area.dart` 的**注释**里也出现过一次 —— 2026-10-24 实测：把
/// `message_bubble.dart` 里的真实文案整句换掉，那条守卫**仍然是绿的**（注释里还命中）。
/// 所以那条守着的是"文档与代码某处一致"，守不住"界面上真的这么写"。
///
/// 这条用例的做法：从文档里取出那句文案，渲染一个"模型未声明图片输入"的气泡，
/// 断言渲染出来的文字与文档逐字相同。改文案 ⇒ 找不到 ⇒ 红。
const _docsPath = 'Docs/user-guide/chat.md';
const _marker = '界面文案：';

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('bubble_copy_'));
  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('渲染出来的"未发送"提示与 chat.md 里标的那句逐字相同', (tester) async {
    // 1) 从文档里取出那句文案（形如：界面文案：`xxx`）
    final lines = File(_docsPath).readAsLinesSync();
    final quotes = <String>[];
    for (final line in lines) {
      final i = line.indexOf(_marker);
      if (i < 0) continue;
      final rest = line.substring(i + _marker.length);
      final open = rest.indexOf('`');
      final close = open < 0 ? -1 : rest.indexOf('`', open + 1);
      if (open >= 0 && close > open) {
        quotes.add(rest.substring(open + 1, close));
      }
    }
    final expected = quotes
        .where((q) => q.contains('模型未声明图片输入'))
        .toList();
    // ignore: avoid_print
    print('  [OBS] 文档里标出的界面文案共 ${quotes.length} 条，其中"未发送"提示 '
        '$expected');
    expect(expected, hasLength(1),
        reason: '$_docsPath 必须用「界面文案：`…`」标出那句提示，且只标一次');

    // 2) 渲染一个"模型未声明图片输入"的气泡
    final png = File('${tempDir.path}${Platform.pathSeparator}p.png')
      ..writeAsBytesSync(base64Decode(_onePixelPngBase64));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          role: 'user',
          content: '看看这张',
          imagePaths: [png.path],
          imagesSent: false,
        ),
      ),
    ));
    await tester.pump();

    // 3) 界面上必须逐字出现那句
    expect(find.text(expected.single), findsOneWidget,
        reason: '气泡上渲染的文字必须与文档里标的那句一字不差；'
            '改掉 message_bubble.dart 里的文案后这条必须红');
  });
}
