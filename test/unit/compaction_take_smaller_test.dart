import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/compaction/compaction_plan.dart';

/// 压缩取值「取小者」的判据（用户 2026-10-05 钉死的规则）。
///
/// 原文⇒一级与一级⇒二级用**同一条**规则：把「压缩前」和「压缩后」的 token 数比一下，
/// 取较小的那一侧作为**下一级**的内容。判据是**严格小于** —— 压缩后的实测值必须真的
/// 比压缩前小才采用它；两边相等时取压缩前那一侧（压缩一点没变小，就没有理由引入一条
/// 摘要）。
///
/// 每条断言之前都先把输入与返回值打印出来，运行者能看出它实际算的是什么。
void main() {
  group('压缩取值：取小者', () {
    test('压缩后更小 ⇒ 用摘要那一侧', () {
      const before = 6000; // 压缩前（原文那一侧是估算值）
      const after = 1500; // 压缩后（模型回的实测 output_tokens）
      final win = CompactionEngine.summarySideWins(before, after);
      // ignore: avoid_print
      print('[取小者] 压缩前=$before 压缩后=$after '
          '⇒ summarySideWins=$win（期望 true：用摘要）');
      expect(win, isTrue,
          reason: '压缩后更小 ⇒ 下一级的内容取摘要那一侧');
    });

    test('压缩后更大 ⇒ 用压缩前那一侧', () {
      const before = 6000;
      const after = 9000;
      final win = CompactionEngine.summarySideWins(before, after);
      // ignore: avoid_print
      print('[取小者] 压缩前=$before 压缩后=$after '
          '⇒ summarySideWins=$win（期望 false：用压缩前那一侧）');
      expect(win, isFalse,
          reason: '压缩后更大 ⇒ 取压缩前那一侧，不许把内容丢掉、也不许把更大的发出去');
    });

    test('两边相等 ⇒ 用压缩前那一侧', () {
      const before = 6000;
      const after = 6000;
      final win = CompactionEngine.summarySideWins(before, after);
      // ignore: avoid_print
      print('[取小者] 压缩前=$before 压缩后=$after '
          '⇒ summarySideWins=$win（期望 false：相等时取压缩前）');
      expect(win, isFalse,
          reason: '两边相等 ⇒ 压缩没有带来任何收益，不引入一条摘要');
    });
  });

  group('容量不够时可以拿掉哪一种', () {
    // 用户 2026-10-05：「我允许静默丢弃的应该只有超过上下文上限的L2级摘要，不应该有
    // 其它东西允许静默丢弃」。所以只有二级及以上、且这一趟确实按摘要发出去的条目可以
    // 因为容量被拿掉。
    test('一级摘要 ⇒ 不允许拿掉', () {
      final ok = CompactionEngine.mayBeLeftOut(level: 1, sentAsSummary: true);
      // ignore: avoid_print
      print('[可拿掉] level=1 sentAsSummary=true（一级摘要）'
          ' ⇒ mayBeLeftOut=$ok（期望 false）');
      expect(ok, isFalse,
          reason: '一级摘要不是最粗的那一层，用户只允许丢二级');
    });

    test('二级摘要（这一趟按摘要发）⇒ 允许拿掉', () {
      final ok = CompactionEngine.mayBeLeftOut(level: 2, sentAsSummary: true);
      // ignore: avoid_print
      print('[可拿掉] level=2 sentAsSummary=true（二级摘要）'
          ' ⇒ mayBeLeftOut=$ok（期望 true）');
      expect(ok, isTrue,
          reason: '最旧的二级摘要可以因为容量被拿掉（只是这次不发，库里不删）');
    });

    test('原文 ⇒ 不允许拿掉', () {
      // 按原文发的条目在代码里是 level=1 且 sentAsSummary=false（原文段的层级取缺省值）。
      final ok = CompactionEngine.mayBeLeftOut(level: 1, sentAsSummary: false);
      // ignore: avoid_print
      print('[可拿掉] level=1 sentAsSummary=false（原文）'
          ' ⇒ mayBeLeftOut=$ok（期望 false）');
      expect(ok, isFalse,
          reason: '拿掉按原文发的条目等于直接丢内容，不是换一种更粗的表示');
    });
  });
}
