import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/config_service.dart';
import 'package:alias_agent/ui/setup_dialog.dart';

void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  group('AppShell', () {
    // ── 5.1 Loading spinner ────────────────────────────────────────

    testWidgets('shows loading spinner when config is not yet loaded', (tester) async {
      // notFound does not set _config or _error → loading spinner visible
      await tester.pumpWidget(const MaterialApp(
        home: AppShell(
          configLoader: _notFound,
        ),
      ));

      // First frame: before postFrameCallback fires, _config and _error are null
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // ── 5.2 Malformed config error display ─────────────────────────

    testWidgets('shows error for malformed config', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppShell(
          configLoader: _malformed,
        ),
      ));

      // Error is set in initState → error UI shown immediately
      expect(find.text('Configuration Error'), findsOneWidget);
      expect(find.text('Invalid config file'), findsOneWidget);
    });

    // ── 5.3 Missing config triggers SetupDialog ────────────────────

    testWidgets('notFound config shows loading then SetupDialog after postFrameCallback',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppShell(
          configLoader: _notFound,
        ),
      ));

      // First frame: loading spinner (no config yet, no error)
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Second frame: postFrameCallback fires → showDialog → SetupDialog
      await tester.pump();
      await tester.pump(); // dialog renders in overlay

      // SetupDialog should be visible now
      expect(find.byType(SetupDialog), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget);
    });

    // ── (D3) Config loaded but agent lacks maxContextTokens → NO SetupDialog ──
    //
    // change `model-truth-from-gateway` 2.3：这条判据被**反转**了。缺席
    // `max_context_tokens` 从此是合法状态（生效窗口取网关目录值；目录也没有时在
    // 创建 Agent 那一刻显式失败并点名模板），所以"缺窗口 ⇒ 弹欢迎对话框"的自动
    // 补问入口已删除。旧断言（必须弹 SetupDialog）在这里必然红，故按新语义改写。

    testWidgets('ok config whose agent lacks maxContextTokens does NOT surface SetupDialog (D3)',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: AppShell(
          configLoader: () => ConfigResult.ok(AppConfig(
            version: 1,
            providers: {
              'test': ProviderConfig(apiKey: 'k', baseUrl: ''),
            },
            agentTypes: {
              'general': AgentTypeConfig(
                name: 'general',
                provider: 'test',
                model: 'm',
                systemPrompt: '',
                // maxContextTokens deliberately left null → legal state since D3.
              ),
            },
          )),
        ),
      ));

      // First frame: loading spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Second frame: no setup dialog — the config is legal as-is.
      await tester.pump();
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 缺窗口的合法配置：SetupDialog 数='
          '${find.byType(SetupDialog).evaluate().length}；'
          '主界面存在=${find.byType(ChatScreen).evaluate().length}');
      expect(find.byType(SetupDialog), findsNothing,
          reason: '缺 max_context_tokens 不再是补问触发条件（D3）：'
              '合法配置不许再被欢迎对话框挡住');
      expect(find.byType(ChatScreen), findsOneWidget,
          reason: '直接进入主界面，说明没有弹对话框接管');
    });
  });
}

// ── Test config loaders ─────────────────────────────────────────────

ConfigResult _notFound() => ConfigResult.notFound();

ConfigResult _malformed() => ConfigResult.malformed('Invalid config file');
