import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/compaction/summary_reference.dart';

SummaryReference _ref(int level, int lo, int hi, String text) =>
    SummaryReference(level: level, coveredMinSeq: lo, coveredMaxSeq: hi, text: text);

void main() {
  // 挑选规则（本变更第一条决定）：最多两条、只取覆盖范围严格早于本批的、按覆盖范围
  // 去重、输出按覆盖范围从旧到新。
  group('参考上下文的挑选规则', () {
    test('没有任何更早的摘要 ⇒ 参考为空（第一段摘要的行为与过去一致）', () {
      final picked = selectSummaryReferences(persisted: const [], batchOldestSeq: 5);
      expect(picked, isEmpty);
      // 有节点、但全都盖到了本批或更晚 ⇒ 同样为空。
      final allOverlapping = selectSummaryReferences(
        persisted: [_ref(1, 1, 4, 'A'), _ref(1, 5, 8, 'B')],
        batchOldestSeq: 3,
      );
      expect(allOverlapping, isEmpty,
          reason: 'coveredMaxSeq 不严格早于本批最旧序号的候选一律不算');
    });

    test('多条候选 ⇒ 最近的一条一级 + 层级最高那条（不同层级时两条都要）', () {
      final picked = selectSummaryReferences(
        persisted: [
          _ref(1, 1, 4, '一级(旧)'),
          _ref(1, 5, 8, '一级(新)'),
          _ref(2, 1, 8, '二级'),
        ],
        // 本批从 seq 20 开始 ⇒ 三条都合格。二级盖住两条一级 ⇒ 按覆盖范围去重后
        // 只剩二级 + …… 见下一条用例；这里换一个二级不覆盖一级的几何。
        batchOldestSeq: 20,
      );
      // 二级 1..8 盖住了"最近的一条一级"5..8 ⇒ 只留二级。
      expect(picked.length, 1);
      expect(picked.single.text, '二级');
    });

    test('较细那条被较粗那条完全盖住 ⇒ 只留较粗的（同一段不以两种文本进同一次请求）',
        () {
      final picked = selectSummaryReferences(
        persisted: [
          _ref(1, 30, 40, '一级(更近，但被更粗的盖住)'),
          _ref(2, 1, 60, '二级(盖住它)'),
        ],
        batchOldestSeq: 100,
      );
      expect(picked.length, 1);
      expect(picked.single.text, '二级(盖住它)');
    });

    test('两条互不覆盖时必须都带上：最近的一条一级 + 层级最高那条', () {
      final picked = selectSummaryReferences(
        persisted: [
          _ref(2, 1, 20, '二级(更旧、更粗)'),
          _ref(1, 41, 50, '一级(最近)'),
        ],
        batchOldestSeq: 100,
      );
      expect(picked.map((r) => r.text).toList(), ['二级(更旧、更粗)', '一级(最近)'],
          reason: '输出按覆盖范围从旧到新：先全局目标那条，再紧邻上文那条');
    });

    test('候选再多也只有两条（有界性：不随会话变长）', () {
      final many = [
        for (var i = 0; i < 5; i++) _ref(1, i * 10 + 1, i * 10 + 10, '一级$i'),
        _ref(2, 1, 30, '二级'),
      ];
      final picked = selectSummaryReferences(persisted: many, batchOldestSeq: 100);
      expect(picked.length, lessThanOrEqualTo(2),
          reason: '5 条一级 + 1 条二级也不能全带上');
      expect(picked.map((r) => r.text), contains('二级'),
          reason: '层级最高那条必须在');
    });

    test('覆盖范围与本次批次交叠的候选（例如本趟后半段才合成的二级）不得入选', () {
      final picked = selectSummaryReferences(
        persisted: [
          _ref(1, 1, 4, '合格的更早摘要'),
          _ref(2, 1, 30, '盖到本批里的二级'),
        ],
        batchOldestSeq: 5,
      );
      expect(picked.map((r) => r.text), ['合格的更早摘要'],
          reason: 'coveredMaxSeq=30 不小于本批最旧序号 5 ⇒ 必须被排除');
    });
  });

  // 本变更不动二级那条链：`summarizeText`（2-pass 合一）与 `_l1SummaryText`（二级保底
  // 路径里产出一级摘要）都不接参考。**如实说明**：那条保底路径在当前代码里几乎跑不到
  // （`l2SubSpans` 只由收拢循环设置），行为用例构造不出来，所以这里用源码扫描 + 类型
  // 约束两条：谁给那条链加上参考，这两条里必有一条红（`summarizeText` 加参数会直接
  // 编译不过，`_l1SummaryText` 的调用点加参数会被下面的扫描抓住）。
  group('二级那条链不接参考（源码扫描，替代构造不出来的行为用例）', () {
    test('summarizeText 没有参考参数，_l1SummaryText 的调用点也没有传参考', () {
      final interfaceSrc =
          File('lib/services/compaction/summary_provider.dart').readAsStringSync();
      final textDecl = interfaceSrc.substring(
          interfaceSrc.indexOf('Future<SummaryResult> summarizeText('));
      final textDeclHead = textDecl.substring(0, textDecl.indexOf('}'));
      expect(textDeclHead.contains('reference'),
          isFalse,
          reason: 'summarizeText（二级合一）不该有参考参数');

      final mainSrc = File('lib/main.dart').readAsStringSync();
      final callAt = mainSrc.indexOf('_l1SummaryText(sessionId');
      expect(callAt, isNot(-1), reason: '保底路径的调用点必须还在（否则这条扫描指错了对象）');
      final callSite = mainSrc.substring(callAt, callAt + 200);
      expect(callSite.contains('reference'),
          isFalse,
          reason: '二级保底路径产出一级摘要时不接参考 —— 二级那条链的输入构成不变');
      // ignore: avoid_print
      print('[OBS] summarizeText 声明=${textDeclHead.replaceAll('\n', ' ')}');
      // ignore: avoid_print
      print('[OBS] _l1SummaryText 调用点=${callSite.split('\n').take(3).join(' ')}');
    });
  });
}
