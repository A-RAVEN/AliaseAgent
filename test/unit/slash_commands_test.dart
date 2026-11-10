// 斜杠命令展开的纯函数用例（change `add-slash-commands` 任务 1.2）。
//
// 钉三件事（design D2 / D3 / D4）：
//   ① 命中带正文：**整段逐字**等于固定模板 + 两个换行 + 原文（期望串在测试里硬编码，
//      **不引用实现常量拼期望** —— 否则改模板时断言会跟着实现一起漂移）；
//   ② 命中空正文：文本止于前缀句后的两个换行、技能名正确，且不等于裸输入；
//   ③ 未命中清单：逐条断言返回值与入参**逐字相同**（静默透传）。
//
// 空白集合（U+0020 / U+0009 / U+000A 算、U+3000 不算）与"只跳过一个空白"的语义
// 是 design D2 钉死的边界，这里各有一条正向 / 边界用例。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/slash_commands.dart';

/// 把不可见字符写成可见形态，便于用例输出被人工核对（只用于打印，不参与断言）。
String _visible(String s) => s
    .replaceAll('\n', r'\n')
    .replaceAll('\t', r'\t')
    .replaceAll('\u3000', '[U+3000 全角空格]');

void main() {
  // 夹具技能名：任务钉死统一用 `edge-skill`。
  const names = ['edge-skill'];

  // ---- 期望串：测试自持的硬编码字面量（禁止引用实现常量）----
  // 整段期望（tasks 1.2 的原文逐字副本）。
  const expectedWhole =
      '已按斜杠命令展开技能 "edge-skill"：请先调用 load_skill(skill: "edge-skill") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：\n\n把这段文字按技能要求处理';
  // 前缀句的逐字副本：给"正文不同"的其它命中用例拼尾部用。
  const expectedPrefix =
      '已按斜杠命令展开技能 "edge-skill"：请先调用 load_skill(skill: "edge-skill") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：';

  test('命中带正文：整段逐字等于 固定模板 + 两个换行 + 原文', () {
    const input = '/edge-skill 把这段文字按技能要求处理';
    final actual = expandSlashCommand(input, names);
    // ignore: avoid_print
    print('[斜杠] 输入=${_visible(input)}');
    // ignore: avoid_print
    print('[斜杠] 输出=${_visible(actual)}');
    expect(actual, expectedWhole,
        reason: '命中必须整段等于固定模板（前缀逐字 + \\n\\n + 余下正文），'
            '截断或改一个标点都算红');
  });

  test('命中空正文：文本止于前缀句后的两个换行、技能名正确、不等于裸输入', () {
    const input = '/edge-skill';
    final actual = expandSlashCommand(input, names);
    // ignore: avoid_print
    print('[斜杠] 空正文：输入=${_visible(input)} 输出=${_visible(actual)} '
        '长度=${actual.length}');
    expect(actual.endsWith('\n\n'), isTrue,
        reason: '空正文时文本必须止于前缀句后的两个换行');
    expect(actual, '$expectedPrefix\n\n',
        reason: '空正文也展开成完整的加载指示（不因为没有正文而透传）');
    expect(actual, contains('"edge-skill"'), reason: '技能名必须写进模板');
    expect(actual, isNot(input), reason: '空正文命中也必须展开，不许透传');
    expect(actual, isNot('/edge-skill'));
  });

  test('空白集合：制表 U+0009 与换行 U+000A 都算首段分界（命中）', () {
    const tabInput = '/edge-skill\t用制表符分隔';
    const lfInput = '/edge-skill\n用换行分隔';
    final tabActual = expandSlashCommand(tabInput, names);
    final lfActual = expandSlashCommand(lfInput, names);
    // ignore: avoid_print
    print('[斜杠] 制表：输出=${_visible(tabActual)}');
    // ignore: avoid_print
    print('[斜杠] 换行：输出=${_visible(lfActual)}');
    expect(tabActual, '$expectedPrefix\n\n用制表符分隔');
    expect(lfActual, '$expectedPrefix\n\n用换行分隔');
  });

  test('只跳过一个空白：`/edge-skill  正文` 的余下正文保留第二个空格', () {
    const input = '/edge-skill  正文';
    final actual = expandSlashCommand(input, names);
    // ignore: avoid_print
    print('[斜杠] 双空格：输出=${_visible(actual)}');
    expect(actual, '$expectedPrefix\n\n 正文',
        reason: 'design D2：余下正文 = 首段之后**跳过一个**空白的剩余文本');
  });

  test('未命中清单：逐条断言返回值与入参逐字相同（静默透传）', () {
    final cases = <({String why, String input, List<String> active})>[
      (why: '`/` 单独', input: '/', active: names),
      (why: '首段不是任何生效技能名', input: '/unknown 你好', active: names),
      (why: '大小写不一致', input: '/Edge-Skill x', active: names),
      (why: '前导空格（不以 `/` 开头）', input: ' /edge-skill 正文', active: names),
      (why: '消息中段出现 `/name`', input: '请执行 /edge-skill 正文', active: names),
      (why: '无空白分界 `/edge-skill正文`', input: '/edge-skill正文', active: names),
      (why: '全角空格 U+3000 不算空白',
          input: '/edge-skill\u3000正文', active: names),
      (why: '空串', input: '', active: names),
      (why: 'activeSkillNames 为空', input: '/edge-skill 干活', active: const []),
    ];
    for (final c in cases) {
      final actual = expandSlashCommand(c.input, c.active);
      // ignore: avoid_print
      print('[斜杠] 未命中（${c.why}）：输入=${_visible(c.input)} '
          '→ 输出=${_visible(actual)} 与入参逐字相同=${actual == c.input}');
      expect(actual, c.input, reason: '未命中必须原样透传：${c.why}');
    }
  });
}
