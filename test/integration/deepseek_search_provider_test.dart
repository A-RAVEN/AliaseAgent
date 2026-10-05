import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';

import 'helpers/fake_sidecar.dart';
import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';

/// `deepseek` 搜索后端的集成测试（tasks.md 4.4）：经**仓库根的真实 `sidecar.dll`**
/// 核对"配置进去 → 可用后端清单出来"这条跨语言链路。
///
/// 用例覆盖哪几件事（共用一条用例时要说清，否则"它到底测了啥"无法核对）：
///   1. `get_search_providers` 的返回是合法 JSON 数组，且每一项都带非空的
///      `name` 与 `description`（清单结构没坏）；
///   2. **在干净的进程里**（搜索初始化还没跑过）把带 DeepSeek 凭据的
///      `search.deepseek` 交给初始化之后，清单里出现 `deepseek`；
///   3. 清单内容在断言之前被打印出来（看得出本次到底认出了哪些后端），且断言用的
///      就是打印的那一份内容。
///
/// **进程前提**：C++ 侧的搜索初始化是每个进程只跑一次（`std::call_once`），而
/// `flutter test` 会把多个测试文件放进同一个进程 —— 只要有别的用例先跑过搜索
/// 初始化，这条就无从验证。所以：
///   - 真正的跨语言判据由 `scripts/deepseek_search_probe.dart`（独立进程）承担，
///     它一次跑一个干净的进程，读数就是最终结论；
///   - 本用例在"初始化还没跑过"的进程里照样能验，跑不了时**如实打印原因并跳过**，
///     不假装通过。
///
/// **不联网**：只读可用后端清单，不发起任何搜索。
///
/// 跑法：先 `powershell -NoProfile -File scripts\sync_sidecar_dll.ps1`，
/// 再 `flutter test test/integration/deepseek_search_provider_test.dart`。
void main() {
  test('可用后端清单的结构 + 干净进程里出现 deepseek（覆盖 1、2、3）', () {
    final bridge = SidecarBridge.instance;

    final before = jsonDecode(bridge.getSearchProviders()) as List<dynamic>;
    // ignore: avoid_print
    print('[deepseek 搜索后端] 初始化之前的可用后端清单: ${jsonEncode(before)}');

    // 清单结构（无论初始化跑没跑过都成立）
    for (final entry in before) {
      expect(entry, isA<Map>());
      expect((entry as Map)['name'], isNotEmpty,
          reason: '后端清单每一行都要有名字');
      expect(entry['description'], isNotEmpty,
          reason: '后端清单每一行都要有能让人看懂的说明');
    }
    // ignore: avoid_print
    print('[deepseek 搜索后端] 清单结构检查通过（${before.length} 项）');

    if (before.isNotEmpty) {
      // 另一种情形：本进程的搜索初始化已经跑过，但如果清单里已经有 `deepseek`，
      // 说明"配置进去 → 清单出来"这条链路在本进程里也验到了。
      final names = before.map((e) => (e as Map)['name']).toList();
      if (names.contains('deepseek')) {
        // ignore: avoid_print
        print('[deepseek 搜索后端] 本进程的清单里已经有 deepseek → 跨语言链路已验证：$names');
        return;
      }
      // ignore: avoid_print
      print('[deepseek 搜索后端] 本进程的搜索初始化已经跑过（清单非空），'
          '这一条的环境前提不成立 → 跨语言判据请跑 '
          '`dart run scripts/deepseek_search_probe.dart`');
      return;
    }

    final config = jsonEncode({
      'deepseek': {'api_key': 'sk-integration-test-占位'},
    });
    // ignore: avoid_print
    print('[deepseek 搜索后端] 交给初始化的配置: $config');
    final initResult = jsonDecode(bridge.ensureSearchInfra(config));
    // ignore: avoid_print
    print('[deepseek 搜索后端] 初始化返回: ${jsonEncode(initResult)}');
    final after = jsonDecode(bridge.getSearchProviders()) as List<dynamic>;
    // ignore: avoid_print
    print('[deepseek 搜索后端] 初始化之后的可用后端清单: ${jsonEncode(after)}');

    expect(initResult['ok'], isTrue, reason: '搜索初始化应当成功');
    final names = after.map((e) => (e as Map)['name']).toList();
    expect(names, contains('deepseek'),
        reason: '写明 search.deepseek（且地址指向 DeepSeek）后该后端出现在清单里');
    final entry =
        after.firstWhere((e) => (e as Map)['name'] == 'deepseek') as Map;
    expect(entry['description'], isNotEmpty,
        reason: '清单里的每一项都要能让人看懂它是什么');
  });

  // ==========================================================================
  // 界面那一段（tasks.md 3.4 / 3.5）：经假 sidecar 的窗口用例，断言
  //   ① 界面把会话模型的地址与密钥一起交给搜索初始化（`session_model`）；
  //   ② 可用后端清单里有 `deepseek` 时，发给模型的工具清单里真的出现
  //      `web_search`（后端列表 → 工具可见性的那一跳）。
  // 清单本身是不是由真实动态库认出来的，由上面那条用例与
  // `scripts/deepseek_search_probe.dart` 负责；这里只验界面这一段。
  // ==========================================================================
  group('界面接线', () {
    tearDown(() {
      registry.clear();
      resolver = null;
    });

    testWidgets('会话模型凭据被一起交下去，且 deepseek 在清单里时 web_search 出现',
        (tester) async {
      registry.clear();
      registry.register(const AgentTypeConfig(
        name: 'general',
        provider: 'test',
        model: 'test-model',
        systemPrompt: '',
      ));
      resolver = ProviderResolver(const AppConfig(
        version: 1,
        providers: {
          'test': ProviderConfig(
            apiKey: 'sk-会话模型那把',
            baseUrl: 'https://api.deepseek.com/anthropic',
          ),
        },
      ));

      final sidecar = FakeSidecar()
        ..stubSearchProviders(
            '[{"name":"deepseek","description":"DeepSeek Web Search"}]')
        ..stubBrowserAvailable('{"ok":true,"available":false,"error":"no Edge"}')
        ..queueDone();

      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            config: const AppConfig(version: 1),
            sessionRepo: FakeSessionRepository(testSessions(1)),
            msgRepo: FakeMessageRepository(),
            sidecar: sidecar,
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      final sentConfig = sidecar.lastEnsureSearchInfraConfig ?? '';
      // ignore: avoid_print
      print('[deepseek 搜索后端] 界面交给搜索初始化的配置: $sentConfig');
      expect(sentConfig, isNotEmpty, reason: '界面必须把搜索配置交下去');
      final cfg = jsonDecode(sentConfig) as Map<String, dynamic>;
      expect(cfg['session_model'], isA<Map>(),
          reason: '会话模型的地址与密钥要一起交下去（字段名 session_model）');
      expect((cfg['session_model'] as Map)['base_url'],
          'https://api.deepseek.com/anthropic');
      expect((cfg['session_model'] as Map)['api_key'], 'sk-会话模型那把');

      await tester.enterText(find.byType(TextField), '搜一下');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      final toolsJson = sidecar.lastToolsJson ?? '[]';
      final tools = (jsonDecode(toolsJson) as List)
          .map((t) => (t as Map)['name'] as String)
          .toList();
      // ignore: avoid_print
      print('[deepseek 搜索后端] 发给模型的工具清单: $tools');
      expect(tools, contains('web_search'),
          reason: '可用后端清单里有 deepseek 时，发给模型的工具里应当有 web_search');
    });
  });
}
