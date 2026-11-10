// 斜杠命令用户文档的**可失败**守卫（change `add-slash-commands` 任务 3.2）。
//
// 四件事，每件都是"删掉/写错就红"：
//   ① `Docs/user-guide/slash-commands.md` 存在；
//   ② 文档含「真实上下文」与指向 `real-context-view.md` 的交叉引用 —— 这是用户
//      核实"模型到底收到了什么"的唯一入口（spec / tasks 3.2 的硬要求）；
//   ③ 文档写清命中规则的三个要点（逐字匹配、全角空格不生效、未命中静默透传），
//      并给出「怎么核实」一节 —— 规则写漏即红；
//   ④ `README.md` 的功能文档索引里有指向它的链接（任务 3.3 说明：`user_docs_test`
//      的双向一致性用例是整份 README 抽链接，本用例仍保留自己这条索引行断言）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final docFile = File('Docs/user-guide/slash-commands.md');
  final readmeFile = File('README.md');

  test('slash-commands.md 存在，含「真实上下文」与 real-context-view.md 交叉引用', () {
    expect(docFile.existsSync(), isTrue,
        reason: '用户文档 Docs/user-guide/slash-commands.md 必须存在');
    final doc = docFile.readAsStringSync();
    // ignore: avoid_print
    print('[文档守卫-斜杠] 长度=${doc.length} '
        '含「真实上下文」=${doc.contains('真实上下文')} '
        '含 real-context-view.md 链接='
        '${doc.contains('](real-context-view.md)')} '
        '含「怎么核实」=${doc.contains('## 怎么核实')}');

    expect(doc, contains('真实上下文'),
        reason: '必须告诉用户去哪一屏核实模型实际收到的内容');
    expect(doc, contains('](real-context-view.md)'),
        reason: '必须交叉引用 Docs/user-guide/real-context-view.md（链接形式，不是光提名字）');
  });

  test('slash-commands.md 写清命中规则与静默透传', () {
    final doc = docFile.readAsStringSync();
    // ignore: avoid_print
    print('[文档守卫-斜杠] 含「逐字匹配」=${doc.contains('逐字')} '
        '含「全角空格」=${doc.contains('全角空格')} '
        '含「静默透传」=${doc.contains('静默透传')} '
        '含 load_skill=${doc.contains('load_skill')}');
    expect(doc, contains('逐字'),
        reason: '命中规则必须写明"首段逐字等于当轮生效技能名"（design D2）');
    expect(doc, contains('全角空格'),
        reason: '必须写明全角空格不算空白、因此不生效（design D2 的边界）');
    expect(doc, contains('静默透传'),
        reason: '未命中必须写明原样透传、不报错不提示');
    expect(doc, contains('load_skill'),
        reason: '文档要说明模型收到的是"先调用 load_skill 再干活"的指示');
    expect(doc, contains('## 怎么核实'),
        reason: '任务 3.2 要求文档必须含一段「怎么核实」');
  });

  test('README 功能文档索引含 Docs/user-guide/slash-commands.md', () {
    expect(readmeFile.existsSync(), isTrue);
    final readme = readmeFile.readAsStringSync();
    // ignore: avoid_print
    print('[文档守卫-斜杠] README 含斜杠命令索引链接='
        '${readme.contains('](Docs/user-guide/slash-commands.md)')}');
    expect(readme, contains('](Docs/user-guide/slash-commands.md)'),
        reason: '新增用户文档必须在 README 的功能文档索引里被链接');
  });
}
