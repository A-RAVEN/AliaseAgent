// 形状实现单一来源与接点守卫（change `migrate-web-fetch-to-spill` 任务 4.1）。
//
// 四件事（全部按源码字符串计数，不靠人看）：
//   ① `shape_stream` 的定义恰一处（`sidecar/src/spill.cpp`），别处不许再有私有定义；
//   ② `shape_stream` 的调用点：`command_tool.cpp` 恰两处（stdout/stderr）、
//      `web_fetch.cpp` 恰一处（在 `web_fetch_shape_success_result` 内部）；
//   ③ `web_fetch.cpp` 里 `web_fetch_shape_success_result` 的调用点恰两处，且分别
//      落在两个成功 `return …dump()` 之前（漏接任何一个出口本用例必须红）；
//   ④ `lib/services/agent.dart` 源码不含 `substring(0, 2000)`（2000 硬切已废除）。
//
// 关于 ② 的口径：tasks 4.1 初稿写"调用点合计恰四处（command_tool 两处 + web_fetch
// 两处）"，但 2.1 要求两个出口都调**包装函数** `web_fetch_shape_success_result`，
// 形状只在包装里发生一次 ⇒ `web_fetch.cpp` 里 `spill::shape_stream(` 只有一处，
// 两处"web_fetch"是包装函数的调用（由 ③ 钉住）。四处与 2.1 的包装设计互斥；该计数
// 错误已报主循环，**裁定采纳本口径**：①定义一处、②调用三处、③包装调用两处、
// ④无 2000 硬切。强度依据：漏接任一出口 ⇒ ③ 红；复制形状 ⇒ ①② 红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 子串出现次数（不重叠）。
int _count(String source, String needle) {
  var n = 0;
  var i = source.indexOf(needle);
  while (i >= 0) {
    n++;
    i = source.indexOf(needle, i + needle.length);
  }
  return n;
}

void main() {
  final spillCpp = File('sidecar/src/spill.cpp').readAsStringSync();
  final commandToolCpp = File('sidecar/src/command_tool.cpp').readAsStringSync();
  final webFetchCpp = File('sidecar/src/web_fetch.cpp').readAsStringSync();
  final agentDart = File('lib/services/agent.dart').readAsStringSync();

  test('① shape_stream 的定义只在 spill.cpp 一处，别处没有私有副本', () {
    final spillDefs = _count(spillCpp, 'StreamShape shape_stream(');
    final otherDefs = _count(commandToolCpp, 'StreamShape shape_stream(') +
        _count(webFetchCpp, 'StreamShape shape_stream(');
    // ignore: avoid_print
    print('[形状守卫] StreamShape shape_stream( 定义：spill.cpp=$spillDefs 其它=$otherDefs');
    expect(spillDefs, 1, reason: '形状实现只许有一份，定义在 spill.cpp');
    expect(otherDefs, 0,
        reason: 'command_tool.cpp / web_fetch.cpp 不许再复制一份私有的 shape_stream');
  });

  test('② shape_stream 调用点：command_tool 两处、web_fetch 一处', () {
    final commandCalls = _count(commandToolCpp, 'shape_stream(');
    final webFetchCalls = _count(webFetchCpp, 'shape_stream(');
    // ignore: avoid_print
    print('[形状守卫] shape_stream( 调用：command_tool=$commandCalls web_fetch=$webFetchCalls');
    expect(commandCalls, 2, reason: 'stdout / stderr 各一次');
    expect(webFetchCalls, 1,
        reason: 'web_fetch 的形状只经 web_fetch_shape_success_result 发生一次；'
            '复制第二份实现会在这里变红');
    expect(commandCalls + webFetchCalls, 3);
  });

  test('③ web_fetch 两个成功出口各调一次 web_fetch_shape_success_result', () {
    final total = _count(webFetchCpp, 'web_fetch_shape_success_result(');
    final defs = _count(webFetchCpp, 'bool web_fetch_shape_success_result(');
    // ignore: avoid_print
    print('[形状守卫] web_fetch_shape_success_result( 出现 $total 次，其中定义 $defs 次');
    expect(defs, 1);
    expect(total - defs, 2, reason: '两个成功出口各接一次；漏接任何一个出口必须红');

    // 两个出口的次序：crawl4ai 的 `return parsed.dump(` 与 curl 的 `return result.dump(`
    // 之前都必须先出现一次包装调用。
    final crawlCall = webFetchCpp.indexOf(
        'web_fetch_shape_success_result(context::Context::current(), parsed,');
    final crawlReturn = webFetchCpp.indexOf('return parsed.dump(');
    final curlCall = webFetchCpp.indexOf(
        'web_fetch_shape_success_result(context::Context::current(), result,');
    final curlReturn = webFetchCpp.indexOf('return result.dump(');
    // ignore: avoid_print
    print('[形状守卫] 出口次序：crawl call=$crawlCall return=$crawlReturn；'
        'curl call=$curlCall return=$curlReturn');
    expect(crawlCall, greaterThan(0));
    expect(crawlReturn, greaterThan(crawlCall),
        reason: 'crawl4ai 出口必须在 return 之前接形状');
    expect(curlCall, greaterThan(0));
    expect(curlReturn, greaterThan(curlCall),
        reason: 'curl 兜底出口必须在 return 之前接形状');
  });

  test('④ agent.dart 不含 substring(0, 2000)（2000 硬切已废除）', () {
    final hits = _count(agentDart, 'substring(0, 2000)');
    // ignore: avoid_print
    print('[形状守卫] agent.dart 里 substring(0, 2000) 出现 $hits 次');
    expect(hits, 0, reason: 'web_fetch 的 2000 字符硬切必须彻底消失，不许以任何形式回来');
  });

  // 4.2 用户文档断言（change `migrate-web-fetch-to-spill`）：截断披露必须写进用户文档。
  test('⑤ web_fetch 的 spill 交付与三条披露写进了用户文档', () {
    final toolsWeb = File('Docs/user-guide/tools-web.md').readAsStringSync();
    expect(toolsWeb, contains('read_spill'),
        reason: '截断表必须给 web_fetch 写明 read_spill 读回办法');
    expect(toolsWeb, contains('preview_chars'),
        reason: '必须写明阈值来自 spill.preview_chars');
    expect(toolsWeb, contains('U+FFFD'),
        reason: '规范化只发生在预览这一步——必须向用户披露');
    expect(toolsWeb, contains('取不回来'),
        reason: '旧会话历史损失必须如实披露，不许写成可找回');
    final configDoc = File('Docs/user-guide/configuration.md').readAsStringSync();
    expect(configDoc, contains('`web_fetch` 的正文'),
        reason: 'preview_chars 键行的适用范围必须含 web_fetch');
    final cmdDoc = File('Docs/user-guide/tools-command.md').readAsStringSync();
    expect(cmdDoc, contains('也管 `web_fetch`'),
        reason: '命令工具文档的同一键行要交叉引用网页工具');
    // 键名与产品解析路径对得上（不许文档写了代码里没有的键）。
    final appConfig = File('lib/models/app_config.dart').readAsStringSync();
    expect(appConfig, contains("'preview_chars'"));
    // ignore: avoid_print
    print('[文档守卫] tools-web/configuration/tools-command 三段披露齐全');
  });
}
