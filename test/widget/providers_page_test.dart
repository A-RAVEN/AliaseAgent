import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/model_discovery_service.dart';
import 'package:alias_agent/ui/providers_page.dart';

/// Provider 管理页（change `add-provider-model-discovery` 任务 4.4）。
///
/// 假配置 + 假探测服务：两个 Provider 并行列出、改名后模板引用同步写回、
/// 被引用时删除被拒并显示模板名、探测失败行内显示原因且旧目录条数不变、
/// 任何界面文本都不含密钥明文。
void main() {
  late Directory tempDir;
  late String configPath;
  late AppConfig config;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('providers_page_test_');
    configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
    config = AppConfig.fromJson({
      'version': 1,
      'providers': {
        'magpie': {
          'api_key': 'sk-super-secret',
          'base_url': 'http://127.0.0.1:3425/v1',
          'models': [
            const ModelCatalogEntry(
              id: 'deepseek/deepseek-flash',
              displayName: 'DeepSeek-V4.1-Flash',
              contextWindow: 1048576,
            ).toJson(),
            const ModelCatalogEntry(
              id: 'kimi/kimi-for-coding',
              displayName: 'K2.8 Preview',
              contextWindow: 1048576,
            ).toJson(),
          ],
          'discovered_at': '2026-11-04T00:00:00.000Z',
        },
        'anthropic': {
          'api_key': 'sk-anthropic-secret',
          'base_url': 'https://api.anthropic.com',
        },
      },
      'agent_types': {
        'general': {
          'provider': 'magpie',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '你是助手',
          'tools': <String>[],
          'max_context_tokens': 100000,
        },
        'reviewer': {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '评审',
          'tools': <String>[],
          'max_context_tokens': 100000,
        },
      },
    });
    ConfigService.save(config, configPath: configPath);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶尔还有句柄没放掉；不掩盖测试结论。
    }
  });

  Widget wrap(ProviderCatalogDiscovery discovery) => MaterialApp(
        home: Scaffold(
          body: ProvidersPage(
            config: ConfigService.load(configPath: configPath).config!,
            discovery: discovery,
            configPath: configPath,
          ),
        ),
      );

  testWidgets('两个 Provider 并行列出，密钥不以明文出现在界面', (tester) async {
    final fake = _FakeDiscovery();
    await tester.pumpWidget(wrap(fake));
    await tester.pump();

    final allTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    // ignore: avoid_print
    print('  [OBS] 列表文本=$allTexts');
    // ignore: avoid_print
    print('  [OBS] magpie 行=${find.byKey(const ValueKey('providers-row-magpie')).evaluate().length} '
        'anthropic 行=${find.byKey(const ValueKey('providers-row-anthropic')).evaluate().length}');

    expect(find.byKey(const ValueKey('providers-row-magpie')), findsOneWidget);
    expect(find.byKey(const ValueKey('providers-row-anthropic')), findsOneWidget);
    expect(allTexts.join('\n'), contains('地址：http://127.0.0.1:3425'),
        reason: '地址必须显示归一化后的值（存储值尾部 /v1 已剥掉）');
    expect(allTexts.join('\n'), contains('目录 2 条'));
    expect(allTexts.join('\n'), contains('未探测'),
        reason: 'anthropic 没有目录也没有 discovered_at，必须显示"未探测"');
    expect(allTexts.join('\n'), isNot(contains('sk-super-secret')));
    expect(allTexts.join('\n'), isNot(contains('sk-anthropic-secret')));

    // 编辑表单里的密钥框必须是遮蔽输入，且不回填原密钥。
    await tester.tap(find.byKey(const ValueKey('provider-edit-magpie')));
    await tester.pumpAndSettle();
    final keyField = tester
        .widget<TextField>(find.byKey(const ValueKey('provider-api-key')));
    // ignore: avoid_print
    print('  [OBS] 密钥框 obscureText=${keyField.obscureText} '
        '当前值="${keyField.controller?.text}"');
    expect(keyField.obscureText, isTrue);
    expect(keyField.controller?.text, isEmpty);
  });

  testWidgets('改名：同一保存动作改写模板引用并写回配置，保存后自动探测一次', (tester) async {
    final fake = _FakeDiscovery();
    await tester.pumpWidget(wrap(fake));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('provider-edit-magpie')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('provider-name')), 'gateway');
    await tester.tap(find.byKey(const ValueKey('provider-form-save')));
    await tester.pumpAndSettle();

    final saved = ConfigService.load(configPath: configPath).config!;
    // ignore: avoid_print
    print('  [OBS] 改名后 providers=${saved.providers.keys.toList()} '
        'general.provider=${saved.agentTypes['general']!.provider} '
        '探测次数=${fake.calls} 探测对象=${fake.probed} '
        '目录条数=${saved.providers['gateway']?.models.length}');

    expect(saved.providers.keys.toSet(), {'gateway', 'anthropic'});
    expect(saved.providers['gateway']!.apiKey, 'sk-super-secret',
        reason: '编辑时密钥留空 = 沿用原密钥');
    expect(saved.providers['gateway']!.models, hasLength(2),
        reason: '改名不清空目录');
    expect(saved.agentTypes['general']!.provider, 'gateway',
        reason: '引用旧名的模板必须在同一次写回里改成新名');
    expect(saved.agentTypes['reviewer']!.provider, 'anthropic');
    expect(fake.calls, 1, reason: '保存成功后自动探测一次');
    expect(fake.probed, ['gateway']);
    final status = tester
        .widget<Text>(find.byKey(const ValueKey('provider-status-gateway')))
        .data;
    // ignore: avoid_print
    print('  [OBS] 改名并自动探测后的行内结果=$status');
    expect(status, contains('新增 0，更新 0，移除 0，丢弃 0'),
        reason: '成功探测必须显示四类计数');
  });

  testWidgets('被引用的 Provider 删除被拒，该行显示引用模板名，配置不变', (tester) async {
    final fake = _FakeDiscovery();
    await tester.pumpWidget(wrap(fake));
    await tester.pump();
    final before = File(configPath).readAsStringSync();

    await tester.tap(find.byKey(const ValueKey('provider-delete-magpie')));
    await tester.pumpAndSettle();

    final errorText = tester
        .widget<Text>(find.byKey(const ValueKey('provider-delete-error-magpie')))
        .data;
    // ignore: avoid_print
    print('  [OBS] 删除被拒原因=$errorText');
    expect(errorText, contains('general'));
    expect(File(configPath).readAsStringSync(), before);
    expect(ConfigService.load(configPath: configPath).config!.providers.containsKey('magpie'),
        isTrue);
  });

  testWidgets('探测失败：行内显示原因，旧目录条数不变，文本不含密钥', (tester) async {
    final fake = _FakeDiscovery()
      ..fail = true
      ..error = 'HTTP 401';
    await tester.pumpWidget(wrap(fake));
    await tester.pump();
    final before = File(configPath).readAsStringSync();

    await tester.tap(find.byKey(const ValueKey('provider-probe-magpie')));
    await tester.pumpAndSettle();

    final status = tester
        .widget<Text>(find.byKey(const ValueKey('provider-status-magpie')))
        .data;
    final rowText = tester
        .widget<Text>(find.descendant(
          of: find.byKey(const ValueKey('providers-row-magpie')),
          matching: find.byType(Text),
        ).first)
        .data;
    final allTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    // ignore: avoid_print
    print('  [OBS] 探测失败状态=$status；行首文本=$rowText；'
        '含密钥=${allTexts.contains('sk-super-secret')}');

    expect(status, contains('探测失败：HTTP 401'));
    expect(allTexts, contains('目录 2 条'), reason: '探测失败不清空旧目录');
    expect(allTexts, isNot(contains('sk-super-secret')));
    expect(File(configPath).readAsStringSync(), before,
        reason: '探测失败不回滚也不改写已保存配置');
    expect(fake.calls, 1);
  });

  testWidgets('非标准目录失败：行内显示总字符数、略去数与完整响应文件路径', (tester) async {
    final path =
        'C:\\Temp\\model_discovery_error_2026-11-04T00-00-00-000Z.txt';
    final fake = _FakeDiscovery()
      ..fail = true
      ..error = '该端点不是 magpie 标准目录：共 100 字符，已略去 60 字符，'
          '完整内容见 $path';
    await tester.pumpWidget(wrap(fake));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('provider-probe-magpie')));
    await tester.pumpAndSettle();

    final status = tester
        .widget<Text>(find.byKey(const ValueKey('provider-status-magpie')))
        .data;
    final allTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join('\n');
    // ignore: avoid_print
    print('  [OBS] 非标准目录状态=$status；目录条数仍在=${allTexts.contains('目录 2 条')}');

    expect(status, contains('共 100 字符'));
    expect(status, contains('已略去 60 字符'));
    expect(status, contains(path));
    expect(allTexts, contains('目录 2 条'), reason: '失败不清空旧目录');
  });

  testWidgets('新增 Provider：保存后自动探测一次，列表立刻出现该行', (tester) async {    final fake = _FakeDiscovery();
    await tester.pumpWidget(wrap(fake));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('add-provider')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('provider-name')), 'second');
    await tester.enterText(
        find.byKey(const ValueKey('provider-base-url')), 'https://second.example/v1/');
    await tester.enterText(find.byKey(const ValueKey('provider-api-key')), 'sk-second');
    await tester.tap(find.byKey(const ValueKey('provider-form-save')));
    await tester.pumpAndSettle();

    final saved = ConfigService.load(configPath: configPath).config!;
    // ignore: avoid_print
    print('  [OBS] 新增后 providers=${saved.providers.keys.toList()} '
        'second.baseUrl=${saved.providers['second']?.baseUrl} '
        '探测次数=${fake.calls} 探测对象=${fake.probed}');

    expect(saved.providers.keys.toSet(), {'magpie', 'anthropic', 'second'});
    expect(saved.providers['second']!.baseUrl, 'https://second.example');
    expect(find.byKey(const ValueKey('providers-row-second')), findsOneWidget);
    expect(fake.calls, 1);
    expect(fake.probed, ['second']);
  });
}

class _FakeDiscovery implements ProviderCatalogDiscovery {
  int calls = 0;
  final List<String> probed = [];
  bool fail = false;
  String error = 'HTTP 500';

  @override
  Future<ModelDiscoveryReport> discover(AppConfig config, String providerName) async {
    calls++;
    probed.add(providerName);
    final entries = config.providers[providerName]?.models ?? const [];
    return ModelDiscoveryReport(
      success: !fail,
      providerName: providerName,
      entries: entries,
      added: 0,
      updated: 0,
      removed: 0,
      dropped: 0,
      error: fail ? error : null,
      discoveredAt: fail ? config.providers[providerName]?.discoveredAt : '2026-11-04T02:00:00.000Z',
      config: fail
          ? config
          : config.copyWith(providers: {
              ...config.providers,
              providerName: ProviderConfig(
                apiKey: config.providers[providerName]!.apiKey,
                baseUrl: config.providers[providerName]!.baseUrl,
                models: entries,
                discoveredAt: '2026-11-04T02:00:00.000Z',
              ),
            }),
    );
  }
}
