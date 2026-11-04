// 执行分组纯函数与集合守卫（change `parallelize-readonly-tool-calls` 任务 3.2 / 3.3）。
//
// 3.2：`planToolGroups` 的每个分段规则各一条用例（design D1 / D6）。
// 3.3：只读集合、逐个集合与工具目录的**集合相等**守卫 —— 多一个、少一个、
//      或把逐个名挪进只读集合，这里都会红。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/services/tool_group_planner.dart';

/// 把计划还原成"每个段里装着哪些调用"的可读形状，方便断言与打印。
List<List<String>> shape(List<String> names, List<ToolGroupPlan> plan) {
  return [
    for (final g in plan) names.sublist(g.start, g.end),
  ];
}

List<bool> flags(List<ToolGroupPlan> plan) => [for (final g in plan) g.concurrent];

void main() {
  group('planToolGroups 分段', () {
    test('① 连续三个 grep_file 合成一个并发段', () {
      final names = ['grep_file', 'grep_file', 'grep_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] ① plan=$plan shape=${shape(names, plan)}');
      expect(plan.length, 1);
      expect(plan.single.concurrent, isTrue);
      expect(plan.single.start, 0);
      expect(plan.single.end, 3);
      expect(shape(names, plan), [
        ['grep_file', 'grep_file', 'grep_file']
      ]);
    });

    test('② 三个 read_file 在同一并发段（用户判据点名的形态）', () {
      final names = ['read_file', 'read_file', 'read_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] ② plan=$plan');
      expect(plan.length, 1);
      expect(plan.single.concurrent, isTrue);
      expect(plan.single.length, 3);
    });

    test('③ [grep_file, write_file, read_file] 切成三个逐个段', () {
      final names = ['grep_file', 'write_file', 'read_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] ③ plan=$plan flags=${flags(plan)}');
      expect(shape(names, plan), [
        ['grep_file'],
        ['write_file'],
        ['read_file'],
      ]);
      expect(flags(plan), [false, false, false]);
    });

    test('④ 连续两个 write_file 各自单独成段', () {
      final names = ['write_file', 'write_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] ④ plan=$plan');
      expect(shape(names, plan), [
        ['write_file'],
        ['write_file'],
      ]);
      expect(flags(plan), [false, false]);
    });

    test('⑤ 未知名 future_tool 单独成段，且不与相邻只读合并', () {
      final names = ['read_file', 'future_tool', 'read_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] ⑤ plan=$plan');
      expect(shape(names, plan), [
        ['read_file'],
        ['future_tool'],
        ['read_file'],
      ]);
      expect(flags(plan), [false, false, false]);
    });

    test('⑥ 单个 read_file 走逐个段（段长 1 走原路）', () {
      final names = ['read_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] ⑥ plan=$plan');
      expect(plan.length, 1);
      expect(plan.single.concurrent, isFalse);
      expect(plan.single.length, 1);
    });

    test('⑦ 4 个只读 + maxParallel=2 ⇒ 两个并发段各 2 项（顺序保留）', () {
      final names = ['read_file', 'read_file', 'read_file', 'read_file'];
      final plan = planToolGroups(names, maxParallel: 2);
      // ignore: avoid_print
      print('[分组] ⑦ plan=$plan flags=${flags(plan)}');
      expect(plan.length, 2);
      expect(plan[0].start, 0);
      expect(plan[0].end, 2);
      expect(plan[1].start, 2);
      expect(plan[1].end, 4);
      expect(flags(plan), [true, true]);
      expect(shape(names, plan), [
        ['read_file', 'read_file'],
        ['read_file', 'read_file'],
      ]);
    });

    test('⑧ maxParallel=0 ⇒ 4 个只读一段（不设上限）', () {
      final names = ['read_file', 'read_file', 'read_file', 'read_file'];
      final plan = planToolGroups(names, maxParallel: 0);
      // ignore: avoid_print
      print('[分组] ⑧ plan=$plan');
      expect(plan.length, 1);
      expect(plan.single.start, 0);
      expect(plan.single.end, 4);
      expect(plan.single.concurrent, isTrue);
    });

    test('⑨ 空列表 ⇒ 空计划', () {
      expect(planToolGroups(const []), isEmpty);
    });

    test('切尾巴只剩 1 项时按逐个段执行（maxParallel=3 + 4 个只读）', () {
      final names = ['read_file', 'read_file', 'read_file', 'read_file'];
      final plan = planToolGroups(names, maxParallel: 3);
      // ignore: avoid_print
      print('[分组] 尾巴 plan=$plan flags=${flags(plan)}');
      expect(shape(names, plan), [
        ['read_file', 'read_file', 'read_file'],
        ['read_file'],
      ]);
      expect(flags(plan), [true, false]);
    });

    test('只读段被写类调用打断后，后面那一段仍可并发', () {
      final names = ['read_file', 'read_file', 'write_file', 'grep_file', 'grep_file'];
      final plan = planToolGroups(names);
      // ignore: avoid_print
      print('[分组] 混合 plan=$plan');
      expect(shape(names, plan), [
        ['read_file', 'read_file'],
        ['write_file'],
        ['grep_file', 'grep_file'],
      ]);
      expect(flags(plan), [true, false, true]);
    });
  });

  group('集合守卫（集合相等，不只是并集覆盖）', () {
    test('只读集合恰好是 spec 点名的 9 个名字', () {
      // ignore: avoid_print
      print('[分组] 只读集合=${kReadOnlyToolNames.toList()..sort()}');
      expect(kReadOnlyToolNames, {
        'read_file',
        'list_dir',
        'glob_file',
        'grep_file',
        'read_spill',
        'read_image',
        'get_current_time',
        'web_search',
        'web_fetch',
      });
      expect(kReadOnlyToolNames.length, 9);
    });

    test('逐个集合恰好是 8 个有状态工具', () {
      // ignore: avoid_print
      print('[分组] 逐个集合=${kSerialToolNames.toList()..sort()}');
      expect(kSerialToolNames, {
        'write_file',
        'edit_file',
        'run_command',
        'browser_navigate',
        'browser_click',
        'browser_type',
        'browser_snapshot',
        'spawn_subagent',
      });
      expect(kSerialToolNames.length, 8);
    });

    test('两个集合交集为空', () {
      final overlap = kReadOnlyToolNames.intersection(kSerialToolNames);
      // ignore: avoid_print
      print('[分组] 交集=$overlap');
      expect(overlap, isEmpty);
    });

    test('两个集合的并集覆盖工具目录全部 17 个已知名字', () {
      // `ToolCatalog.kBaseToolNames` 的 11 项 + lib/main.dart 条件注册的 6 项
      // （web_search / web_fetch / 四个 browser_*）。
      final conditional = <String>{
        'web_search',
        'web_fetch',
        'browser_navigate',
        'browser_click',
        'browser_type',
        'browser_snapshot',
      };
      final allKnown = <String>{
        ...ToolCatalog.kBaseToolNames,
        ...conditional,
      };
      final union = <String>{
        ...kReadOnlyToolNames,
        ...kSerialToolNames,
      };
      // ignore: avoid_print
      print('[分组] 已知工具数=${allKnown.length} 分类并集数=${union.length} '
          '未归类=${allKnown.difference(union)} 多出来的=${union.difference(allKnown)}');
      expect(allKnown.length, 17, reason: '基础 11 + 条件注册 6 = 17 个已知名字');
      expect(union, allKnown, reason: '每个已知工具名都必须被归到只读或逐个其中一类');
      expect(union.length, 17);
    });
  });
}
