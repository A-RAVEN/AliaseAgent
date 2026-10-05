import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/search_text_assembly.dart';

/// `web_search` 结果拼给模型的那段文本的单元测试（change `fix-silent-truncation`，
/// tasks.md 4.2 / 4.4 / 4.5 / 4.6）。
///
/// 覆盖哪几件事（共用用例时要说清，否则"它到底测了啥"无法核对）：
///   1. 预算真的生效：给一份远超预算的返回（三个后端、首条正文各 5000 字），拼出的
///      文本长度不超过预算 —— 不设预算时会拼出 15000 字以上，所以这条能真的失败；
///   2. 几个后端就写几行结果行（`<名字>: <条数> results`），**一行都不许少**；
///   3. 小预算下（预算传 5，连一行结果行都放不下）"预览被省略"那一支真的跑得出来，
///      并且省略是**点名**的（写出后端名与各自条数），不是只报一个数字；
///   4. 被省略预览的后端，它自己的结果行仍在；
///   5. 出错的后端照旧写 `ERROR` 行，不参与预览分配。
///
/// 为什么要传小预算：按真实预算（8000）与正常返回规模（几个后端、各几条、正文几百
/// 字），"有后端被省略"这一支根本不会发生 —— 拿真实规模去断言它是恒真的
/// （第二轮对抗验证就是这么发现旧写法的断言无效）。
void main() {
  Map<String, dynamic> searchResult(Map<String, Map<String, dynamic>> providers) => {
        'ok': true,
        'results': providers,
      };

  Map<String, dynamic> providerWith(int count, {String content = ''}) => {
        'results': List.generate(
          count,
          (i) => {
            'title': '标题$i',
            'url': 'https://example.com/$i',
            'content': content,
          },
        ),
      };

  test('预算真的生效：远超预算的返回，拼出来不超过预算', () {
    // 每个后端给 5 条、首条正文各 5000 字：不设预算时三个后端合计会到 15000 字以上，
    // 远超 8000 —— 所以这条断言能真的失败（若只给 900 字，即使预算失效也只拼出约
    // 2900 字，仍然小于 8000，那条断言就是恒真的）。
    final big = searchResult({
      'zhipuai': providerWith(5, content: '正' * 5000),
      'kimi': providerWith(5, content: '文' * 5000),
      'deepseek': providerWith(5, content: '字' * 5000),
    });
    final text = assembleSearchText(big);

    // ignore: avoid_print
    print('[拼装/预算] 实测长度=${text.length} 预算=$defaultSearchTextBudget');
    expect(text.length, lessThanOrEqualTo(defaultSearchTextBudget),
        reason: '拼装必须落在预算内 —— 否则会被界面那道通用截断再砍一次（等于换个地方丢）');
    // 三个后端的结果行仍要一个不少
    expect(text, contains('zhipuai: 5 results'));
    expect(text, contains('kimi: 5 results'));
    expect(text, contains('deepseek: 5 results'));
  });

  test('预算真的在分配：中等规模的正文会被带上（截到各自的份额）', () {
    // 两个后端、首条正文各 2500 字：每人份额约 4000 字，所以正文应当被**带上并截断**，
    // 而不是像超大正文那样整段省略。没有这条，上面那条"不超过预算"的断言可能被
    // "干脆什么都不写"满足（实测过：5000 字正文会让三个后端全部省略，只剩结果行）。
    final text = assembleSearchText(searchResult({
      'zhipuai': providerWith(5, content: '甲' * 2500),
      'kimi': providerWith(5, content: '乙' * 2500),
    }));

    // ignore: avoid_print
    print('[拼装/分配] 实测长度=${text.length}');
    expect(text, contains('标题0 — https://example.com/0'));
    expect(text, contains('甲'), reason: '中等规模时正文应当被带上（截到份额）');
    expect(text, contains('乙'));
    expect(text.length, lessThanOrEqualTo(defaultSearchTextBudget));
  });

  test('几个后端就写几行结果行，一个都不许少', () {
    // 小预算：三个后端的结果行本身就要 60 多字。**结果行不受预算管** —— 预算只能
    // 压缩预览。把预算调小到"放不下任何预览"，三个后端名仍必须一个不少
    // （这正是"结构性信息不许被预算吃掉"那一条；变异 9.3 就是在这里变红的）。
    final text = assembleSearchText(
      searchResult({
        'zhipuai': providerWith(5),
        'kimi': providerWith(1),
        'deepseek': providerWith(10),
      }),
      budget: 5,
    );

    // ignore: avoid_print
    print('[拼装] 实测输出：\n$text');
    expect(text, contains('zhipuai: 5 results'));
    expect(text, contains('kimi: 1 results'));
    expect(text, contains('deepseek: 10 results'));
  });

  test('真实预算下三个后端都放得下，不出现省略提示', () {
    final text = assembleSearchText(searchResult({
      'zhipuai': providerWith(5),
      'kimi': providerWith(1),
      'deepseek': providerWith(10),
    }));

    // ignore: avoid_print
    print('[拼装/正常预算] 实测输出：\n$text');
    expect(text, contains('zhipuai: 5 results'));
    expect(text.contains('只给出了条数'), isFalse,
        reason: '真实预算下三个后端都放得下，不该出现省略提示');
  });

  test('小预算时预览被省略：点名后端与各自条数', () {
    // 预算 5：连一行结果行都放不下，三个后端必然全部进入"预览被省略"这一支。
    final text = assembleSearchText(
      searchResult({
        'zhipuai': providerWith(5),
        'kimi': providerWith(1),
        'deepseek': providerWith(10),
      }),
      budget: 5,
    );

    // ignore: avoid_print
    print('[拼装/小预算] 实测输出：\n$text');
    // 省略必须点名：写出后端名与条数，而不是只说"还有 N 个没显示"
    expect(text, contains('zhipuai（5 条）'));
    expect(text, contains('kimi（1 条）'));
    expect(text, contains('deepseek（10 条）'));
    expect(text, contains('只给出了条数'));
  });

  test('预览被省略时该后端的结果行仍在，并带一句说明', () {
    final text = assembleSearchText(
      searchResult({'zhipuai': providerWith(5)}),
      budget: 5,
    );

    // ignore: avoid_print
    print('[拼装/单后端小预算] 实测输出：\n$text');
    expect(text, contains('zhipuai: 5 results'),
        reason: '结构性信息（有几个后端、各几条）不许被预算吃掉');
    expect(text, contains('本条预览因篇幅未显示'));
  });

  test('出错的后端照旧写 ERROR 行，不参与预览分配', () {
    final text = assembleSearchText(searchResult({
      'zhipuai': {'error': 'HTTP 429'},
      'kimi': providerWith(2),
    }));

    expect(text, contains('zhipuai: ERROR — HTTP 429'));
    expect(text, contains('kimi: 2 results'));
  });
}
