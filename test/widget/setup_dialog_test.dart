import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/services/model_discovery_service.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/setup_dialog.dart';

/// 首启 / 补问两步向导（change `model-truth-from-gateway` 2.3 改写）。
///
/// 第 2 步从"手填上下文窗口"改成**探测门**：探测成功且目录非空才能 Start，
/// 模型来自目录（缺省第一项），目录与 `discovered_at` 在同一次保存里写回，
/// 写出的配置**没有** `max_context_tokens` 键。
class _FakeProbe implements ModelCatalogProbe {
  _FakeProbe(this.result);

  ModelCatalogProbeResult result;
  final List<({String baseUrl, String apiKey})> calls = [];

  @override
  Future<ModelCatalogProbeResult> fetch({
    required String baseUrl,
    required String apiKey,
    required int previewChars,
  }) async {
    calls.add((baseUrl: baseUrl, apiKey: apiKey));
    return result;
  }
}

const _flash = ModelCatalogEntry(
  id: 'deepseek/deepseek-flash',
  displayName: 'DeepSeek-V4.1-Flash',
  contextWindow: 1048576,
  reasoningEfforts: ['none', 'low', 'high', 'max'],
);
const _kimi = ModelCatalogEntry(
  id: 'kimi/kimi-for-coding',
  displayName: 'K2.8 Preview',
  contextWindow: 262144,
);

ModelCatalogProbeResult _okCatalog() =>
    ModelCatalogProbeResult.success(const [_flash, _kimi], 0);

ModelCatalogProbeResult _emptyCatalog() =>
    ModelCatalogProbeResult.success(const [], 0);

ModelCatalogProbeResult _failedProbe() =>
    ModelCatalogProbeResult.failure('连接失败：Connection refused');

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

