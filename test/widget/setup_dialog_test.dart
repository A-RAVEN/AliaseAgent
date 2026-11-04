import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/setup_dialog.dart';

Widget _wrapDialog(SetupDialog dialog) {
  return MaterialApp(home: Scaffold(body: dialog));
}

/// 填第一步的三个输入框（不点按钮）。
Future<void> _fillStepOne(
  WidgetTester tester, {
  String? name,
  String? url,
  String key = 'sk-ant-test-key',
}) async {
  if (name != null) {
    await tester.enterText(
        find.byKey(const ValueKey('setup-provider-name')), name);
  }
  if (url != null) {
    await tester.enterText(find.byKey(const ValueKey('setup-base-url')), url);
  }
  if (key.isNotEmpty) {
    await tester.enterText(find.byKey(const ValueKey('setup-api-key')), key);
  }
  await tester.pump();
}

/// 走完第一步（填 key 后点"下一步"）。
Future<void> _passStepOne(WidgetTester tester, {String key = 'sk-ant-test-key'}) async {
  await _fillStepOne(tester, key: key);
  await tester.tap(find.byKey(const ValueKey('setup-next')));
  await tester.pump();
}

void main() {
  group('SetupDialog（两步向导）', () {
    // ── 4.1 Renders provider fields + "Start" button ───────────────

    testWidgets('renders API key + max context tokens fields and Start button', (tester) async {
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}),
      ));
      await tester.pump();

      // 第一步：Provider 名字 / 网关地址 / API 密钥。
      expect(find.byKey(const ValueKey('setup-provider-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-base-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-api-key')), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget); // labelText
      expect(find.text('下一步'), findsOneWidget);
      // 第二步的窗口输入框此时还不在界面上。
      expect(find.text('Max Context Tokens'), findsNothing);

      await _passStepOne(tester);
      expect(find.text('Max Context Tokens'), findsOneWidget); // labelText
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('上一步'), findsOneWidget);
    });

    testWidgets('首启默认名与地址为 magpie 与 127.0.0.1:3425', (tester) async {
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}),
      ));
      await tester.pump();

      final nameField = tester
          .widget<TextField>(find.byKey(const ValueKey('setup-provider-name')));
      final urlField = tester
          .widget<TextField>(find.byKey(const ValueKey('setup-base-url')));
      final keyField = tester
          .widget<TextField>(find.byKey(const ValueKey('setup-api-key')));
      // ignore: avoid_print
      print('  [OBS] 首启默认值：name="${nameField.controller?.text}" '
          'url="${urlField.controller?.text}" '
          'key="${keyField.controller?.text}" obscure=${keyField.obscureText}');
      expect(nameField.controller?.text, 'magpie',
          reason: '用户 2026-11-04 裁定：首启默认 Provider 名改为 magpie');
      expect(urlField.controller?.text, 'http://127.0.0.1:3425',
          reason: '用户 2026-11-04 裁定：首启默认地址改为本机 magpie 网关，'
              '不再默认指向 api.anthropic.com');
      expect(keyField.controller?.text, 'magpie',
          reason: '用户 2026-11-04 裁定：magpie 网关的密钥约定就叫 magpie，首启预填');
      expect(keyField.obscureText, isTrue, reason: '密钥输入框必须遮蔽');
    });

    // ── 4.2 Empty input → error, dialog stays ──────────────────────

    testWidgets('empty API key shows validation error', (tester) async {
      bool completed = false;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));
      await tester.pump();

      // 第一步只填名称/地址，密钥清空 → 点"下一步"被拒（首启默认会预填 magpie，
      // 这条用例要验"用户清空后仍必须拦住"，不是验证默认值）。
      await tester.enterText(find.byKey(const ValueKey('setup-api-key')), '');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pump();

      expect(completed, isFalse);
      expect(find.text('Please enter an API key'), findsOneWidget);
      expect(find.byType(SetupDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-api-key')), findsOneWidget,
          reason: '校验失败必须停在第一步并保留输入');
    });

    // ── 4.3 Valid key + window → onComplete called ─────────────────

    testWidgets('valid API key triggers onComplete', (tester) async {
      bool completed = false;
      AppConfig? savedConfig;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(
          onComplete: () => completed = true,
          saveConfig: (config) => savedConfig = config,
        ),
      ));
      await tester.pump();

      await _passStepOne(tester);
      await tester.enterText(
          find.byKey(const ValueKey('setup-max-context-tokens')), '200000');
      await tester.pump();

      // 只有两步都过了，"Start"才完成向导。
      expect(completed, isFalse, reason: '第二步还没点 Start');
      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(completed, isTrue);
      expect(savedConfig, isNotNull);
      expect(savedConfig!.providers['magpie']!.apiKey, 'sk-ant-test-key');
      expect(savedConfig!.providers['magpie']!.baseUrl,
          'http://127.0.0.1:3425');
      expect(
        savedConfig!.agentTypes['general']!.maxContextTokens,
        200000,
        reason: 'max context tokens must be required and captured on setup',
      );
      expect(
        savedConfig!.agentTypes['general']!.toJson()['input_modalities'],
        ['text'],
        reason: 'setup 写出的配置必须带 input_modalities：默认只有 text，'
            '模型能不能收图由用户改这一项，且图片不会被静默发出去',
      );
      // ignore: avoid_print
      print('  [OBS] 首启默认工具清单=${savedConfig!.agentTypes['general']!.tools}');
      expect(savedConfig!.agentTypes['general']!.tools,
          ToolCatalog.kBaseToolNames,
          reason: '首启默认清单必须覆盖当前十项基础工具，不能还是旧版那两项');
    });

    testWidgets('补问合并现有配置：provider/search/spill/自定义模板与未编辑字段都保留', (tester) async {
      final existing = AppConfig.fromJson({
        'version': 1,
        'providers': {
          'anthropic': {'api_key': 'old-key', 'base_url': 'https://api.anthropic.com'},
          'deepseek': {'api_key': 'ds-key', 'base_url': 'https://api.deepseek.com'},
        },
        'search': {
          'deepseek': {'enabled': true, 'k': 4},
        },
        'spill': {'preview_chars': 2500},
        'agent_types': {
          // general 故意缺 max_context_tokens —— 这正是补问的触发条件。
          'general': {
            'provider': 'anthropic',
            'model': 'claude-custom',
            'system_prompt': '老的系统提示词',
            'tools': ['read_file', 'run_command'],
            'thinking_effort': 'high',
            'compaction_threshold_percent': 35,
            'compaction_wait_threshold_percent': 70,
            'input_modalities': ['text', 'image'],
            'command_timeout_ms': 5000,
            'command_max_timeout_ms': 9000,
            'standing_requirements': ['不要改用户配置'],
          },
          'reviewer': {
            'provider': 'deepseek',
            'model': 'deepseek-v4',
            'system_prompt': '评审',
            'tools': ['read_file'],
            'max_context_tokens': 64000,
          },
        },
      });
      AppConfig? saved;
      var completed = false;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        existingConfig: existing,
        onComplete: () => completed = true,
        saveConfig: (config) => saved = config,
      )));
      await tester.pump();

      // 补问时名字与地址按 general 实际在用的 provider 预填，密钥不回显。
      final nameField = tester.widget<TextField>(
          find.byKey(const ValueKey('setup-provider-name')));
      final urlField = tester.widget<TextField>(
          find.byKey(const ValueKey('setup-base-url')));
      final keyField = tester.widget<TextField>(
          find.byKey(const ValueKey('setup-api-key')));
      // ignore: avoid_print
      print('  [OBS] 补问预填：name=${nameField.controller?.text} '
          'url=${urlField.controller?.text} key值长度=${keyField.controller?.text.length} '
          'key回显=${keyField.obscureText}');
      expect(nameField.controller?.text, 'anthropic');
      expect(urlField.controller?.text, 'https://api.anthropic.com');
      expect(keyField.controller?.text, isEmpty, reason: '旧密钥不回显');
      expect(keyField.obscureText, isTrue);

      await _passStepOne(tester, key: 'sk-new-key');
      await tester.enterText(
          find.byKey(const ValueKey('setup-max-context-tokens')), '300000');
      await tester.tap(find.text('Start'));
      await tester.pump();

      final general = saved!.agentTypes['general']!;
      // ignore: avoid_print
      print('  [OBS] 补问保存后 providers=${saved!.providers.keys.toList()} '
          'search=${saved!.search} spill=${saved!.spillPreviewChars} '
          'general(model=${general.model}, tools=${general.tools}, '
          'modalities=${general.inputModalities}, '
          'timeout=${general.commandTimeoutMs}/${general.commandMaxTimeoutMs}, '
          'standing=${general.standingRequirements}, '
          'compaction=${general.compactionThresholdPercent}/'
          '${general.compactionWaitThresholdPercent}, window=${general.maxContextTokens}) '
          '其它模板=${saved!.agentTypes.keys.toList()}');

      expect(completed, isTrue);
      expect(saved!.providers.keys.toSet(), {'anthropic', 'deepseek'});
      expect(saved!.providers['anthropic']!.apiKey, 'sk-new-key');
      expect(saved!.providers['deepseek']!.apiKey, 'ds-key');
      expect(saved!.search, {
        'deepseek': {'enabled': true, 'k': 4},
      });
      expect(saved!.spillPreviewChars, 2500);
      expect(saved!.agentTypes.keys.toSet(), {'general', 'reviewer'});
      expect(saved!.agentTypes['reviewer']!.model, 'deepseek-v4');
      expect(general.maxContextTokens, 300000);
      expect(general.model, 'claude-custom');
      expect(general.systemPrompt, '老的系统提示词');
      expect(general.tools, ['read_file', 'run_command']);
      expect(general.thinkingEffort, 'high');
      expect(general.inputModalities, ['text', 'image']);
      expect(general.commandTimeoutMs, 5000);
      expect(general.commandMaxTimeoutMs, 9000);
      expect(general.standingRequirements, ['不要改用户配置']);
      expect(general.compactionThresholdPercent, 35);
      expect(general.compactionWaitThresholdPercent, 70);
    });

    testWidgets('补问时改 Provider 名：引用旧名的模板同一次写回里改过去', (tester) async {
      final existing = AppConfig.fromJson({
        'version': 1,
        'providers': {
          'anthropic': {'api_key': 'old-key', 'base_url': 'https://old.example/v1'},
        },
        'agent_types': {
          'general': {
            'provider': 'anthropic',
            'model': 'claude-custom',
            'system_prompt': '老的',
            'tools': ['read_file'],
          },
          'reviewer': {
            'provider': 'anthropic',
            'model': 'm2',
            'system_prompt': '评审',
            'tools': ['read_file'],
            'max_context_tokens': 1000,
          },
        },
      });
      AppConfig? saved;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        existingConfig: existing,
        onComplete: () {},
        saveConfig: (config) => saved = config,
      )));
      await tester.pump();

      await _fillStepOne(tester, name: 'gateway', key: 'sk-new');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('setup-max-context-tokens')), '5000');
      await tester.tap(find.text('Start'));
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 补问改名后 providers=${saved?.providers.keys.toList()} '
          'general.provider=${saved?.agentTypes['general']?.provider} '
          'reviewer.provider=${saved?.agentTypes['reviewer']?.provider} '
          'baseUrl=${saved?.providers['gateway']?.baseUrl}');
      expect(saved!.providers.keys.toSet(), {'gateway'});
      expect(saved!.providers['gateway']!.baseUrl, 'https://old.example',
          reason: '地址归一化剥掉尾部 /v1');
      expect(saved!.agentTypes['general']!.provider, 'gateway');
      expect(saved!.agentTypes['reviewer']!.provider, 'gateway',
          reason: '引用旧名的其它模板不能悬空');
    });

    // ── 4.3b Max context tokens is required → validation error ─────

    testWidgets('missing max context tokens shows validation error', (tester) async {
      bool completed = false;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));
      await tester.pump();

      await _passStepOne(tester);
      // 第二步的窗口留空。
      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(completed, isFalse);
      expect(
        find.text('Please enter a valid max context token count (a positive integer)'),
        findsOneWidget,
      );
    });

    // ── 4.4 barrierDismissible=false ───────────────────────────────

    testWidgets('tapping outside dialog does not close it', (tester) async {
      // SetupDialog must be shown via showDialog to have a barrier
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SetupDialog(onComplete: () {}),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ));

      // Open the dialog
      await tester.tap(find.text('Open'));
      await tester.pump(); // showDialog schedules insertion
      await tester.pump(); // dialog renders

      expect(find.byType(SetupDialog), findsOneWidget);

      // Tap outside the dialog (top-left corner, far from dialog center)
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();

      // Dialog should still be present (barrierDismissible: false)
      expect(find.byType(SetupDialog), findsOneWidget);
    });

    // ── 新增：非法网关地址、两步都过才完成、名字为空 / 重名 ───────────

    testWidgets('invalid base URL blocked', (tester) async {
      var completed = false;
      AppConfig? saved;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        onComplete: () => completed = true,
        saveConfig: (config) => saved = config,
      )));
      await tester.pump();

      for (final bad in const ['127.0.0.1:3425', 'ftp://x']) {
        await _fillStepOne(tester, url: bad, key: 'sk-ant-test-key');
        await tester.tap(find.byKey(const ValueKey('setup-next')));
        await tester.pump();
        final error = tester
            .widget<Text>(find.byKey(const ValueKey('setup-error')))
            .data;
        // ignore: avoid_print
        print('  [OBS] 非法地址 "$bad" ⇒ 错误="$error"');
        expect(error, contains('网关地址'));
        expect(find.byKey(const ValueKey('setup-api-key')), findsOneWidget,
            reason: '校验失败停在第一步，保留输入');
      }
      expect(completed, isFalse);
      expect(saved, isNull, reason: '非法地址不得落盘');
    });

    testWidgets('两步都过才 onComplete', (tester) async {
      var completed = false;
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));
      await tester.pump();

      // 第一步通过：还没有完成。
      await _passStepOne(tester);
      expect(completed, isFalse);
      expect(find.byKey(const ValueKey('setup-max-context-tokens')), findsOneWidget);

      // 第二步空窗口被拒：仍没完成。
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(completed, isFalse);

      // 两步都合法才完成。
      await tester.enterText(
          find.byKey(const ValueKey('setup-max-context-tokens')), '1000');
      await tester.tap(find.text('Start'));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 两步都过后 completed=$completed');
      expect(completed, isTrue);
    });

    testWidgets('empty or duplicate provider name blocked', (tester) async {
      final existing = AppConfig.fromJson({
        'version': 1,
        'providers': {
          'anthropic': {'api_key': 'k1', 'base_url': 'https://api.anthropic.com'},
          'other': {'api_key': 'k2', 'base_url': 'https://other.example'},
        },
        'agent_types': {
          'general': {
            'provider': 'anthropic',
            'model': 'm',
            'system_prompt': 's',
            'tools': ['read_file'],
            'max_context_tokens': 1000,
          },
        },
      });
      var completed = false;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        existingConfig: existing,
        onComplete: () => completed = true,
        saveConfig: (_) {},
      )));
      await tester.pump();

      // 重名（other 已存在）。
      await _fillStepOne(tester, name: 'other', key: 'sk');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pump();
      var error = tester.widget<Text>(find.byKey(const ValueKey('setup-error'))).data;
      // ignore: avoid_print
      print('  [OBS] 重名错误=$error');
      expect(error, contains('已存在'));

      // 空名字。
      await _fillStepOne(tester, name: ' ', key: 'sk');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pump();
      error = tester.widget<Text>(find.byKey(const ValueKey('setup-error'))).data;
      // ignore: avoid_print
      print('  [OBS] 空名字错误=$error');
      expect(error, contains('Provider 名称'));
      expect(completed, isFalse);
      expect(find.byKey(const ValueKey('setup-api-key')), findsOneWidget);
    });
  });
}
