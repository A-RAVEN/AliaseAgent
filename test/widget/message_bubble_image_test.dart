// 用户消息气泡里的附件图（add-image-input 任务 11.1）。
//
// 四条：正常显示且尺寸有上界、文件缺失回落成可见文本、模型未声明图片输入时多一行提示、
// 怪路径不抛异常。尺寸上界用的是既有常量（气泡 600 宽、卡片 400 高），不是新发明的。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/message_bubble.dart';

/// 1×1 的合法 PNG。
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bubble_img_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  String writePng() {
    final file = File('${tempDir.path}${Platform.pathSeparator}pic.png');
    file.writeAsBytesSync(base64Decode(_onePixelPngBase64));
    return file.path;
  }

  testWidgets('正常显示：有 Image，且受 600×400 的上界约束', (tester) async {
    final path = writePng();
    await tester.pumpWidget(_wrap(MessageBubble(
      role: 'user',
      content: '看看这张',
      imagePaths: [path],
    )));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    // 文字也在
    expect(find.text('看看这张'), findsOneWidget);

    // 找那个包着图的 ConstrainedBox，断言上界就是我们说的那两个数
    final boxes = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((b) => b.constraints)
        .where((c) => c.maxHeight != double.infinity && c.maxHeight > 0)
        .toList();
    // ignore: avoid_print
    print('  [OBS] 带有限高的 ConstrainedBox => '
        '${boxes.map((c) => '${c.maxWidth}x${c.maxHeight}').toList()}');
    expect(
      boxes.any((c) =>
          c.maxWidth == MessageBubble.maxImageWidth &&
          c.maxHeight == MessageBubble.maxImageHeight),
      isTrue,
      reason: '图的容器必须显式限到 ${MessageBubble.maxImageWidth}×'
          '${MessageBubble.maxImageHeight}',
    );
    expect(MessageBubble.maxImageWidth, 600);
    expect(MessageBubble.maxImageHeight, 400);
  });

  testWidgets('文件被删：显示 [图片已丢失：<path>]，不抛异常', (tester) async {
    final path = writePng();
    File(path).deleteSync();

    await tester.pumpWidget(_wrap(MessageBubble(
      role: 'user',
      content: '这张图没了',
      imagePaths: [path],
    )));
    // 图片读取失败走的是**真实文件 I/O**：`pump()` 只推帧不推真实异步，
    // 所以要用 `runAsync` 让那次 I/O 真的跑完，再推一帧让 errorBuilder 落地。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('[图片已丢失：$path]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('模型未声明图片输入：多一行提示', (tester) async {
    final path = writePng();
    await tester.pumpWidget(_wrap(MessageBubble(
      role: 'user',
      content: '看看',
      imagePaths: [path],
      imagesSent: false,
    )));
    await tester.pump();

    expect(find.text('模型未声明图片输入，本次没有发送图片'), findsOneWidget);
  });

  testWidgets('声明了图片输入时不出现那行提示', (tester) async {
    final path = writePng();
    await tester.pumpWidget(_wrap(MessageBubble(
      role: 'user',
      content: '看看',
      imagePaths: [path],
    )));
    await tester.pump();

    expect(find.text('模型未声明图片输入，本次没有发送图片'), findsNothing);
  });

  testWidgets('只有图片、没有文字：气泡仍然渲染（不是空盒子）', (tester) async {
    final path = writePng();
    await tester.pumpWidget(_wrap(ChatBubbleHarness(path: path)));
    await tester.pump();

    expect(find.byType(MessageBubble), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
  });
}

/// 直接渲染一个"只有图片"的消息气泡。
class ChatBubbleHarness extends StatelessWidget {
  final String path;
  const ChatBubbleHarness({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    return MessageBubble(role: 'user', content: '', imagePaths: [path]);
  }
}
