// 管理屏用户文档守卫（change `web-management-ui` 任务 4.2）。
//
// 与 `parallel_tools_docs_test` / `web_core_docs_test` 同一条先例：关键字符串**取自
// 代码常量**，不手抄副本 —— 改代码文案而不同步文档就会红。
//
// 覆盖三件事：
//   ① 文档存在，且 README 功能索引双向一致（目录 ↔ 索引）；
//   ② 管理 RPC 方法名全部出现在文档的 RPC 表里（清单取自 `kCoreRpcMethodNames`）；
//   ③ 图片上限取自 `image_budget.dart` 的 `kMaxImageBytes` 且带出处 §6.4.3；
//      生效时机说明取自 `kAgentTemplateEffectiveNote`（单一口径）；
//      web-core-shim 文档要写「空配置启动」这条新行为。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/core/headless_core.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/image_budget.dart';

void _obs(String label, Object? value) {
  // ignore: avoid_print
  print('[文档守卫] $label: $value');
}

/// 解析 markdown 的**表格行**（只认 `|…|`；表头分隔行跳过）。
///
/// change `chat-bubbles-avatars` 7.3：RPC 载荷必须**按表行**核对 —— 整篇子串出现
/// 一个 `profile` 不算过（正文提一句也能过）。
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
  final doc = File('Docs/user-guide/web-management.md');
  final readme = File('README.md').readAsStringSync();
  final webCoreDoc = File('Docs/user-guide/web-core-shim.md').readAsStringSync();

  test('管理文档存在，且 README 功能索引双向一致', () {
    _obs('文档路径', doc.path);
    expect(doc.existsSync(), isTrue,
        reason: '缺少 Docs/user-guide/web-management.md');
    expect(readme, contains('Docs/user-guide/web-management.md'),
        reason: 'README 的功能文档索引必须链接管理屏文档');
  });

  test('管理 RPC 方法名全部写进文档的 RPC 表', () {
    final text = doc.readAsStringSync();
    final missing = [
      for (final method in kCoreRpcMethodNames)
        if (!text.contains(method)) method,
    ];
    _obs('代码里的 RPC 方法数', kCoreRpcMethodNames.length);
    _obs('文档里缺少的方法', missing);
    expect(missing, isEmpty, reason: '管理文档没有列出这些 RPC 方法：$missing');
  });

  test('图片上限取自 image_budget 常量并带出处', () {
    final text = doc.readAsStringSync();
    _obs('代码里的单张上限', kMaxImageBytes);
    expect(text, contains('$kMaxImageBytes'),
        reason: '文档必须写出单张图片上限的**代码常量值** $kMaxImageBytes（32 MiB）');
    expect(text, contains('§6.4.3'), reason: '必须写明出处 DeepSeekAPIDoc §6.4.3');
  });

  test('模板生效时机说明与代码常量逐字一致（单一口径）', () {
    final text = doc.readAsStringSync();
    _obs('代码常量', kAgentTemplateEffectiveNote);
    expect(text, contains(kAgentTemplateEffectiveNote),
        reason: '文档必须与 kAgentTemplateEffectiveNote 说同一句话');
  });

  test('web-core-shim 文档写明空配置启动（D2 新行为）', () {
    _obs('web-core-shim 文档长度', webCoreDoc.length);
    for (final anchor in const ['空配置', '首启向导', 'malformed']) {
      _obs('锚点', anchor);
      expect(webCoreDoc, contains(anchor),
          reason: 'web-core-shim 文档缺少空配置启动的锚点 "$anchor"');
    }
    // 旧口径「先运行一次 Flutter 应用才能启动核心」必须被改掉。
    expect(webCoreDoc, isNot(contains('本入口不提供首启配置界面')),
        reason: '空配置启动后 web 端有首启向导，旧口径必须更新');
  });

  test('管理文档覆盖必写内容（密钥脱敏 / 留空沿用 / 引用拒删 / general 不可删）', () {
    final text = doc.readAsStringSync();
    for (final anchor in const [
      '不回显',
      '留空',
      '引用',
      'general',
      '不可删',
      '整圈',
      '图片未发送',
      '图片已丢失',
    ]) {
      _obs('内容锚点', anchor);
      expect(text, contains(anchor), reason: '管理文档缺少内容锚点 "$anchor"');
    }
  });

  test('布局锚点：列表常驻 / 只覆盖主区 / 点会话关闭 / 管理入口在左栏底部（change `group-chat-layout` / `global-settings-menu`）', () {
    final text = doc.readAsStringSync();
    for (final anchor in const [
      '会话列表',
      '只覆盖主区',
      '点会话',
      // change `global-settings-menu` 5.3：管理入口从「单聊顶栏」搬到「左栏底部」，
      // 只换这一处过时锚点（换成实际写进文档的新口径），其余锚点与断言不动。
      '左栏底部',
      'Provider 配置',
      '模板配置',
      '恰好两项',
      '群聊模板由各成员决定',
    ]) {
      _obs('布局锚点', anchor);
      expect(text, contains(anchor), reason: '管理文档缺少布局锚点 "$anchor"');
    }
  });

  test('返工锚点：删除当前会话会关闭管理页（change `group-chat-layout` 3.5）', () {
    final text = doc.readAsStringSync();
    for (final anchor in const [
      '删除当前会话会关闭管理页',
      '失败不关',
    ]) {
      _obs('返工锚点', anchor);
      expect(text, contains(anchor), reason: '管理文档缺少返工锚点 "$anchor"');
    }
  });

  test('头像控件文案锚点：代码里有、文档里也写（change `chat-bubbles-avatars` 7.3a）', () {
    final text = doc.readAsStringSync();
    final userBlock = File('web/src/components/UserAvatarBlock.tsx');
    final templatesPage = File('web/src/components/TemplatesPage.tsx');
    expect(userBlock.existsSync(), isTrue,
        reason: '侧栏用户头像组件必须存在（新扫描源）');
    expect(templatesPage.existsSync(), isTrue,
        reason: '模板页组件必须存在（新扫描源）');
    final userSource = userBlock.readAsStringSync();
    final templatesSource = templatesPage.readAsStringSync();
    // 文案写死为"期望存在"：组件里没长出来时先红。
    for (final anchor in const ['换头像', '恢复默认', '头像资料读取失败']) {
      _obs('UserAvatarBlock 文案', anchor);
      expect(userSource, contains(anchor),
          reason: 'UserAvatarBlock.tsx 缺少文案「$anchor」');
      expect(text, contains(anchor), reason: '管理文档缺少「$anchor」的说明');
    }
    for (final anchor in const ['清除头像']) {
      _obs('TemplatesPage 文案', anchor);
      expect(templatesSource, contains(anchor),
          reason: 'TemplatesPage.tsx 缺少文案「$anchor」');
      expect(text, contains(anchor), reason: '管理文档缺少「$anchor」的说明');
    }
  });

  test('RPC 表按行补齐头像载荷（profile.save / config.get / template.save）（change `chat-bubbles-avatars` 7.3b）', () {
    final rows = tableRows(doc.readAsStringSync());
    final firstColumn = {
      for (final row in rows)
        if (row.isNotEmpty) row.first.replaceAll('`', ''),
    };
    _obs('RPC 表第一列', firstColumn);
    expect(firstColumn, contains('profile.save'),
        reason: '管理文档 RPC 表必须有 profile.save 的独立一行');
    final configRow = rows
        .where((row) => row.isNotEmpty && row.first.replaceAll('`', '') == 'config.get')
        .toList();
    _obs('config.get 表行', configRow);
    expect(configRow, isNotEmpty);
    expect(
      configRow.any((row) =>
          row.any((cell) => cell.contains('profile') || cell.contains('identitySeed'))),
      isTrue,
      reason: 'config.get 那一行必须带 profile / identitySeed 字样（整篇子串不算过）',
    );
    final templateRow = rows
        .where((row) => row.isNotEmpty && row.first.replaceAll('`', '') == 'template.save')
        .toList();
    _obs('template.save 表行', templateRow);
    expect(templateRow, isNotEmpty);
    expect(
      templateRow.any((row) => row.any((cell) => cell.contains('avatarPath'))),
      isTrue,
      reason: 'template.save 那一行必须带 avatarPath 字样（整篇子串不算过）',
    );
  });
}
