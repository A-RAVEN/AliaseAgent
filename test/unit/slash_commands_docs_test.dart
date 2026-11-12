// 斜杠命令用户文档的**可失败**守卫（change `add-slash-commands` 任务 3.2；
// change `slash-command-completion` 任务 4.1 补了「补全」那一节）。
//
// 五件事，每件都是"删掉/写错就红"：
//   ① `Docs/user-guide/slash-commands.md` 存在；
//   ② 文档含「真实上下文」与指向 `real-context-view.md` 的交叉引用 —— 这是用户
//      核实"模型到底收到了什么"的唯一入口（spec / tasks 3.2 的硬要求）；
//   ③ 文档写清命中规则的三个要点（逐字匹配、全角空格不生效、未命中静默透传），
//      并给出「怎么核实」一节 —— 规则写漏即红；
//   ④ `README.md` 的功能文档索引里有指向它的链接（任务 3.3 说明：`user_docs_test`
//      的双向一致性用例是整份 README 抽链接，本用例仍保留自己这条索引行断言）；
//   ⑤ **补全**那一节：Tab 接受、回车改道（面板可见时回车是接受不是发送）、
//      "无匹配技能"与空目录空态两句精确串（直接引用实现常量 ⇒ 改文案不改文档就红）、
//      候选表是"最近一次扫描"的快照、Tab 截胡的无障碍取舍被登记。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/ui/slash_completion.dart';

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

  // ---------------------------------------------------------------------------
  // ⑤ 补全那一节（change `slash-command-completion` 任务 4.1）
  //
  // 两句界面文案**直接引用实现常量**：代码改文案而文档没跟上，这里立刻红
  // （`test/widget/slash_completion_panel_test.dart` 里另有一份独立硬编码的副本，
  // 两侧夹住"代码 ↔ 文档"）。
  // ---------------------------------------------------------------------------
  test('slash-commands.md 有「补全」一节：Tab 接受、回车改道、两句精确串、候选表时点',
      () {
    final doc = docFile.readAsStringSync();
    // ignore: avoid_print
    print('[文档守卫-斜杠-补全] 含「## 补全」=${doc.contains('## 补全')} '
        '含 Tab=${doc.contains('Tab')} '
        '含空态精确串=${doc.contains(kSlashCompletionEmptyCatalogHint)} '
        '含无匹配精确串=${doc.contains(kSlashCompletionNoMatchHint)} '
        '含「而不是发送」=${doc.contains('而不是发送')} '
        '含「最近一次扫描」=${doc.contains('最近一次扫描')} '
        '含「无障碍」=${doc.contains('无障碍')}');

    expect(doc, contains('## 补全'),
        reason: '补全必须自己成一节：用户在那里学"打几个字母按 Tab"');
    expect(doc, contains('Tab'),
        reason: 'Tab 是补全的核心操作（用户点名要的交互），文档必须写出来');
    expect(doc, contains(kSlashCompletionEmptyCatalogHint),
        reason: '空目录空态文案必须与实现常量逐字一致：'
            '用户屏上看到的和文档写的要是同一句（「$kSlashCompletionEmptyCatalogHint」）');
    expect(doc, contains(kSlashCompletionNoMatchHint),
        reason: '无命中提示行的精确串也必须与实现常量一致（「$kSlashCompletionNoMatchHint」）');
    expect(doc, contains('而不是发送'),
        reason: '回车改道是这个特性唯一改变既有行为的点（面板可见时回车是接受补全），'
            '必须写明"想直接发送要先接受或先 Esc"');
    expect(doc, contains('最近一次扫描'),
        reason: '候选表读的是最近一次 scan 的快照（装/删技能后要先发一条消息），'
            '这条已知限制必须告诉用户（design D6）');
    expect(doc, contains('无障碍'),
        reason: '面板可见时 Tab 被截胡是无障碍/键盘习惯上的已知取舍，必须登记（design Risks）');

    // 文案里写的 "详见 skills.md" 不是随口一提：那份文档必须真实存在。
    expect(File(kSlashCompletionSkillsDocPath).existsSync(), isTrue,
        reason: '空态文案引导用户去看 $kSlashCompletionSkillsDocPath，该文件必须存在');
  });
}
