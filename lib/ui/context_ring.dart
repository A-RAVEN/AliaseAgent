import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:alias_agent/models/context_breakdown.dart';
import 'package:alias_agent/ui/compaction_status_banner.dart';

/// 环的尺寸与描边。
///
/// **直径 20 是用户 2026-10-18 明说的**（原话「可以 20」），不是从参照物量出来的 ——
/// 原来那个 14 才来自用户点名的 dsh 参照物，而本机实测用户自己 dsh 窗口里那个环只有
/// **19 物理像素 ≈ 15.2 逻辑像素**（`AppliedDPI = 120`，见 design D4），比 14 只大 1～2
/// 像素，照它放大根本不会显眼，所以用户改成了 20。
///
/// 半径由前两者**算出**（描边以内切圆为准），不再单独写一个来路不明的数。
const double contextRingDiameter = 20; // 逻辑像素
const double contextRingStroke = 2;
const double contextRingRadius = (contextRingDiameter - contextRingStroke) / 2;

/// 三段的颜色：**用户 2026-10-18 要求"鲜艳、必须能分辨"**。
///
/// 原来取的是主题的 `primary` / `tertiary` / `outline`，但那三个在 Material 3 默认配色下
/// 是紫 / 酱红 / 灰 —— 饱和度和色相都太接近，20 像素的环上肉眼分不开（用户原话：
/// 「你这个紫和深红我真的看不出来」）。
///
/// 现在改成三个自己定的高饱和色，色相两两相差 ≥ 60°（蓝 224° / 橙 26° / 绿 145°），
/// 这条由 `test/widget/context_ring_test.dart` 里的色相判据守着。
const Color contextRingLevel2Color = Color(0xFF2962FF); // 蓝（二级摘要）
const Color contextRingLevel1Color = Color(0xFFFF6D00); // 橙（一级摘要）
const Color contextRingRawColor = Color(0xFF00C853); // 绿（原文）

/// 轨道的颜色。**2026-10-18 从 `surfaceContainerHighest` 换掉** —— 那个颜色在近黑背景上
/// 几乎同色，真机截图里整圈等于隐形（放大 12 倍才认得出）。
///
/// 用的是 `onSurfaceVariant` 而不是更暗的 `outlineVariant`：后者虽然比旧色亮一点，
/// 但与背景的对比度只有约 1.6:1，仍低于 WCAG 2.1 SC 1.4.11 对非文本内容要求的 3:1
/// （[test/widget/context_ring_test.dart] 里那条用例就是按 3:1 卡的）。
///
/// 提成公开常量是为了让控件用例能读到它：原来它是私有 getter `_trackColor`，
/// 测试拿不到就没有观测通道，"换掉这个颜色"也就写不成一条能失败的判据。
Color contextRingTrackColor(ColorScheme scheme) => scheme.onSurfaceVariant;

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
/// 所以数字是这个包装里的**兄弟节点**，`ContextRing` 自己还是它自己的边长（现在是 20×20）。
class ContextRingLabeled extends StatelessWidget {
  final ContextBreakdown? breakdown;

  /// 数字与环之间的间距。
  ///
  /// **由描边常量推导**（`contextRingStroke * 2` = 4），不再写成我随手挑的 6 ——
  /// AGENTS 第 9 节要求尺寸能溯源，而"描边的两倍"至少指得出它是从哪个已有常量来的。
  static const double labelGap = contextRingStroke * 2;

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
  /// 三段各自的颜色，顺序与 [ContextBreakdown.ringSegments] 一致（二级 → 一级 → 原文）。
  ///
  /// 高饱和三色（用户 2026-10-18：「用鲜艳点的颜色」）—— 见文件顶部的常量说明。
  List<Color> get _segmentColors => const [
        contextRingLevel2Color,
        contextRingLevel1Color,
        contextRingRawColor,
      ];

  Color get _trackColor => contextRingTrackColor(scheme);

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
