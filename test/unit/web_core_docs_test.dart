// 用户文档守卫（change `web-ui-core-shim` 任务 5.2）。
//
// 关键字符串**取自代码常量 / 入口源码**，不是手抄副本：
//   - 启动命令来自 `lib/core/headless_core.dart` 的 `kCoreEntryCommand`，并与
//     `bin/alias_agent_core.dart` 的 `--help` 文案同源；
//   - 端口回显格式来自 `kCoreUrlTemplate`；WS 路径来自 `kCoreWebSocketPath`；
//   - 单实例提示语来自 `kCoreAlreadyRunningMessage`；
//   - 错误码来自 `JsonRpcErrorCode` 的规范常量；
//   - RPC 方法名来自 `kCoreRpcMethodNames`；
//   - 开发期代理环境变量从 `web/vite.config.ts` 源码里解析（改配置不改文档就红）。
//
// 改代码文案而不同步文档 → 本守卫红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/core_lock.dart';
import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/core/json_rpc.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[文档守卫] $label: $value');
}

/// 解析一份 markdown 里的**表格行**：返回每行去掉首尾 `|` 后按 `|` 切出的单元格。
///
/// 只认以 `|` 开头、以 `|` 结尾的行；表头分隔行（`---`）跳过。这不是"整份文档
/// 子串包含"——方法名必须出现在第一列（change `group-chat-layout` R.17：原先对
/// `kCoreRpcMethodNames` 只查整篇子串，正文提一句也能过）。
List<List<String>> tableRows(String markdown) {
  final rows = <List<String>>[];
  for (final line in markdown.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) continue;
    final cells = trimmed
        .substring(1, trimmed.length - 1)
        .split('|')
        .map((cell) => cell.trim())
        .toList();
    if (cells.every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell))) continue;
    rows.add(cells);
  }
  return rows;
}

