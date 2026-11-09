// 技能用户文档的**可失败**守卫（change `add-skill-mechanism` 任务 7.3）。
//
// 四件事，每件都是"删掉/写错就红"：
//   ① `Docs/user-guide/skills.md` 存在，且写清安装位置、**改了技能文件下一条消息
//      就生效（无需重启）**、同修改时间且同大小覆盖写的检测盲区、长内容用 `read_spill`
//      取回、内联预览的坏字节显示为 `U+FFFD`，以及**提示词里常驻创建简则、助手可以
//      代写新技能**（返工 5.4，design D6；这条正向断言是本轮新增，删掉文档那句话即红）；
//   ② `Docs/user-guide/configuration.md` 的 `preview_chars` 那一行同时点名
//      `web_fetch` 与 `load_skill`（配置项的适用工具清单不能漏）；
//   ③ `README.md` 的功能文档索引里有 `Docs/user-guide/skills.md`；
//   ④ `Docs/user-guide/tools-file.md` 的「只读工具的并行执行」小节**不含**
//      `load_skill` —— 那个小节的名单被 `parallel_tools_docs_test` 钉住恰好 17 名
//      （`load_skill` 不在只读/逐个两个集合里，设计 D9）。
//
// 关于 ① 里"安装位置"的字面形态：tasks 7.3 的原话是"含 `~/.aliasagent/skills`"。
// 执行过程中曾一度放宽成"`~` 或 Windows 实写两种前缀之一"（当时已就位的文档只写了
// `C:\Users\你\.aliasagent\skills\`）；主循环裁定**任务原文优先、文档配合任务而非
// 相反**，随后 `Docs/user-guide/skills.md` 补回了带 `~/` 前缀的写法（同时保留 Windows
// 实写说明）。本用例因此改回**单形态字面量**断言（更严）：`~/.aliasagent/skills`
// 必须原样出现。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 文档某一节（从标题行到下一个同级 `## ` 标题之前）。
String _section(String markdown, String heading) {
  final start = markdown.indexOf(heading);
  if (start < 0) throw StateError('文档里找不到小节 "$heading"');
  final rest = markdown.substring(start + heading.length);
  final next = rest.indexOf('\n## ');
  return next < 0 ? rest : rest.substring(0, next);
}

void main() {
  final skillsDocFile = File('Docs/user-guide/skills.md');
  final configDocFile = File('Docs/user-guide/configuration.md');
  final readmeFile = File('README.md');
  final toolsFileDocFile = File('Docs/user-guide/tools-file.md');

  test('skills.md 存在且写清安装位置、下一条消息生效、覆盖写盲区、read_spill 与 U+FFFD',
      () {
    expect(skillsDocFile.existsSync(), isTrue,
        reason: '用户文档 Docs/user-guide/skills.md 必须存在');
    final doc = skillsDocFile.readAsStringSync();

    // ignore: avoid_print
    print('[文档守卫] skills.md 长度=${doc.length} '
        '含 `~/.aliasagent/skills`=${doc.contains('~/.aliasagent/skills')} '
        '含"下一条消息就生效"=${doc.contains('下一条消息就生效')} '
        '含"覆盖写"=${doc.contains('覆盖写')} '
        '含"创建简则"=${doc.contains('提示词里常年带一段创建简则')} '
        '含旧句"改了技能文件要重启应用才生效"='
        '${doc.contains('改了技能文件要重启应用才生效')}');
    // 单形态字面量（主循环裁定：任务原文优先，文档配合任务）：`~` 形态必须原样出现，
    // 只写 Windows 实写形态、或删掉安装说明都会红。
    expect(doc, contains('~/.aliasagent/skills'),
        reason: '安装位置必须按任务原文写成 `~/.aliasagent/skills`');
    // 生效口径（change `refresh-skill-catalog-each-turn` 3.1/3.2）：正向断言新口径
    // 「下一条消息就生效」——改前这里是 `contains('重启')`（旧口径时代留下的一句），
    // 文档哪怕整篇写着"要重启"它也照样绿，测不住本 change。
    expect(doc, contains('下一条消息就生效'),
        reason: '必须写清"改了技能文件，下一条消息就生效"（新口径）');
    // 负向断言（比旧守卫严）：旧限制句残留即红。
    expect(doc, isNot(contains('改了技能文件要重启应用才生效')),
        reason: '已废除的"改了技能文件要重启应用才生效"不许再出现在文档里');
    // 盲区要如实登记（design D1：同 mtime 同大小的覆盖写探测不到）。
    expect(doc, contains('覆盖写'), reason: '已知限制节要写清同大小覆盖写的检测盲区');
    expect(doc, contains('read_spill'), reason: '长内容要给出取回办法');
    expect(doc, contains('U+FFFD'),
        reason: '内联预览的坏字节替换规则要写进用户文档（spill delta 点名本文档）');
    // 返工 5.4（design D6）：提示词里常驻创建简则、助手能代写新技能这句是新增的
    // 用户可见承诺 —— 删掉它（或改写成别处）即红，别让文档这一句变成没人管的孤句。
    expect(doc, contains('提示词里常年带一段创建简则'),
        reason: '「助手什么时候用它」节要写明提示词里常带一段创建简则');
    expect(doc, contains('助手随时可以帮你写新技能'),
        reason: '要写出用户能得到什么：助手可以代写新技能');
  });

  test('configuration.md 的 preview_chars 行同时含 web_fetch 与 load_skill', () {
    expect(configDocFile.existsSync(), isTrue);
    final doc = configDocFile.readAsStringSync();
    final rows = doc
        .split('\n')
        .where((line) => line.contains('`preview_chars`'))
        .toList();
    // ignore: avoid_print
    print('[文档守卫] configuration.md 的 preview_chars 行数=${rows.length}');
    for (final line in rows) {
      // ignore: avoid_print
      print('[文档守卫]   $line');
    }
    expect(rows, isNotEmpty, reason: '配置键表里必须有 preview_chars 这一行');
    expect(rows.length, 1, reason: '同一个配置键只该有一行（两份就会漂移）');
    expect(rows.single, contains('web_fetch'));
    expect(rows.single, contains('load_skill'),
        reason: 'load_skill 也走这个配置项，适用工具清单必须点名它');
  });

  test('README 功能文档索引含 Docs/user-guide/skills.md', () {
    expect(readmeFile.existsSync(), isTrue);
    final doc = readmeFile.readAsStringSync();
    // ignore: avoid_print
    print('[文档守卫] README 含 skills.md 索引='
        '${doc.contains('Docs/user-guide/skills.md')}');
    expect(doc, contains('Docs/user-guide/skills.md'),
        reason: '新增用户文档必须在 README 的功能文档索引里被指向');
  });

  test('tools-file.md 的并行小节不含 load_skill', () {
    expect(toolsFileDocFile.existsSync(), isTrue);
    final doc = toolsFileDocFile.readAsStringSync();
    final section = _section(doc, '## 只读工具的并行执行');
    // ignore: avoid_print
    print('[文档守卫] 并行小节里 load_skill 出现次数='
        '${'load_skill'.allMatches(section).length}');
    expect(section, isNot(contains('load_skill')),
        reason: '设计 D9：load_skill 不在只读/逐个两个集合里，'
            '写进并行小节会让 parallel_tools_docs_test 的 17 名清单变红');
    // 但整篇文档里应当有一处交叉引用（不然用户不知道有这个工具）。
    expect(doc, contains('load_skill'),
        reason: '工具文档要交叉引用 load_skill（放在并行小节之外）');
  });
}
