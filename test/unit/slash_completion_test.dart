// 技能名补全的**匹配纯函数**用例（change `slash-command-completion` 任务 1.2）。
//
// 钉六件事（design D3，借鉴 DSH `dsh-client-ui-commands` fuzzy-label 的排序骨架、
// 有意不移植对齐分）：
//   ① 前缀命中排在子序列命中之前（即使子序列在输入列表里更靠前）；
//   ② 子序列按序不必相邻 —— 用 `/egk` 命中 `edge-skill` 证明（`/ed` 只能证相邻）；
//   ③ 大小写不敏感（`/EGK` 与 `/egk` 同结果）；
//   ④ 空查询按输入顺序全量返回（不排序、不丢）；
//   ⑤ 无命中返回空列表（不是 null、不是原列表）；
//   ⑥ 多命中：先按首次命中位置，同分保持输入顺序（稳定）。
//
// 另有一条 `slashFirstSegmentEnd` 的边界用例：design D1 钉死空白集合是
// U+0020/U+0009/U+000A，全角空格 U+3000 **不算**空白（与
// `lib/services/slash_commands.dart` 同一集合）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/slash_completion.dart';

void main() {
  group('filterSkillNames', () {
    test('前缀命中排在子序列命中之前', () {
      const names = ['pre-ed', 'ed-foo', 'edge-skill'];
      final actual = filterSkillNames('ed', names);
      // ignore: avoid_print
      print('[补全匹配] query=ed names=$names → $actual');
      expect(actual, ['ed-foo', 'edge-skill', 'pre-ed'],
          reason: '两个前缀命中（按输入顺序）在前，子序列命中 pre-ed 垫底');
    });

    test('子序列按序不必相邻：/egk 命中 edge-skill', () {
      const names = ['edge-skill'];
      // 先证"这不是相邻子串"：命中只能来自按序子序列（`/ed` 那种相邻匹配证不了这条）。
      expect('edge-skill'.contains('egk'), isFalse,
          reason: 'egk 不是 edge-skill 的相邻子串');
      final nonAdjacent = filterSkillNames('egk', names);
      final adjacent = filterSkillNames('ed', names);
      // ignore: avoid_print
      print('[补全匹配] query=egk → $nonAdjacent；query=ed → $adjacent');
      expect(nonAdjacent, ['edge-skill'],
          reason: 'e…g…k 按序不必相邻，也必须命中');
      expect(adjacent, ['edge-skill'], reason: '相邻子序列当然也命中');
    });

    test('大小写不敏感', () {
      const names = ['edge-skill'];
      final upper = filterSkillNames('EGK', names);
      final mixed = filterSkillNames('EgK', names);
      final lower = filterSkillNames('egk', names);
      // ignore: avoid_print
      print('[补全匹配] EGK → $upper；EgK → $mixed；egk → $lower');
      expect(upper, ['edge-skill'], reason: '大写查询也要命中');
      expect(mixed, ['edge-skill'], reason: '混合大小写同样命中');
      expect(upper, lower, reason: '大小写不该改变结果');
    });

    test('空查询按输入顺序全量返回', () {
      const names = ['zeta-skill', 'alpha-skill', 'mid-skill'];
      final actual = filterSkillNames('', names);
      // ignore: avoid_print
      print('[补全匹配] query=(空) names=$names → $actual');
      expect(actual, ['zeta-skill', 'alpha-skill', 'mid-skill'],
          reason: '空查询必须原样按输入顺序全量列出（不排序、不丢）');
    });

    test('无命中返回空列表', () {
      final none = filterSkillNames('zzz', ['edge-skill', 'other-skill']);
      final tooLong = filterSkillNames('edge-skill-x', ['edge-skill']);
      // ignore: avoid_print
      print('[补全匹配] zzz → $none；edge-skill-x → $tooLong');
      expect(none, isEmpty, reason: '没有匹配就是空列表（不是 null、不是原列表）');
      expect(tooLong, isEmpty, reason: '查询比名字长 ⇒ 不可能是子序列');
    });

    test('多命中：先按首次命中位置，同分按输入顺序（稳定）', () {
      const byPosition = ['--ab', 'a-b', 'xx-ab', 'ab-xx'];
      final positionActual = filterSkillNames('ab', byPosition);
      // ignore: avoid_print
      print('[补全匹配] query=ab names=$byPosition → $positionActual');
      expect(positionActual, ['ab-xx', 'a-b', '--ab', 'xx-ab'],
          reason: '前缀先；其余按首次命中位置 0 < 2 < 3');

      // 同组同位置：Dart 的 List.sort 不稳定，所以必须有"输入顺序"兜底。
      const tied = ['xx-ed', 'ab-ed', 'ed', 'cc-ed'];
      final tiedActual = filterSkillNames('ed', tied);
      // ignore: avoid_print
      print('[补全匹配] query=ed names=$tied → $tiedActual');
      expect(tiedActual, ['ed', 'xx-ed', 'ab-ed', 'cc-ed'],
          reason: '三个命中都从下标 3 开始 ⇒ 保持输入顺序');
    });

    test('不修改入参（返回新列表）', () {
      final names = ['zeta-skill', 'alpha-skill'];
      final filtered = filterSkillNames('', names);
      final matched = filterSkillNames('a', names);
      // ignore: avoid_print
      print('[补全匹配] 入参=$names 空查询结果=$filtered 命中=$matched');
      expect(names, ['zeta-skill', 'alpha-skill'], reason: '入参不许被改序');
      expect(identical(filtered, names), isFalse,
          reason: '函数返回自己的列表，调用方改它不该影响技能目录快照');
      expect(matched, ['alpha-skill', 'zeta-skill'],
          reason: '前缀 alpha 在前；zeta 的 a 在下标 3');
    });
  });

  group('slashFirstSegmentEnd', () {
    test('空白三码元是首段分界，全角空格不算空白', () {
      const fullWidth = '/ed\u3000正文';
      // ignore: avoid_print
      print('[首段末] "/ed 正文" → ${slashFirstSegmentEnd('/ed 正文')}；'
          '全角 → ${slashFirstSegmentEnd(fullWidth)}（长度 ${fullWidth.length}）');
      expect(slashFirstSegmentEnd('/ed 正文'), 3);
      expect(slashFirstSegmentEnd('/ed\t正文'), 3, reason: 'U+0009 制表是分界');
      expect(slashFirstSegmentEnd('/ed\n正文'), 3, reason: 'U+000A 换行是分界');
      expect(slashFirstSegmentEnd('/ed'), 3, reason: '没有空白时首段末 = 文本长度');
      expect(slashFirstSegmentEnd(fullWidth), fullWidth.length,
          reason: '全角空格 U+3000 刻意不算空白（与 slash_commands.dart 同一集合）');
      expect(slashFirstSegmentEnd(''), 0, reason: '空文本没有首段');
    });
  });
}
