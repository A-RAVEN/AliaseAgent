import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/ui/setup_dialog.dart';

Widget _wrapDialog(SetupDialog dialog) {
  return MaterialApp(home: Scaffold(body: dialog));
}

void main() {
  group('SetupDialog', () {
    // ── 4.1 Renders TextField + "Start" button ─────────────────────

    testWidgets('renders API key + max context tokens fields and Start button', (tester) async {
      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () {}),
      ));

      // Two TextFields: API key + max context tokens
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('API Key'), findsOneWidget); // labelText
      expect(find.text('Max Context Tokens'), findsOneWidget); // labelText

      // "Start" button (NOT "Save")
      expect(find.text('Start'), findsOneWidget);
    });

    // ── 4.2 Empty input → error, dialog stays ──────────────────────

    testWidgets('empty API key shows validation error', (tester) async {
      bool completed = false;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));

      // Tap "Start" with empty input
      await tester.tap(find.text('Start'));
      await tester.pump();

      // onComplete should NOT have been called
      expect(completed, isFalse);

      // Error message should appear
      expect(find.text('Please enter an API key'), findsOneWidget);

      // Dialog should still be present
      expect(find.byType(SetupDialog), findsOneWidget);
    });

    // ── 4.3 Valid key → onComplete called ──────────────────────────

    testWidgets('valid API key triggers onComplete', (tester) async {
      bool completed = false;
      AppConfig? savedConfig;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(
          onComplete: () => completed = true,
          saveConfig: (config) => savedConfig = config,
        ),
      ));

      // Enter a valid key + a valid max context token count
      await tester.enterText(find.byType(TextField).at(0), 'sk-ant-test-key');
      await tester.enterText(find.byType(TextField).at(1), '200000');
      await tester.pump();

      // Tap "Start"
      await tester.tap(find.text('Start'));
      await tester.pump();

      // onComplete should have been called
      expect(completed, isTrue);

      // saveConfig should have been called with a valid config
      expect(savedConfig, isNotNull);
      expect(savedConfig!.providers['anthropic']!.apiKey, 'sk-ant-test-key');
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

      await tester.enterText(find.byType(TextField).at(0), 'sk-new-key');
      await tester.enterText(find.byType(TextField).at(1), '300000');
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

    // ── 4.3b Max context tokens is required → validation error ─────

    testWidgets('missing max context tokens shows validation error', (tester) async {
      bool completed = false;

      await tester.pumpWidget(_wrapDialog(
        SetupDialog(onComplete: () => completed = true),
      ));

      // Enter only the API key — max context tokens left empty
      await tester.enterText(find.byType(TextField).at(0), 'sk-ant-test-key');
      await tester.pump();

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
  });
}
