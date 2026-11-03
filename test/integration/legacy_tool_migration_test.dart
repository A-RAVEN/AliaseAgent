import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 旧默认工具清单的**可见**迁移（change `add-agent-object-and-templates` 任务 1.3）。
///
/// 固定三件事：① 旧版首启写出的两项默认清单升级为当前基础工具并给出可见提示；
/// ② 用户自定义的清单（收窄或扩展）原样保留；③ 迁移落盘后重新读取仍是升级后的值。
void main() {
  AppConfig configWith({
    required List<String> generalTools,
    List<String> customTools = const ['read_file', 'run_command'],
  }) {
    return AppConfig.fromJson({
      'version': 1,
      'providers': {
        'test': {'api_key': 'fake-key', 'base_url': ''},
      },
      'search': {
        'deepseek': {'enabled': true},
      },
      'spill': {'preview_chars': 777},
      'agent_types': {
        'general': {
          'provider': 'test',
          'model': 'test-model',
          'system_prompt': '你是助手',
          'tools': generalTools,
          'max_context_tokens': 100000,
          'input_modalities': ['text', 'image'],
        },
        'custom': {
          'provider': 'test',
          'model': 'test-model-2',
          'system_prompt': '你是自定义',
          'tools': customTools,
          'max_context_tokens': 50000,
        },
      },
    });
  }

  test('旧默认两项清单升级为当前基础工具（十一项），并给出可见提示', () {
    final result = ToolListMigration.migrate(
        configWith(generalTools: const ['read_file', 'list_dir']));
    // ignore: avoid_print
    print('  [OBS] 迁移模板=${result.migratedTemplates} '
        '提示=${result.notices} 新清单=${result.config.agentTypes['general']!.tools}');
    expect(result.changed, isTrue);
    expect(result.migratedTemplates, ['general']);
    expect(result.notices.single, contains('general'));
    expect(result.notices.single, contains('旧版首启默认'));
    expect(result.notices.single, contains('11 项'),
        reason: '提示里的数量必须与当前基础清单一致');
    expect(result.config.agentTypes['general']!.tools,
        ToolCatalog.kBaseToolNames);
    expect(result.config.agentTypes['general']!.tools.length, 11);
    expect(result.config.agentTypes['general']!.tools,
        contains('spawn_subagent'));
    // 未开放迁移的字段必须原样：图片模态、窗口。
    expect(result.config.agentTypes['general']!.inputModalities,
        ['text', 'image']);
    expect(result.config.agentTypes['general']!.maxContextTokens, 100000);
  });

  test('旧十项完整形状不自动加回 spawn_subagent（用户删除后重新加载仍保持删除）', () {
    // 上一版完整默认清单的形状 = 当前十一项里去掉 spawn_subagent。
    final oldTen = ToolCatalog.kBaseToolNames
        .where((n) => n != 'spawn_subagent')
        .toList();
    expect(oldTen.length, 10);
    expect(oldTen, isNot(contains('spawn_subagent')));

    final tempDir = Directory.systemTemp.createTempSync('legacy_ten_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(path).writeAsStringSync(
        jsonEncode(configWith(generalTools: oldTen).toJson()));

    // 真实配置加载 → 迁移：不得仅凭"恰好是旧十项形状"就推断用户想自动升级。
    final loaded = ConfigService.load(configPath: path).config!;
    final migrated = ToolListMigration.migrate(loaded);
    // ignore: avoid_print
    print('  [OBS] 旧十项迁移 changed=${migrated.changed} '
        '提示=${migrated.notices} 清单=${migrated.config.agentTypes['general']!.tools}');
    expect(migrated.changed, isFalse,
        reason: '旧十项形状与"用户主动删除"在磁盘上相同，不得自动升级');
    expect(migrated.notices, isEmpty);
    expect(migrated.config.agentTypes['general']!.tools, oldTen);
    expect(migrated.config.agentTypes['general']!.tools,
        isNot(contains('spawn_subagent')));

    // 写回并重新加载：删除仍然保持。
    ConfigService.save(migrated.config, configPath: path);
    final reread = ConfigService.load(configPath: path).config!;
    // ignore: avoid_print
    print('  [OBS] 重新加载后清单（${reread.agentTypes['general']!.tools.length} 项）='
        '${reread.agentTypes['general']!.tools}');
    expect(reread.agentTypes['general']!.tools,
        isNot(contains('spawn_subagent')),
        reason: '重新加载后仍保持删除');
    expect(reread.agentTypes['general']!.tools.toSet(), oldTen.toSet());
    expect(reread.agentTypes['custom']!.tools, ['read_file', 'run_command']);
  });

  test('自定义清单原样保留（收窄与扩展都不迁移）', () {
    for (final tools in const [
      ['read_file'],
      ['read_file', 'run_command'],
      ['read_file', 'list_dir', 'run_command'],
    ]) {
      final result =
          ToolListMigration.migrate(configWith(generalTools: tools));
      // ignore: avoid_print
      print('  [OBS] 自定义清单 $tools -> 迁移=${result.changed} '
          '保存后=${result.config.agentTypes['general']!.tools}');
      expect(result.changed, isFalse);
      expect(result.notices, isEmpty);
      expect(result.config.agentTypes['general']!.tools, tools);
    }
  });

  test('其它模板不受影响；迁移是幂等的', () {
    final first = ToolListMigration.migrate(
        configWith(generalTools: const ['read_file', 'list_dir']));
    final second = ToolListMigration.migrate(first.config);
    // ignore: avoid_print
    print('  [OBS] 第一次 changed=${first.changed} 第二次 changed=${second.changed}；'
        'custom 工具=${first.config.agentTypes['custom']!.tools}');
    expect(first.config.agentTypes['custom']!.tools, ['read_file', 'run_command']);
    expect(second.changed, isFalse, reason: '升级后的清单不是旧形状，不许反复迁移');
    expect(second.config.agentTypes['general']!.tools,
        ToolCatalog.kBaseToolNames);
  });

  test('迁移结果可写盘并重新读回（配置其它段不丢）', () {
    final tempDir = Directory.systemTemp.createTempSync('legacy_tools_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final path = '${tempDir.path}${Platform.pathSeparator}config.json';
    File(path).writeAsStringSync(
        jsonEncode(configWith(generalTools: const ['read_file', 'list_dir'])
            .toJson()));

    final loaded = ConfigService.load(configPath: path).config!;
    final migrated = ToolListMigration.migrate(loaded);
    ConfigService.save(migrated.config, configPath: path);
    final reread = ConfigService.load(configPath: path).config!;
    // ignore: avoid_print
    print('  [OBS] 落盘后 general.tools=${reread.agentTypes['general']!.tools.length} 项；'
        'providers=${reread.providers.keys.toList()} search=${reread.search} '
        'spill=${reread.spillPreviewChars} custom=${reread.agentTypes['custom']!.tools}');
    expect(reread.agentTypes['general']!.tools, ToolCatalog.kBaseToolNames);
    expect(reread.providers.keys, ['test']);
    expect(reread.search?['deepseek'], {'enabled': true});
    expect(reread.spillPreviewChars, 777);
    expect(reread.agentTypes['custom']!.tools, ['read_file', 'run_command']);
  });

  testWidgets('迁移提示在界面上真的可见（不是只写日志）', (tester) async {
    final result = ToolListMigration.migrate(
        configWith(generalTools: const ['read_file', 'list_dir']));
    final notice = result.notices.join('\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: result.config,
          toolMigrationNotice: notice,
          sessionRepo: FakeSessionRepository([]),
          msgRepo: FakeMessageRepository(),
          sidecar: FakeSidecar(),
          backgroundFoldEnabled: false,
        ),
      ),
    ));
    await tester.pump();
    // ignore: avoid_print
    print('  [OBS] 界面上的迁移提示：${find.text(notice).evaluate().length} 处');
    expect(find.byKey(const ValueKey('tool-migration-notice')), findsOneWidget);
    expect(find.textContaining('已升级为当前'), findsOneWidget);
  });
}
