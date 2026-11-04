import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Provider / 模型目录文档与界面文案、配置解析路径的一致性
/// （change `add-provider-model-discovery` 任务 8.3）。
///
/// 只核对能失败的事实：文档里的界面词必须在产品代码里原样找得到；配置键
/// `models` / `discovered_at` 必须同时出现在文档的键表与 `ProviderConfig.fromJson`
/// 的解析路径里；8.1 点名的"已知限制"三条必须逐条在。
void main() {
  const providerDocPath = 'Docs/user-guide/provider-models.md';
  const configDocPath = 'Docs/user-guide/configuration.md';
  const templatesDocPath = 'Docs/user-guide/agent-templates.md';

  final libSources = _allLibSources();

  test('界面词在文档与产品代码里逐词一致', () {
    final providerDoc = File(providerDocPath).readAsStringSync();
    final configDoc = File(configDocPath).readAsStringSync();
    final templatesDoc = File(templatesDocPath).readAsStringSync();
    final joinedCode = libSources.join('\n');

    const words = [
      'Providers',
      '探测',
      '未探测',
      '目录未提供窗口',
      '请先在 Providers 页添加供应商',
    ];
    for (final word in words) {
      // ignore: avoid_print
      print('  [OBS] 界面词「$word」：provider-models=${providerDoc.contains(word)} '
          'configuration=${configDoc.contains(word)} '
          'agent-templates=${templatesDoc.contains(word)} '
          '代码=${joinedCode.contains(word)}');
      expect(joinedCode, contains(word),
          reason: '产品代码里没有这个界面词：$word（文档写了一个代码里不存在的文案？）');
      expect(providerDoc, contains(word),
          reason: '$providerDocPath 缺少界面词：$word');
    }

    // 8.2 的两份文档各自该覆盖到的词。
    for (final word in const ['Providers', '探测', '未探测']) {
      expect(configDoc, contains(word),
          reason: '$configDocPath 缺少界面词：$word');
    }
    for (final word in const [
      'Providers',
      '探测',
      '目录未提供窗口',
      '请先在 Providers 页添加供应商',
    ]) {
      expect(templatesDoc, contains(word),
          reason: '$templatesDocPath 缺少界面词：$word');
    }
  });

  test('8.1 的已知限制三条逐条在', () {
    final providerDoc = File(providerDocPath).readAsStringSync();
    const limits = [
      ('magpie 标准方言', '只认 magpie 标准方言'),
      ('目录不自动刷新', '目录不自动刷新'),
      ('video 收不了', '目录里的 video 接受不了 / 只收 text、image'),
    ];
    for (final (needle, description) in limits) {
      // ignore: avoid_print
      print('  [OBS] 已知限制「$needle」在文档里=${providerDoc.contains(needle)}');
      expect(providerDoc, contains(needle), reason: '已知限制缺少：$description');
    }
  });

  test('配置键 models / discovered_at 同时出现在文档键表与代码解析路径', () {
    final configDoc = File(configDocPath).readAsStringSync();
    final providerSource =
        File('lib/models/provider_config.dart').readAsStringSync();
    for (final key in const ['models', 'discovered_at']) {
      // ignore: avoid_print
      print('  [OBS] 键 $key：文档=${configDoc.contains('`$key`')} '
          '代码读=${providerSource.contains("['$key']")} '
          '代码写=${providerSource.contains("'$key':")}');
      expect(configDoc, contains('`$key`'),
          reason: '$configDocPath 的键表里没有 `$key`');
      expect(providerSource, contains("['$key']"),
          reason: 'ProviderConfig.fromJson 没有读 $key');
      expect(providerSource, contains("'$key':"),
          reason: 'ProviderConfig.toJson 没有写回 $key');
    }
  });

  test('8.1 的四类计数与失败原因在文档里写清', () {
    final providerDoc = File(providerDocPath).readAsStringSync();
    for (final word in const ['新增', '更新', '移除', '丢弃', '探测失败']) {
      // ignore: avoid_print
      print('  [OBS] 计数/失败词「$word」在 provider-models.md=${providerDoc.contains(word)}');
      expect(providerDoc, contains(word),
          reason: '$providerDocPath 没有写清「$word」');
    }
    expect(providerDoc, contains('model_discovery_error_'),
        reason: '文档必须写出完整响应的落盘文件前缀');
    expect(providerDoc, contains('preview_chars'),
        reason: '文档必须写出预览长度来自 spill.preview_chars');
  });
}

List<String> _allLibSources() {
  final dir = Directory('lib');
  if (!dir.existsSync()) return const [];
  return [
    for (final f in dir.listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f.readAsStringSync(),
  ];
}
