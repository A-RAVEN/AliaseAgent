import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/ui/context_ring.dart';

/// 把环渲染成 PNG 供人眼看（tasks 11.4）。
///
/// 数据是真实的 [ContextBreakdown]、控件是真实的 [ContextRing]，唯一"非真机"的地方是
/// **不经过真机投影** —— 三级摘要那一段在真机上不可达（见 tasks 11.1 的四次实测）。
Future<void> _shoot(
  WidgetTester tester,
  ContextBreakdown breakdown,
  String name,
) async {
  final key = GlobalKey();
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.blue,
      brightness: Brightness.dark,
    ),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: key,
          child: ContextRingLabeled(breakdown: breakdown),
        ),
      ),
    ),
  ));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    // 放大 8 倍：环本身只有 20 逻辑像素，1:1 出图看不清分段。
    final image = await boundary.toImage(pixelRatio: 8);
    // 必须指定 png 格式：默认是裸 RGBA，直接写进 .png 会得到一张坏图（这次踩过）。
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('test/live_visual/$name.png')
        .writeAsBytesSync(data!.buffer.asUint8List());
  });
  // ignore: avoid_print
  print('  [OBS] 已写出 test/live_visual/$name.png');
}

void main() {
  testWidgets('导出三段与两段的环图（供人眼查看）', (tester) async {
    // 三段：二级 1000 / 一级 2000 / 原文 3000，窗口 10000。
    await _shoot(
      tester,
      const ContextBreakdown(
        level2Tokens: 1000,
        level1Tokens: 2000,
        rawTokens: 3000,
        fixedOverheadTokens: 0,
        windowTokens: 10000,
      ),
      'ring_three_segments',
    );

    // 两段：取自压缩用例 2026-10-18 的真实读数（一级 2918 / 原文 2132 / 窗口 8660）。
    await _shoot(
      tester,
      const ContextBreakdown(
        level2Tokens: 0,
        level1Tokens: 2918,
        rawTokens: 2132,
        fixedOverheadTokens: 1676,
        windowTokens: 8660,
      ),
      'ring_two_segments',
    );
  });
}
