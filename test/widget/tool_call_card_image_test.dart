// `read_image` 的工具卡片（add-image-input 任务 11.3）。
//
// 四条：收起状态就有图 + 元数据行、展开状态能看到文字信封、重载（走 toJson/fromJson
// 回环）后图还在、"持久化的 activity 里没有元数据"，外加尺寸上界。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/ui/tool_call_card.dart';

const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

const _envelope = '<path>pic.png</path>\n<type>image</type>\n<content>\n'
    'image/png image, 1x1 px, 68 bytes\n</content>';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('card_img_test_');
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

  ToolCallActivity readImageActivity(String path) => ToolCallActivity(
        id: 'tc-img',
        toolName: 'read_image',
        input: {'path': 'pic.png'},
        status: ToolCallStatus.done,
        result: _envelope,
        // 真实路径里 result 与 resultPreview 是一起写进去的（copyWith 那两个参数），
        // 卡片的折叠/展开开关正是看 resultPreview 有没有值。
        resultPreview: '<path>pic.png</path>',
        imagePath: path,
      );

  testWidgets('收起状态就有缩略图 + 元数据行，且尺寸有上界', (tester) async {
    final path = writePng();
    await tester.pumpWidget(_wrap(ToolCallCard(activity: readImageActivity(path))));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget,
        reason: '不展开也要看得见模型看到的那张图');

    // 标题只显示路径
    expect(find.text('read_image(pic.png)'), findsOneWidget);

    // 元数据行来自信封
    expect(find.text('image/png · 1×1 · 68 字节'), findsOneWidget);

    // 尺寸上界 600×400
    final constraints = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((b) => b.constraints)
        .where((c) => c.maxWidth == 600 && c.maxHeight == 400)
        .toList();
    // ignore: avoid_print
    print('  [OBS] 600×400 的容器数=${constraints.length}');
    expect(constraints, isNotEmpty, reason: '图必须显式限到 600×400');
  });

  testWidgets('展开后能看到文字信封', (tester) async {
    final path = writePng();
    await tester.pumpWidget(_wrap(ToolCallCard(activity: readImageActivity(path))));
    await tester.pump();

    expect(find.textContaining('<type>image</type>'), findsNothing,
        reason: '收起时不占地方');

    await tester.tap(find.text('Expand result'));
    await tester.pump();

    expect(find.textContaining('<type>image</type>'), findsOneWidget,
        reason: '展开后要能看到那段文字信封');
    expect(find.byType(Image), findsOneWidget, reason: '展开后图仍然在');
  });

  testWidgets('重载：走 toJson/fromJson 回环后图还在', (tester) async {
    final path = writePng();
    final original = readImageActivity(path);
    // 这就是"存进 messages.tool_calls 再读出来"的那条路
    final restored =
        ToolCallActivity.fromJson(jsonDecode(jsonEncode(original.toJson()))
            as Map<String, dynamic>);

    await tester.pumpWidget(_wrap(ToolCallCard(activity: restored)));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('image/png · 1×1 · 68 字节'), findsOneWidget,
        reason: '元数据从已落库的 result 信封解析，不靠额外字段');
  });

  testWidgets('持久化的 activity 里 image 只有 path 一个键', (tester) async {
    final path = writePng();
    final json = readImageActivity(path).toJson();
    final image = json['image'] as Map<String, dynamic>;
    // ignore: avoid_print
    print('  [OBS] 持久化的 image => $image');
    expect(image.keys.toList(), ['path']);
  });

  testWidgets('文件被删：卡片显示 [图片已丢失：<path>]', (tester) async {
    final path = writePng();
    File(path).deleteSync();
    await tester.pumpWidget(_wrap(ToolCallCard(activity: readImageActivity(path))));
    // 读文件是真实 I/O，要让 runAsync 真跑一次
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('[图片已丢失：$path]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
