// 用户消息气泡里的附件图（add-image-input 任务 11.1）。
//
// 四条：正常显示且尺寸有上界、文件缺失回落成可见文本、模型未声明图片输入时多一行提示、
// 怪路径不抛异常。尺寸上界用的是既有常量（气泡 600 宽、卡片 400 高），不是新发明的。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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

  testWidgets('16.1 附图靠用户侧：图与文字右边缘对齐，整组在右半侧；助手仍在左',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final path = writePng();
    // 产品里气泡由 `chat_area.dart` 的 ListView.builder 承载 —— ListView 会给子项
    // **满宽**约束，气泡才有"靠右"的余地。直接塞进 Scaffold body 拿到的是松约束，
    // 量出来的位置会偏左（第一版就是这么错判的），所以这里用 ListView 复现真实环境。
    Widget listWrap(Widget child) =>
        MaterialApp(home: Scaffold(body: ListView(children: [child])));

    // 用户消息：靠右
    await tester.pumpWidget(listWrap(MessageBubble(
      role: 'user',
      content: '这句话比一个像素宽得多，用来当右边缘的参照物',
      imagePaths: [path],
    )));
    await tester.pump();
    final imgRect = tester.getRect(find.byType(Image));
    final txtRect = tester.getRect(find.text('这句话比一个像素宽得多，用来当右边缘的参照物'));
    // ignore: avoid_print
    print('  [OBS] 用户消息：图 right=${imgRect.right} 文字 right=${txtRect.right} '
        '窗口宽=${tester.view.physicalSize.width}');
    expect(imgRect.right, closeTo(txtRect.right, 0.5),
        reason: '附图的右边缘必须与同一消息文字的右边缘对齐（CrossAxisAlignment.end）');
    expect(imgRect.right, greaterThan(400),
        reason: '整组必须落在窗口右半侧（窗口 800，右半侧起点 400）');

    // 助手消息：仍在左
    await tester.pumpWidget(listWrap(MessageBubble(
      role: 'assistant',
      content: '这是助手的回复，也比一个像素宽得多',
      imagePaths: [path],
    )));
    await tester.pump();
    final imgLeft = tester.getRect(find.byType(Image));
    final txtLeft = tester.getRect(find.text('这是助手的回复，也比一个像素宽得多'));
    // ignore: avoid_print
    print('  [OBS] 助手消息：图 left=${imgLeft.left} 文字 left=${txtLeft.left}');
    expect(imgLeft.left, closeTo(txtLeft.left, 0.5),
        reason: '助手消息里附图与文字应左对齐（CrossAxisAlignment.start）');
    expect(imgLeft.left, lessThan(400), reason: '助手消息必须留在左半侧');
  });

  testWidgets('16.5 点缩略图打开全窗查看层，Esc 能关掉', (tester) async {
    final path = writePng();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          MessageBubble(role: 'user', content: '看看这张', imagePaths: [path]),
        ]),
      ),
    ));
    await tester.pump();

    expect(find.byKey(imageViewerKey), findsNothing, reason: '一开始不该有查看层');
    // 测试图是 1×1 的 PNG，在 widget 测试里没解码完 ⇒ 缩略图命中区域接近 0 像素，
    // `tester.tap` 派不出去（不是产品问题）。所以直接取缩略图外层的 InkWell 并调用它的
    // onTap —— 这样仍然能证明"点击**接到了**打开查看层"，而且一旦有人把 InkWell 删掉，
    // 这里连 widget 都找不到，会直接红。
    final inkWell = tester.widget<InkWell>(
        find.byKey(ValueKey('bubble-image-$path')));
    expect(inkWell.onTap, isNotNull, reason: '缩略图必须挂着点击回调');
    inkWell.onTap!();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 点缩略图后 查看层存在=${find.byKey(imageViewerKey).evaluate().isNotEmpty}');
    expect(find.byKey(imageViewerKey), findsOneWidget,
        reason: '点缩略图必须打开覆盖整窗的查看层（外层要有 InkWell）');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 按 Esc 后 查看层存在=${find.byKey(imageViewerKey).evaluate().isNotEmpty}');
    expect(find.byKey(imageViewerKey), findsNothing, reason: 'Esc 必须能关掉查看层');
  });

  testWidgets('16.3 附图不吃掉气泡视觉：尺寸受 600×400 约束且气泡底色仍在',
      (tester) async {
    final path = writePng();
    final scheme = ColorScheme.fromSeed(seedColor: Colors.blue);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(colorScheme: scheme),
      home: Scaffold(
        body: MessageBubble(
          role: 'user',
          content: '看看',
          imagePaths: [path],
        ),
      ),
    ));
    await tester.pump();

    // 断言"约束"而不是"渲染出来的尺寸"：1×1 的测试图在 widget 测试里未解码完，
    // 渲染尺寸会是 0×0，那样的断言是恒真的（空断言），起不到守护作用。
    final limits = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((b) => b.constraints)
        .where((c) => c.maxHeight > 0 && c.maxHeight != double.infinity)
        .toList();
    // ignore: avoid_print
    print('  [OBS] 限高容器=${limits.map((c) => '${c.maxWidth}x${c.maxHeight}').toList()}');
    expect(
      limits.any((c) =>
          c.maxWidth == MessageBubble.maxImageWidth &&
          c.maxHeight == MessageBubble.maxImageHeight),
      isTrue,
      reason: '附图必须显式限到 600×400，否则一张 4000×3000 的截图会把对话推走',
    );
    // 同时钉住常量的**数值**：只比常量自己会变成恒真断言（把常量改成 100000 也绿）。
    expect(MessageBubble.maxImageWidth, 600);
    expect(MessageBubble.maxImageHeight, 400);

    final bubbleColors = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .toList();
    expect(bubbleColors.contains(scheme.primaryContainer), isTrue,
        reason: '图必须包在带 primaryContainer 底色的气泡里，不能是一张裸图');
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
