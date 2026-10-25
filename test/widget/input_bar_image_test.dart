import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/input_bar.dart';

/// 16.2：待发附件条的位置与单删。
///
/// 判据有两半：
/// 1. 附件条在输入框**上方**（条的 `top` 小于输入框的 `top`），不是塞在输入框右侧；
/// 2. 每张缩略图右上角的删除只删**自己那张** —— 传进来的下标必须是这一张的下标。
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGA'
    'hKmMIQAAAABJRU5ErkJggg==';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('input_bar_img_'));
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

  Widget wrap({
    required TextEditingController controller,
    required List<String> paths,
    required void Function(int) onRemove,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: InputBar(
            controller: controller,
            onSubmit: () {},
            pendingImagePaths: paths,
            onRemoveImage: onRemove,
          ),
        ),
      ),
    );
  }

  testWidgets('附件条在输入框上方，不在输入框里或右侧', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final paths = [writePng('a.png'), writePng('b.png')];

    await tester.pumpWidget(wrap(controller: controller, paths: paths, onRemove: (_) {}));
    await tester.pump();

    final stripRect = tester.getRect(find.byType(SingleChildScrollView).first);
    final fieldRect = tester.getRect(find.byType(TextField));
    // ignore: avoid_print
    print('  [OBS] 附件条 top=${stripRect.top}  输入框 top=${fieldRect.top}');
    expect(stripRect.top, lessThan(fieldRect.top),
        reason: '附件条必须在输入框上方（条的 top 小于输入框 top）');
    expect(find.byType(Image), findsNWidgets(2), reason: '两张图各渲染一个缩略图');
  });

  testWidgets('删除按钮只删自己那张：两张时删右边那张传下标 1，剩一张时删它传下标 0',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final paths = [writePng('a.png'), writePng('b.png')];
    final removed = <int>[];

    await tester.pumpWidget(wrap(
      controller: controller,
      paths: paths,
      onRemove: removed.add,
    ));
    await tester.pump();

    // 两个删除按钮，按下标顺序排列；点第二个 ⇒ 必须传 1（不是写死的 0）
    final deletes = find.byTooltip('移除这张图');
    expect(deletes, findsNWidgets(2));
    await tester.tap(deletes.at(1));
    await tester.pump();
    // ignore: avoid_print
    print('  [OBS] 两张时点第二个删除 ⇒ 回调收到 $removed');
    expect(removed, [1], reason: '点第二张的删除必须传下标 1（写死 0 会把左边那张删掉）');

    // 只剩一张时，唯一那个删除传 0
    removed.clear();
    await tester.pumpWidget(wrap(
      controller: controller,
      paths: [paths.first],
      onRemove: removed.add,
    ));
    await tester.pump();
    final deletes1 = find.byTooltip('移除这张图');
    expect(deletes1, findsOneWidget);
    await tester.tap(deletes1);
    await tester.pump();
    // ignore: avoid_print
    print('  [OBS] 一张时点删除 ⇒ 回调收到 $removed');
    expect(removed, [0]);
  });
}