void main() {
  final doc = File('Docs/user-guide/web-core-shim.md');
  final readme = File('README.md').readAsStringSync();
  final viteConfig = File('web/vite.config.ts').readAsStringSync();

  test('用户文档存在且 README 索引指向它', () {
    _obs('文档路径', doc.path);
    expect(doc.existsSync(), isTrue,
        reason: '缺少 Docs/user-guide/web-core-shim.md');
    expect(readme, contains('Docs/user-guide/web-core-shim.md'),
        reason: 'README 的功能文档索引必须加入无头核心文档');
  });

  test('启动命令 / 端口回显 / WS 路径 / 单实例提示 / CWD 约定均与代码一致', () {
    final text = doc.readAsStringSync();
    final usages = <String, String>{
      '启动命令': kCoreEntryCommand,
      '端口回显格式': kCoreUrlTemplate,
      'WebSocket 路径': kCoreWebSocketPath,
      '单实例提示': kCoreAlreadyRunningMessage,
      '运行目录约定': 'CWD',
    };
    final missing = <String>[];
    usages.forEach((label, value) {
      _obs(label, value);
      if (!text.contains(value)) missing.add('$label（缺 "$value"）');
    });
    expect(missing, isEmpty, reason: '文档缺少以下代码常量原文：$missing');
  });

  test('RPC 方法清单与代码常量一致（按 RPC 表行解析，整篇子串不算过）', () {
    final text = doc.readAsStringSync();
    final rows = tableRows(text);
    final firstColumn = {
      for (final row in rows)
        if (row.isNotEmpty) row.first.replaceAll('`', ''),
    };
    final missing = [
      for (final method in kCoreRpcMethodNames)
        if (!firstColumn.contains(method)) method,
    ];
    _obs('代码里的 RPC 方法', kCoreRpcMethodNames);
    _obs('RPC 表第一列', firstColumn);
    _obs('文档里缺少的方法（按表行）', missing);
    expect(missing, isEmpty,
        reason: '文档 RPC 表必须逐行列出这些方法（第一列）；整篇子串出现不算过：$missing');
  });

  test('JSON-RPC 规范错误码全部写进文档', () {
    final text = doc.readAsStringSync();
    final codes = <int>[
      JsonRpcErrorCode.parseError,
      JsonRpcErrorCode.invalidRequest,
      JsonRpcErrorCode.methodNotFound,
      JsonRpcErrorCode.invalidParams,
      JsonRpcErrorCode.internalError,
    ];
    final missing = [for (final code in codes) if (!text.contains('$code')) code];
    _obs('代码里的错误码', codes);
    _obs('文档里缺少的错误码', missing);
    expect(missing, isEmpty, reason: '文档没有列出这些错误码：$missing');
  });

  test('开发期 Vite 代理环境变量从 vite.config.ts 解析并出现在文档', () {
    final matches = RegExp(r'env\.([A-Z][A-Z0-9_]+)').allMatches(viteConfig);
    final keys = {for (final match in matches) match.group(1)!};
    _obs('vite.config.ts 解析到的 env 键', keys);
    expect(keys, isNotEmpty,
        reason: 'vite.config.ts 里找不到 env.<KEY> 形式的代理配置');
    final text = doc.readAsStringSync();
    final missing = [for (final key in keys) if (!text.contains(key)) key];
    _obs('文档里缺少的环境变量', missing);
    expect(missing, isEmpty, reason: '文档没有写这些开发期环境变量：$missing');
  });

  test('已知限制段落覆盖本 change 必须披露的边界', () {
    final text = doc.readAsStringSync();
    // change `web-chat-screen` 任务 7.2（审查 TC-2）：文档已从"验证页"口径改成
    // **完整聊天屏**口径，旧锚点 '最小验证页' 不再成立（改前红证据见 change 报告）。
    // 这里只换锚点集、不改断言语义：仍然要求每个边界锚点都在文档里出现，
    // 并且新增的锚点覆盖完整屏必须披露的边界（折叠/贴底/跳底/重连）。
    for (final anchor in const [
      '完整聊天屏',
      '无鉴权',
      '全量载入历史',
      '测试',
      '折叠',
      '贴底跟随',
      '跳底按钮',
      '重连',
    ]) {
      _obs('边界锚点', anchor);
      expect(text, contains(anchor), reason: '已知限制缺少锚点 "$anchor"');
    }
  });

  test('布局锚点：会话列表常驻 / 群聊只换主区 / 空聊天屏 / 管理入口在单聊（change `group-chat-layout`）', () {
    final text = doc.readAsStringSync();
    for (final anchor in const [
      '会话列表常驻',
      '群聊',
      '主区',
      '空聊天屏',
      '管理入口在单聊',
    ]) {
      _obs('布局锚点', anchor);
      expect(text, contains(anchor), reason: '文档缺少布局锚点 "$anchor"');
    }
  });

  test('返工后的错误分流锚点：加载会话失败 / 列表刷新失败 / 不误报（change `group-chat-layout` 3.5）', () {
    final text = doc.readAsStringSync();
    for (final anchor in const [
      '加载会话失败',
      '列表刷新失败',
      '不误报',
      '操作成功',
    ]) {
      _obs('错误分流锚点', anchor);
      expect(text, contains(anchor), reason: '文档缺少返工错误分流锚点 "$anchor"');
    }
  });

  test('R.14/R.15 行为同步：group.chain 表行含 error / 链失败显示真因（change `group-chat-layout` R.17）', () {
    final text = doc.readAsStringSync();
    // 与 `group_docs_test.dart` 同口径：按表行断言，整篇出现 `error` 不算过
    // （steps 段早就有 error，修前也不会红）。
    final rows = tableRows(text);
    final chainRows = rows
        .where((row) =>
            row.isNotEmpty && row.first.replaceAll('`', '') == 'group.chain')
        .toList();
    _obs('group.chain 表行', chainRows);
    expect(chainRows, isNotEmpty,
        reason: 'group.chain 必须是无头核心 RPC 表里的独立一行（第一列）');
    final hasErrorField = chainRows.any(
      (row) => row.any((cell) => RegExp(r'\berror\b').hasMatch(cell)),
    );
    _obs('group.chain 行是否写出 error 字段', hasErrorField);
    expect(hasErrorField, isTrue,
        reason: 'group.chain 表行必须写出 error 字段（失败真因；整篇子串不算过）');
    _obs('链失败真因锚点', '链失败显示真因');
    expect(text, contains('链失败显示真因'),
        reason: '无头核心文档必须写明链失败时界面显示真因');
    // 工作区回落缺省只属 group-chat.md（本文件没有工作区段），不在这里加锚点。
  });
}
