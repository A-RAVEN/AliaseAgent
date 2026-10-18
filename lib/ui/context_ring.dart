import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/ui/compaction_status_banner.dart';

/// 环的尺寸、描边与半径 —— **来源**：用户点名的那个参照物。
///
/// 用户原话要的是「类似 dsh 这样的一个圆环」，dsh 的实现里这几个数就是
/// `dsh-client-ui-conversation/lib/client.js` 里 `ContextMeter` 的
/// `viewBox "0 0 14 14"`、`RADIUS = 5.5`、`transform: rotate(-90 7 7)`。
/// 照参照物取数，不是我定的。
const double contextRingDiameter = 14; // 逻辑像素
const double contextRingStroke = 2;
const double contextRingRadius = 5.5;

/// 三段用哪种画法：**实心扇形**。
///
/// 这不是随手定的：细描边弧在 4.5% 那一档只有 1.6 像素长，等于看不见（design D10 有算术）。
/// 把它提成一个公开常量，是为了让"三段确实是实心"这件事能被一条命令核到（tasks 9.10），
/// 而不是只能靠肉眼。
const PaintingStyle contextRingSegmentStyle = PaintingStyle.fill;

/// 上下文占用环：整圈 = 模型窗口，三段首尾相接，从 12 点起顺时针
/// 二级摘要 → 一级摘要 → 原文（design D4）。**不含**系统提示词与工具定义（D5）。
///
/// [breakdown] 为 null（还没捕获过 / 窗口未知）时渲染成不占高度的空盒子（D7）。
class ContextRing extends StatelessWidget {
  final ContextBreakdown? breakdown;

  /// 点一下弹只读面板（D6）。为 null 时不接这个回调。
  final VoidCallback? onTap;

  const ContextRing({super.key, required this.breakdown, this.onTap});

  @override
  Widget build(BuildContext context) {
    final b = breakdown;
    if (b == null || b.windowTokens <= 0) return const SizedBox.shrink();
    final ring = SizedBox(
      width: contextRingDiameter,
      height: contextRingDiameter,
      child: CustomPaint(
        painter: _RingPainter(
          breakdown: b,
          scheme: Theme.of(context).colorScheme,
        ),
      ),
    );
    // 默认点击就弹只读面板（D6）；调用方想换行为可以传 onTap。
    return InkWell(
      onTap: onTap ?? () => ContextRing.showPanel(context, b),
      customBorder: const CircleBorder(),
      child: ring,
    );
  }

  /// 点开后的只读面板（design D6）：逐行给数字，每行标明它是实测还是估算。
  ///
  /// token 数写原始整数，不做 K / 万 缩写（D8）—— 缩写会再引一层四舍五入，而这个面板
  /// 就是拿来核对数字的。底部那句复用「真实上下文」那一屏的原句，两处说同一句话。
  static Future<void> showPanel(BuildContext context, ContextBreakdown b) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('上下文占用'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _panelRow('二级摘要', '${b.level2Tokens}', '实测'),
              _panelRow('一级摘要', '${b.level1Tokens}', '实测'),
              _panelRow('原文', '${b.rawTokens}', '估算'),
              _panelRow('系统提示词 + 工具定义', '${b.fixedOverheadTokens}',
                  '估算（环上不含这一行）'),
              _panelRow('合计', '${b.usedTokens}', '上面各项相加'),
              _panelRow(
                '占模型窗口',
                // 只给**一个**百分比（用户 2026-10-16 裁定），分子与环旁那个数字同口径 ——
                // 直接复用 labelOf，两处就不可能不一致；分母是窗口。
                ContextRingLabeled.labelOf(b) ?? '窗口未知',
                '——',
              ),
              const SizedBox(height: 12),
              const Text(CompactionStatusBanner.contextViewNote),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static Widget _panelRow(String label, String value, String source) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 160, child: Text(label)),
            Text(value),
            const SizedBox(width: 8),
            Text(source, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}

/// 环 + 它**左边**那个百分比数字。
///
/// 数字**不放进 [ContextRing] 内部**：那会把 `find.byType(ContextRing)` 的尺寸从 14×14 顶掉，
/// 而 `test/widget/context_ring_test.dart` 里有 5 处断言正是按 14×14 比的（tasks 9.2）。
/// 所以数字是这个包装里的**兄弟节点**，`ContextRing` 自己还是 14×14。
class ContextRingLabeled extends StatelessWidget {
  final ContextBreakdown? breakdown;

  /// 数字与环之间的间距。
  ///
  /// **这个数是我选的**（AGENTS 第 9 节要求上下限/尺寸可溯源，这里给不出四类来源之一）：
  /// 取 6 是想让它读起来像"贴着环"，不要再挤到环上。要改成别的值，说一句即可。
  static const double labelGap = 6;

  const ContextRingLabeled({super.key, required this.breakdown});

  /// 这一轮占用的百分比文本：分子是**环上三段之和**（不是四项合计），两位小数 + `%`。
  ///
  /// 返回 null 表示这一轮没有可显示的数（没有拆分 / 窗口未知）—— 那时数字不出现。
  static String? labelOf(ContextBreakdown? b) {
    if (b == null || b.windowTokens <= 0) return null;
    return '${(b.conversationTokens / b.windowTokens * 100).toStringAsFixed(2)}%';
  }

  @override
  Widget build(BuildContext context) {
    final label = labelOf(breakdown);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(width: labelGap),
        ],
        ContextRing(breakdown: breakdown),
      ],
    );
  }
}

/// 画轨道整圈 + 三段弧。颜色取自主题（D9），**不写死十六进制**。
class _RingPainter extends CustomPainter {
  final ContextBreakdown breakdown;
  final ColorScheme scheme;

  _RingPainter({required this.breakdown, required this.scheme});

  /// 三段各自的颜色，顺序与 [ContextBreakdown.ringSegments] 一致（二级 → 一级 → 原文）。
  List<Color> get _segmentColors =>
      [scheme.primary, scheme.tertiary, scheme.outline];

  Color get _trackColor => scheme.surfaceContainerHighest;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: contextRingRadius);
    canvas.drawCircle(
      center,
      contextRingRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = contextRingStroke
        ..color = _trackColor,
    );

    // 起点 12 点方向（-90°），顺时针累加。
    var start = -math.pi / 2;
    final segments = breakdown.ringSegments;
    final colors = _segmentColors;
    for (var i = 0; i < segments.length && i < colors.length; i++) {
      final sweep = segments[i].sweepRadians;
      if (sweep <= 0) continue;
      canvas.drawArc(
        rect,
        start,
        sweep,
        // 实心扇形要从圆心扇出来；这一段写死 true，画法统一由下面的常量决定。
        true,
        Paint()
          ..style = contextRingSegmentStyle
          ..strokeWidth = contextRingStroke
          ..color = colors[i],
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.breakdown != breakdown || oldDelegate.scheme != scheme;
}
