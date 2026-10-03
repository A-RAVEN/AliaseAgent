import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/compaction_status.dart';

/// 压缩状态模型：界面文案与"空闲"的判断。
///
/// 这些文案就是用户界面上看到的那句话，所以逐字钉住 —— 文档里引用的也是同一句
/// （见 `test/unit/user_docs_test.dart` 的界面文案守卫）。
void main() {
  group('CompactionStatus（压缩进行中的状态）', () {
    test('空闲：不空闲判断为真、没有文案、没有附注', () {
      // ignore: avoid_print
      print('  [OBS] idle.isIdle=${CompactionStatus.idle.isIdle} '
          'label=${CompactionStatus.idle.label} note=${CompactionStatus.idle.note}');
      expect(CompactionStatus.idle.isIdle, isTrue);
      expect(CompactionStatus.idle.label, isNull,
          reason: '空闲时没有可显示的话，界面据此不渲染任何东西');
      expect(CompactionStatus.idle.note, isNull);
    });

    test('挑选分段主题：只有阶段，没有段号', () {
      final s = CompactionStatus.seam();
      // ignore: avoid_print
      print('  [OBS] seam: label="${s.label}" note=${s.note}');
      expect(s.isIdle, isFalse);
      expect(s.label, '正在挑选分段主题');
      expect(s.note, isNull, reason: '发送前那次压缩不显示"让路"那句');
    });

    test('后台压缩要说明"发消息会让它先让路"', () {
      final s = CompactionStatus.level1(segment: 1, total: 9, background: true);
      // ignore: avoid_print
      print('  [OBS] 后台: label="${s.label}" note="${s.note}"');
      expect(s.note, '你发消息会让压缩先让路');
      expect(s.label, isNot(contains('让路')),
          reason: '"让路"那句是附注，不混进阶段文案里');
    });

    test('一级摘要：总数已知给"共几段"，未知就不给分母（两种文案必须不同）', () {
      final known = CompactionStatus.level1(segment: 3, total: 9);
      final unknown = CompactionStatus.level1(segment: 3);
      // ignore: avoid_print
      print('  [OBS] 总数已知: "${known.label}"；总数未知: "${unknown.label}"');
      expect(known.label, '正在压缩较早的对话：正在生成第 3 段摘要，共 9 段');
      expect(unknown.label, '正在压缩较早的对话：正在生成第 3 段摘要');
      expect(unknown.label, isNot(known.label),
          reason: '总数从 9 改成未知，文案必须跟着变 —— 这条对照证明上面那条'
              '不是恒真（把 total 写死成 9 也照样"通过"）');
    });

    test('二级摘要：阶段说法与一级不同，段号照常显示', () {
      final s = CompactionStatus.level2(segment: 2, total: 3);
      // ignore: avoid_print
      print('  [OBS] level2: "${s.label}"');
      expect(s.label, '正在把一级摘要合成二级摘要：正在生成第 2 段，共 3 段');
      expect(s.label, isNot(contains('较早的对话')),
          reason: '合成二级摘要与压原文是两件事，文案不许混');
    });
  });
}
