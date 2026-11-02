import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/ui/agent_template_editor.dart';

/// 模板编辑器（change `add-agent-object-and-templates` 任务 3.2）。
///
/// 固定的是：模板名只在添加时可填、修改时只读；模型改了要当场确认窗口；保存失败
/// 保留输入并指出字段；第一版没有删除 / 改名 / 实例覆盖入口。
void main() {
  const original = AgentTypeConfig(
    name: 'general',
    provider: 'anthropic',
    model: 'claude-sonnet-4-6',
    systemPrompt: '你是助手',
    tools: ['read_file'],
    maxContextTokens: 100000,
    thinkingEffort: 'high',
  );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('添加：填写字段并保存，草稿完整交给回调', (tester) async {
    AgentTemplateDraft? saved;
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['anthropic', 'deepseek'],
      availableTools: const ['read_file', 'write_file', 'run_command'],
      onSave: (draft) async => saved = draft,
    )));
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('template-name')), 'writer');
    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'deepseek-v4');
    await tester.enterText(
        find.byKey(const ValueKey('template-system-prompt')), '你是写作者');
    await tester.enterText(
        find.byKey(const ValueKey('template-window')), '640000');
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('  [OBS] 添加草稿：name=${saved?.name} provider=${saved?.provider} '
        'model=${saved?.model} effort=${saved?.thinkingEffort} '
        'window=${saved?.maxContextTokensText} tools=${saved?.tools} '
        'prompt=${saved?.systemPrompt}');
    expect(saved, isNotNull);
    expect(saved!.isNew, isTrue);
    expect(saved!.name, 'writer');
    expect(saved!.provider, 'anthropic');
    expect(saved!.model, 'deepseek-v4');
    expect(saved!.maxContextTokensText, '640000');
    expect(saved!.tools.toSet(), {'read_file', 'write_file', 'run_command'},
        reason: '添加时默认勾上目录里当前可用的全部工具，用户可再取消');
    expect(saved!.systemPrompt, '你是写作者');
  });

  testWidgets('修改：模板名只读；换模型时当场确认窗口后才保存', (tester) async {
    AgentTemplateDraft? saved;
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      original: original,
      providers: const ['anthropic', 'deepseek'],
      availableTools: const ['read_file', 'write_file'],
      onSave: (draft) async => saved = draft,
    )));
    await tester.pump();

    final nameField =
        tester.widget<TextField>(find.byKey(const ValueKey('template-name')));
    // ignore: avoid_print
    print('  [OBS] 修改模式下模板名 readOnly=${nameField.readOnly} '
        '当前值=${nameField.controller?.text}');
    expect(nameField.readOnly, isTrue, reason: '模板名创建后不可修改');
    expect(nameField.controller?.text, 'general');

    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'claude-opus-4-6');
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();

    // 先弹出窗口确认，还没有保存。
    // ignore: avoid_print
    print('  [OBS] 确认对话框出现=${find.text('确认上下文窗口').evaluate().length}；'
        '此时已保存=${saved != null}');
    expect(find.text('确认上下文窗口'), findsOneWidget);
    expect(saved, isNull, reason: '没确认窗口之前不许保存');

    await tester.tap(find.byKey(const ValueKey('confirm-window')));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 确认后保存：model=${saved?.model} window=${saved?.maxContextTokensText}');
    expect(saved, isNotNull);
    expect(saved!.model, 'claude-opus-4-6');
    expect(saved!.maxContextTokensText, '100000');
    expect(saved!.originalName, 'general');
  });

  testWidgets('模型变了但取消确认 ⇒ 不保存', (tester) async {
    AgentTemplateDraft? saved;
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      original: original,
      providers: const ['anthropic'],
      availableTools: const ['read_file'],
      onSave: (draft) async => saved = draft,
    )));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'another-model');
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 取消确认后 saved=${saved == null ? "null" : saved!.model}');
    expect(saved, isNull);
  });

  testWidgets('保存被拒时保留输入并指出具体字段', (tester) async {
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['anthropic'],
      availableTools: const ['read_file', 'write_file'],
      onSave: (draft) async {
        if (draft.model.trim().isEmpty) {
          throw const AgentTemplateValidationException('模型', '模型不能为空');
        }
        if (draft.tools.contains('write_file') && draft.name == 'dup') {
          throw const AgentTemplateValidationException('模板名', '模板名 "dup" 已存在');
        }
        if (draft.tools.contains('run_command')) {
          throw const AgentTemplateValidationException('工具', '未知工具：run_command');
        }
      },
    )));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('template-name')), 'dup');
    await tester.enterText(find.byKey(const ValueKey('template-window')), '5000');
    await tester.ensureVisible(find.byKey(const ValueKey('tool-chip-write_file')));
    await tester.tap(find.byKey(const ValueKey('tool-chip-write_file')));
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();

    final errorText = tester
        .widget<Text>(find.descendant(
            of: find.byKey(const ValueKey('template-editor-error')),
            matching: find.byType(Text)))
        .data;
    // ignore: avoid_print
    print('  [OBS] 空模型错误=$errorText；'
        '模板名仍为=${tester.widget<TextField>(find.byKey(const ValueKey('template-name'))).controller?.text}；'
        '窗口仍为=${tester.widget<TextField>(find.byKey(const ValueKey('template-window'))).controller?.text}；'
        'write_file 仍取消选中=${!tester.widget<FilterChip>(find.byKey(const ValueKey('tool-chip-write_file'))).selected}');
    expect(errorText, contains('模型：模型不能为空'));
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('template-name')))
            .controller
            ?.text,
        'dup',
        reason: '保存失败必须保留用户输入');
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('template-window')))
            .controller
            ?.text,
        '5000');
    expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('tool-chip-write_file')))
            .selected,
        isFalse,
        reason: '保存失败必须保留用户取消勾选的状态');
  });

  testWidgets('保存失败：模板名重复的控制器错误也显示出来', (tester) async {
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['anthropic'],
      availableTools: const ['read_file'],
      onSave: (draft) async {
        throw AgentTemplateValidationException(
            '模板名', '模板名 "${draft.name}" 已存在：添加被拒绝，既有同名模板保持不变');
      },
    )));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('template-name')), 'general');
    await tester.enterText(find.byKey(const ValueKey('template-model')), 'm');
    await tester.enterText(find.byKey(const ValueKey('template-window')), '1000');
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();
    final errorText = tester
        .widget<Text>(find.descendant(
            of: find.byKey(const ValueKey('template-editor-error')),
            matching: find.byType(Text)))
        .data;
    // ignore: avoid_print
    print('  [OBS] 重复模板名错误=$errorText');
    expect(errorText, contains('已存在'));
  });

  testWidgets('第一版没有删除按钮，也没有改名或实例覆盖入口', (tester) async {
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      original: original,
      providers: const ['anthropic'],
      availableTools: const ['read_file'],
      onSave: (draft) async {},
    )));
    await tester.pump();
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .toList();
    // ignore: avoid_print
    print('  [OBS] 编辑器文本：$texts');
    expect(texts.where((t) => t.contains('删除')), isEmpty);
    expect(texts.where((t) => t.contains('复制')), isEmpty);
    expect(texts.where((t) => t.contains('实例')), isEmpty);
  });

  // 走真实 AgentTemplateController 的校验路径：空模板名 / 空模型 / 重复名 /
  // 未知 provider / 非法窗口 / 未知工具，并核对失败后输入保留。
  group('真实控制器校验（保存被拒、输入保留）', () {
    late Directory tempDir;
    late AgentTypeRegistry registry;
    late AgentTemplateController controller;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('editor_validate_');
      registry = AgentTypeRegistry()
        ..register(const AgentTypeConfig(
          name: 'general',
          provider: 'anthropic',
          model: 'claude-sonnet-4-6',
          systemPrompt: '你是助手',
          tools: ['read_file'],
          maxContextTokens: 100000,
        ));
      controller = AgentTemplateController(
        registry: registry,
        config: const AppConfig(
          version: 1,
          providers: {
            'anthropic': ProviderConfig(
                apiKey: 'sk-x', baseUrl: 'https://api.anthropic.com'),
          },
          agentTypes: {
            'general': original,
          },
        ),
        configPath:
            '${tempDir.path}${Platform.pathSeparator}config.json',
        knownTools: () => const {'read_file', 'write_file'},
      );
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    Future<void> pump(WidgetTester tester,
        {List<String> providers = const ['anthropic'],
        List<String> tools = const ['read_file', 'write_file']}) async {
      await tester.pumpWidget(wrap(AgentTemplateEditor(
        providers: providers,
        availableTools: tools,
        onSave: (draft) async => controller.save(draft),
      )));
      await tester.pump();
    }

    Future<String> saveAndReadError(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('save-template')));
      await tester.pumpAndSettle();
      return tester
          .widget<Text>(find.descendant(
              of: find.byKey(const ValueKey('template-editor-error')),
              matching: find.byType(Text)))
          .data!;
    }

    String nameOf(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const ValueKey('template-name')))
        .controller!
        .text;

    testWidgets('空模板名', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const ValueKey('template-model')), 'm');
      await tester.enterText(find.byKey(const ValueKey('template-window')), '1000');
      final error = await saveAndReadError(tester);
      // ignore: avoid_print
      print('  [OBS] 空模板名错误=$error');
      expect(error, contains('模板名'));
      expect(error, contains('不能为空'));
      expect(registry.listNames(), ['general']);
    });

    testWidgets('空模型', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const ValueKey('template-name')), 'n1');
      await tester.enterText(find.byKey(const ValueKey('template-window')), '1000');
      final error = await saveAndReadError(tester);
      // ignore: avoid_print
      print('  [OBS] 空模型错误=$error');
      expect(error, contains('模型'));
      expect(error, contains('不能为空'));
      expect(nameOf(tester), 'n1', reason: '失败后保留输入');
    });

    testWidgets('重复模板名', (tester) async {
      await pump(tester);
      await tester.enterText(find.byKey(const ValueKey('template-name')), 'general');
      await tester.enterText(find.byKey(const ValueKey('template-model')), 'm');
      await tester.enterText(find.byKey(const ValueKey('template-window')), '1000');
      final error = await saveAndReadError(tester);
      // ignore: avoid_print
      print('  [OBS] 重复名错误=$error');
      expect(error, contains('已存在'));
      expect(nameOf(tester), 'general');
      expect(registry.listNames(), ['general']);
    });

    testWidgets('未知 provider', (tester) async {
      // 修改一个"当前引用了已不存在 provider"的模板：编辑器把它显示出来，
      // 保存时控制器必须拒绝（不静默改成别的 provider）。
      final stale = const AgentTypeConfig(
        name: 'general',
        provider: 'ghost',
        model: 'claude-sonnet-4-6',
        systemPrompt: '你是助手',
        tools: ['read_file'],
        maxContextTokens: 100000,
      );
      await tester.pumpWidget(wrap(AgentTemplateEditor(
        original: stale,
        providers: const ['ghost'],
        availableTools: const ['read_file'],
        onSave: (draft) async => controller.save(draft),
      )));
      await tester.pump();
      final error = await saveAndReadError(tester);
      // ignore: avoid_print
      print('  [OBS] 未知 provider 错误=$error');
      expect(error, contains('provider'));
      expect(error, contains('未定义'));
      expect(registry.listNames(), ['general']);
    });

    testWidgets('非法上下文窗口（0、负数、非整数）', (tester) async {
      await pump(tester);
      for (final window in const ['0', '-3', 'abc']) {
        await tester.enterText(
            find.byKey(const ValueKey('template-name')), 'n3');
        await tester.enterText(find.byKey(const ValueKey('template-model')), 'm');
        await tester.enterText(
            find.byKey(const ValueKey('template-window')), window);
        final error = await saveAndReadError(tester);
        // ignore: avoid_print
        print('  [OBS] 窗口="$window" 错误=$error');
        expect(error, contains('上下文窗口'));
        expect(error, contains('正整数'));
        expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('template-window')))
                .controller
                ?.text,
            window,
            reason: '失败后保留用户填的窗口值');
      }
      expect(registry.listNames(), ['general']);
    });

    testWidgets('未知工具（目录里没有的名字）', (tester) async {
      await pump(tester, tools: const ['read_file', 'mystery_tool']);
      await tester.enterText(find.byKey(const ValueKey('template-name')), 'n4');
      await tester.enterText(find.byKey(const ValueKey('template-model')), 'm');
      await tester.enterText(find.byKey(const ValueKey('template-window')), '1000');
      final error = await saveAndReadError(tester);
      // ignore: avoid_print
      print('  [OBS] 未知工具错误=$error');
      expect(error, contains('未知工具'));
      expect(error, contains('mystery_tool'));
      expect(registry.listNames(), ['general']);
    });
  });
}
