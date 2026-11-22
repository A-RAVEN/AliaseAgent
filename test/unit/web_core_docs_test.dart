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

  test('RPC 方法清单与代码常量一致', () {
    final text = doc.readAsStringSync();
    final missing = [
      for (final method in kCoreRpcMethodNames)
        if (!text.contains(method)) method,
    ];
    _obs('代码里的 RPC 方法', kCoreRpcMethodNames);
    _obs('文档里缺少的方法', missing);
    expect(missing, isEmpty, reason: '文档没有列出这些方法：$missing');
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
}
