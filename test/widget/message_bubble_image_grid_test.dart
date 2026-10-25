import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/message_bubble.dart';

/// 16.7：多图布局按 DeepSeek 官方规格定的尺寸。
///
/// 尺寸链（见 tasks.md 16.7）：每格 294×194 = (600−12)/2 × (400−12)/2，间距 6 沿用
/// 产品既有的 `SizedBox(height: 6)`；两行 (194+6)×2 = 400 = 既有的 `maxImageHeight`，
/// 所以气泡不会因为附图多而被撑破。超过 4 张时第 4 格盖「+N」，点开进查看层。
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('grid_img_'));
  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  String writePng(String name) {
    final f = File('${tempDir.path}${Platform.pathSeparator}$name');
    f.writeAsBytesSync(base64Decode(_onePixelPngBase64));
    return f.path;
  }

  Future<void> pumpWithImages(WidgetTester tester, List<String> paths) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          MessageBubble(role: 'user', content: '', imagePaths: paths),
        ]),
      ),
    ));
    await tester.pump();
  }

  testWidgets('5 张图只排 4 格、第 4 格显示「+1」、气泡总高不超过 400', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final paths = [for (var i = 0; i < 5; i++) writePng('p$i.png')];
    await pumpWithImages(tester, paths);

    // 只渲染 4 张 Image（第 5 张被折起来）
    expect(find.byType(Image), findsNWidgets(4),
        reason: '一条消息最多显示 4 格，第 5 张及以后折进「+N」');
    expect(find.text('+1'), findsOneWidget, reason: '5 张时第 4 格应显示 +1');

    // 气泡（带 primaryContainer 底色的那个容器）总高不超过 400
    final bubble = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere((c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color != null &&
            (c.constraints?.maxWidth == 600));
    expect(bubble.constraints!.maxWidth, 600);
    final bubbleSize = tester.getSize(find.byWidget(bubble));
    // ignore: avoid_print
    print('  [OBS] 5 张图：Image 个数=4，气泡高=${bubbleSize.height}，'
        '格宽=${(MessageBubble.maxImageWidth - 12) / 2}');
    expect(bubbleSize.height, lessThanOrEqualTo(MessageBubble.maxImageHeight),
        reason: '两行图的高度合计必须 ≤ 400（否则气泡会被图撑走）');
  });

  testWidgets('单张图仍然走 600×400 的原路径，不是被压成半格', (tester) async {
    await pumpWithImages(tester, [writePng('one.png')]);
    final limits = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((b) => b.constraints)
        .where((c) => c.maxHeight > 0 && c.maxHeight != double.infinity)
        .toList();
    // ignore: avoid_print
    print('  [OBS] 单张图限高容器=${limits.map((c) => '${c.maxWidth}x${c.maxHeight}').toList()}');
    expect(
      limits.any((c) =>
          c.maxWidth == MessageBubble.maxImageWidth &&
          c.maxHeight == MessageBubble.maxImageHeight),
      isTrue,
      reason: '单张图不该被当作网格的一格（300 宽），仍用 600×400',
    );
  });

  testWidgets('「+N」那格点开后落到查看层，并显示 4/5', (tester) async {
    final paths = [for (var i = 0; i < 5; i++) writePng('q$i.png')];
    await pumpWithImages(tester, paths);

    final inkWell = tester.widget<InkWell>(
        find.byKey(ValueKey('bubble-image-${paths[3]}')));
    inkWell.onTap!();
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('  [OBS] 点第 4 格后 查看层存在=${find.byKey(imageViewerKey).evaluate().isNotEmpty}，'
        '页码文案=${find.text('4/5').evaluate().isNotEmpty}');
    expect(find.byKey(imageViewerKey), findsOneWidget);
    expect(find.text('4/5'), findsOneWidget, reason: '「+N」点开应落在第 4 张，并标出 4/5');
    expect(find.byTooltip('下一张'), findsOneWidget, reason: '还有第 5 张，可以往后翻');
  });
}