/// 走完第一步（填 key 后点"下一步"，等探测返回）。
Future<void> _passStepOne(WidgetTester tester,
    {String key = 'sk-ant-test-key'}) async {
  await _fillStepOne(tester, key: key);
  await tester.tap(find.byKey(const ValueKey('setup-next')));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('SetupDialog（两步向导）', () {
    // ── 2.3 改写：第 2 步是探测门，没有窗口输入 ─────────────────────

    testWidgets('第 1 步是 Provider 三要素；第 2 步是探测后的模型下拉，全流程无窗口输入',
        (tester) async {
      final probe = _FakeProbe(_okCatalog());
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}, probe: probe),
      ));
      await tester.pump();

      // 第一步：Provider 名字 / 网关地址 / API 密钥。
      expect(find.byKey(const ValueKey('setup-provider-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-base-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-api-key')), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget); // labelText
      expect(find.text('下一步'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-model')), findsNothing);
      expect(find.text('Max Context Tokens'), findsNothing);

      await _passStepOne(tester);
      // ignore: avoid_print
      print('  [OBS] 探测调用=${probe.calls}；模型下拉='
          '${find.byKey(const ValueKey('setup-model')).evaluate().length}；'
          '窗口输入=${find.byKey(const ValueKey('setup-max-context-tokens')).evaluate().length}');
      expect(find.text('Max Context Tokens'), findsNothing,
          reason: '窗口输入步已被删除（D2/D3）：窗口取网关目录值');
      expect(find.byKey(const ValueKey('setup-max-context-tokens')), findsNothing);
      expect(find.byKey(const ValueKey('setup-model')), findsOneWidget);
      expect(find.text('DeepSeek-V4.1-Flash'), findsWidgets,
          reason: '下拉显示 display_name');
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('上一步'), findsOneWidget);
      expect(probe.calls.single.baseUrl, 'http://127.0.0.1:3425',
          reason: '探测必须用第 1 步填入的地址');
      expect(probe.calls.single.apiKey, 'sk-ant-test-key',
          reason: '探测必须用第 1 步填入的密钥');
    });

    testWidgets('首启默认名与地址为 magpie 与 127.0.0.1:3425', (tester) async {
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}, probe: _FakeProbe(_okCatalog())),
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

    // ── 空输入 → 报错、对话框不关闭 ────────────────────────────────

    testWidgets('empty API key shows validation error', (tester) async {
      bool completed = false;
      final probe = _FakeProbe(_okCatalog());

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true, probe: probe),
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
      expect(probe.calls, isEmpty, reason: '第一步没过就不该探测');
    });

    // ── 合法输入 + 探测成功 → onComplete，写回目录且无窗口键 ──────────

    testWidgets('valid input + probed catalog triggers onComplete and saves catalog', (tester) async {
      bool completed = false;
      AppConfig? savedConfig;
      final probe = _FakeProbe(_okCatalog());

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(
          onComplete: () => completed = true,
          saveConfig: (config) => savedConfig = config,
          probe: probe,
        ),
      ));
      await tester.pump();

      await _passStepOne(tester);
      // 只有探测成功后才有下拉；此时还没保存。
      expect(completed, isFalse, reason: '还没点 Start');
      await tester.tap(find.text('Start'));
      await tester.pump();

      final general = savedConfig!.agentTypes['general']!;
      final provider = savedConfig!.providers['magpie']!;
      final providerJson = provider.toJson();
      // ignore: avoid_print
      print('  [OBS] 保存后 general.model=${general.model} '
          'window=${general.maxContextTokens} '
          'toJson 含窗口键=${general.toJson().containsKey('max_context_tokens')}；'
          'provider.models=${provider.models.map((m) => m.id).toList()} '
          'discovered_at=${provider.discoveredAt} '
          '目录条目 JSON 键=${(providerJson['models'] as List).first.keys.toList()}');

      expect(completed, isTrue);
      expect(provider.apiKey, 'sk-ant-test-key');
      expect(provider.baseUrl, 'http://127.0.0.1:3425');
      expect(provider.models.map((m) => m.id).toList(),
          ['deepseek/deepseek-flash', 'kimi/kimi-for-coding'],
          reason: '探测到的目录必须在同一次保存里写回 providers.<名>.models');
      expect(provider.discoveredAt, isNotNull,
          reason: '已探测必须以 discovered_at 为准（脏值判定要用它，不许靠目录为空）');
      expect((providerJson['models'] as List).first.containsKey('context_window'),
          isTrue,
          reason: '持久化目录的窗口键必须是 context_window');
      expect(general.model, _flash.id,
          reason: '缺省模型 = 探测目录第一项（网关顺序），产品里没有硬编码模型串');
      expect(general.toJson().containsKey('max_context_tokens'), isFalse,
          reason: '首启写出的配置不含窗口键：缺席 = 从目录推导');
      expect(general.maxContextTokens, isNull);
      expect(
        savedConfig!.agentTypes['general']!.toJson()['input_modalities'],
        ['text'],
        reason: 'setup 写出的配置必须带 input_modalities：默认只有 text',
      );
      expect(general.tools, ToolCatalog.kBaseToolNames,
          reason: '首启默认清单必须覆盖当前基础工具');
    });

    testWidgets('模型下拉可改：存的是目录条目的 id，不是 display_name', (tester) async {
      AppConfig? savedConfig;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        onComplete: () {},
        saveConfig: (config) => savedConfig = config,
        probe: _FakeProbe(_okCatalog()),
      )));
      await tester.pump();

      await _passStepOne(tester);
      await tester.tap(find.byKey(const ValueKey('setup-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('K2.8 Preview').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pump();

      // ignore: avoid_print
      print('  [OBS] 改选第二个模型后 general.model=${savedConfig?.agentTypes['general']?.model}');
      expect(savedConfig!.agentTypes['general']!.model, _kimi.id,
          reason: '下拉显示 display_name，但存进配置的必须是目录条目的 id');
    });

    // ── 探测门：失败 / 空目录都不放行、不写配置 ─────────────────────

    testWidgets('probe failure blocks Start and names the failure', (tester) async {
      bool completed = false;
      AppConfig? saved;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        onComplete: () => completed = true,
        saveConfig: (config) => saved = config,
        probe: _FakeProbe(_failedProbe()),
      )));
      await tester.pump();

      await _passStepOne(tester);
      final error = tester
          .widget<Text>(find.byKey(const ValueKey('setup-error')))
          .data;
      // ignore: avoid_print
      print('  [OBS] 探测失败后错误="$error"；Start 存在=${find.text('Start').evaluate().length}');
      expect(error, contains('探测失败'));
      expect(error, contains('Connection refused'));

      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(completed, isFalse, reason: '探测失败时 Start 不许完成向导');
      expect(saved, isNull, reason: '探测失败不许写出任何配置');
    });

    testWidgets('empty catalog blocks Start', (tester) async {
      bool completed = false;
      AppConfig? saved;
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        onComplete: () => completed = true,
        saveConfig: (config) => saved = config,
        probe: _FakeProbe(_emptyCatalog()),
      )));
      await tester.pump();

      await _passStepOne(tester);
      final error = tester
          .widget<Text>(find.byKey(const ValueKey('setup-error')))
          .data;
      // ignore: avoid_print
      print('  [OBS] 空目录错误="$error"');
      expect(error, contains('目录为空'));

      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(completed, isFalse);
      expect(saved, isNull);
    });

    // ── 补问：合并既有配置，不碰模型/窗口 ──────────────────────────

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
          // general 故意缺 max_context_tokens —— 这从此是**合法状态**（D3）。
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
        probe: _FakeProbe(_okCatalog()),
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
      expect(saved!.providers['anthropic']!.models, (_okCatalog()).entries,
          reason: '补问也要把探测到的目录写回该 Provider');
      expect(saved!.providers['anthropic']!.discoveredAt, isNotNull);
      expect(saved!.search, {
        'deepseek': {'enabled': true, 'k': 4},
      });
      expect(saved!.spillPreviewChars, 2500);
      expect(saved!.agentTypes.keys.toSet(), {'general', 'reviewer'});
      expect(saved!.agentTypes['reviewer']!.model, 'deepseek-v4');
      expect(general.model, 'claude-custom', reason: '补问不碰模型字段');
      expect(general.toJson().containsKey('max_context_tokens'), isFalse,
          reason: '补问不许顺手塞一个窗口键进去');
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
        probe: _FakeProbe(_okCatalog()),
      )));
      await tester.pump();

      await _fillStepOne(tester, name: 'gateway', key: 'sk-new');
      await tester.tap(find.byKey(const ValueKey('setup-next')));
      await tester.pump();
      await tester.pump();
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
      expect(saved!.agentTypes['reviewer']!.maxContextTokens, 1000,
          reason: '既有覆盖值原样保留（它是合法的目录缺失兜底）');
    });

    // ── barrierDismissible=false ───────────────────────────────────

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
                  builder: (_) => SetupDialog(
                      onComplete: () {}, probe: _FakeProbe(_okCatalog())),
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

    // ── 非法网关地址、两步都过才完成、名字为空 / 重名 ───────────────

    testWidgets('invalid base URL blocked', (tester) async {
      var completed = false;
      AppConfig? saved;
      final probe = _FakeProbe(_okCatalog());
      await tester.pumpWidget(_wrapDialog(SetupDialog(
        onComplete: () => completed = true,
        saveConfig: (config) => saved = config,
        probe: probe,
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
      expect(probe.calls, isEmpty, reason: '地址非法时不该发探测请求');
    });

    testWidgets('两步都过才 onComplete', (tester) async {
      var completed = false;
      AppConfig? saved;
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(
          onComplete: () => completed = true,
          // 必须注入 saveConfig：否则会走 ConfigService.save 写真实的
          // ~/.aliasagent/config.json（测试不许碰用户配置）。
          saveConfig: (config) => saved = config,
          probe: _FakeProbe(_okCatalog()),
        ),
      ));
      await tester.pump();

      // 第一步通过 + 探测成功：还没有完成（还没点 Start）。
      await _passStepOne(tester);
      expect(completed, isFalse);
      expect(saved, isNull);
      expect(find.byKey(const ValueKey('setup-model')), findsOneWidget);

      // 点 Start 才完成。
      await tester.tap(find.text('Start'));
      await tester.pump();
      // ignore: avoid_print
      print('  [OBS] 两步都过后 completed=$completed saved=${saved != null}');
      expect(completed, isTrue);
      expect(saved, isNotNull);
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
        probe: _FakeProbe(_okCatalog()),
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
