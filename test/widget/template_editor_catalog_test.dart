import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/services/agent_template_controller.dart';
import 'package:alias_agent/ui/agent_template_editor.dart';

/// 模板编辑器对接模型目录（change `add-provider-model-discovery` 任务 6.4）。
///
/// 假目录含：带 `video` 的条目、窗口未知的条目、无 `native_endpoints` 的条目、
/// 目录档位含执行层不支持名字的条目。断言回填、过滤、可见提示与"目录外手输仍可保存"。
void main() {
  const flash = ModelCatalogEntry(
    id: 'deepseek/deepseek-flash',
    displayName: 'DeepSeek-V4.1-Flash',
    contextWindow: 1048576,
    maxOutputTokens: 393216,
    inputModalities: ['text', 'image'],
    outputModalities: ['text'],
    reasoningEfforts: ['none', 'low', 'high', 'max'],
    nativeEndpoints: ['/v1/messages'],
    pricing: {'prompt': '0.00000015'},
  );
  const kimi = ModelCatalogEntry(
    id: 'kimi/kimi-for-coding',
    displayName: 'K2.8 Preview',
    contextWindow: 1048576,
    inputModalities: ['text', 'image', 'video'],
    outputModalities: ['text'],
    reasoningEfforts: ['none', 'low', 'high', 'max'],
  );
  const noWindowNoNative = ModelCatalogEntry(
    id: 'unknown/window-model',
    displayName: '窗口未知',
    inputModalities: ['text'],
    reasoningEfforts: [],
  );
  const weirdEfforts = ModelCatalogEntry(
    id: 'weird/efforts',
    displayName: '档位方言',
    contextWindow: 4096,
    inputModalities: ['text'],
    reasoningEfforts: ['low', 'crazy', 'xhigh'],
  );
  const deepseekOther = ModelCatalogEntry(
    id: 'deepseek/other',
    displayName: '另一个模型',
    contextWindow: 1000,
    inputModalities: ['text'],
  );

  final catalogs = <String, List<ModelCatalogEntry>>{
    'magpie': [flash, kimi, noWindowNoNative, weirdEfforts],
    'deepseek': [deepseekOther],
  };

  Widget wrap(AgentTemplateEditor editor) =>
      MaterialApp(home: Scaffold(body: editor));

  Future<void> selectModel(WidgetTester tester, String displayName) async {
    await tester.tap(find.byKey(const ValueKey('template-model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(displayName).last);
    await tester.pumpAndSettle();
  }

  String windowText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('template-window')))
      .controller!
      .text;

  bool chipSelected(WidgetTester tester, String modality) => tester
      .widget<FilterChip>(find.byKey(ValueKey('modality-chip-$modality')))
      .selected;

  testWidgets('选目录模型：预填 1048576、模态只有 text/image、无 native 的条目仍可选', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AgentTemplateDraft? saved;
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      await tester.pumpWidget(wrap(AgentTemplateEditor(
        providers: const ['magpie', 'deepseek'],
        catalogs: catalogs,
        availableTools: const ['read_file'],
        onSave: (draft) async => saved = draft,
      )));
      await tester.pump();

      await selectModel(tester, 'DeepSeek-V4.1-Flash');
      // ignore: avoid_print
      print('  [OBS] 选中 flash 后窗口=${windowText(tester)} '
          'text 勾选=${chipSelected(tester, 'text')} '
          'image 勾选=${chipSelected(tester, 'image')} '
          'video chip 存在=${find.byKey(const ValueKey('modality-chip-video')).evaluate().length}');
      // ignore: avoid_print
      print('  [OBS] native 说明=${_textOf(tester, const ValueKey('template-native-endpoints'))}');
      // ignore: avoid_print
      print('  [OBS] pricing 说明=${_textOf(tester, const ValueKey('template-pricing'))}');

      expect(windowText(tester), '1048576', reason: '窗口以目录值回填');
      expect(chipSelected(tester, 'text'), isTrue);
      expect(chipSelected(tester, 'image'), isTrue);
      expect(find.byKey(const ValueKey('modality-chip-video')), findsNothing,
          reason: 'video 不在产品能发送的模态里，不该出现可勾选项');
      expect(_textOf(tester, const ValueKey('template-native-endpoints')),
          contains('/v1/messages'));
      expect(_textOf(tester, const ValueKey('template-pricing')),
          contains('0.00000015'));

      // 无 native_endpoints 的条目：照常可选，且不显示任何 native 说明。
      await selectModel(tester, 'K2.8 Preview');
      expect(find.byKey(const ValueKey('template-native-endpoints')), findsNothing);
      final omitted = _textOf(tester, const ValueKey('template-omitted-modalities'));
      // ignore: avoid_print
      print('  [OBS] kimi(video) 略去说明=$omitted；日志行=${logs.where((l) => l.contains('目录模态')).toList()}');
      expect(omitted, contains('video'));
      expect(logs.any((l) => l.contains('目录模态') && l.contains('video')), isTrue,
          reason: '略去必须有一行日志点名');
      expect(chipSelected(tester, 'text'), isTrue);
      expect(chipSelected(tester, 'image'), isTrue);

      // 窗口未知条目：窗口留空 + 明确提示。
      await selectModel(tester, '窗口未知');
      final hint = _textOf(tester, const ValueKey('template-window-hint'));
      // ignore: avoid_print
      print('  [OBS] 窗口未知条目：窗口="${windowText(tester)}" 提示=$hint');
      expect(windowText(tester), isEmpty);
      expect(hint, contains('目录未提供窗口，请手填（压缩阈值依赖它）'));

      // 目录档位有执行层不支持的取值：不消失，显示一行。
      await selectModel(tester, '档位方言');
      final unsupported = _textOf(tester, const ValueKey('template-unsupported-efforts'));
      // ignore: avoid_print
      print('  [OBS] 不支持档位说明=$unsupported');
      expect(unsupported, contains('crazy'));
      expect(unsupported, contains('暂不被执行层支持'));

      // 保存一次，确认回填的模态进入草稿，且 video 没有混进去。
      await selectModel(tester, 'K2.8 Preview');
      await tester.enterText(find.byKey(const ValueKey('template-name')), 'n1');
      await tester.tap(find.byKey(const ValueKey('save-template')));
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('  [OBS] 保存草稿 model=${saved?.model} '
          'modalities=${saved?.inputModalities} window=${saved?.maxContextTokensText}');
      expect(saved!.inputModalities, isNot(contains('video')));
      expect(saved!.inputModalities, containsAll(<String>['text', 'image']));
    } finally {
      debugPrint = originalDebugPrint;
    }
  });

  testWidgets('provider 下拉列两条；切 provider 后模型下拉换成该 Provider 的目录', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['magpie', 'deepseek'],
      catalogs: catalogs,
      availableTools: const ['read_file'],
      onSave: (draft) async {},
    )));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('template-provider')));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] provider 下拉里的名字：magpie=${find.text('magpie').evaluate().length} '
        'deepseek=${find.text('deepseek').evaluate().length}');
    expect(find.text('magpie'), findsWidgets);
    expect(find.text('deepseek'), findsWidgets);
    await tester.tap(find.text('deepseek').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('template-model-picker')));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 切到 deepseek 后模型下拉：另一个模型=${find.text('另一个模型').evaluate().length} '
        'flash=${find.text('DeepSeek-V4.1-Flash').evaluate().length}');
    expect(find.text('另一个模型'), findsOneWidget);
    expect(find.text('DeepSeek-V4.1-Flash'), findsNothing);
  });

  testWidgets('手输目录外模型可保存，并显示中性提示"不在最近一次目录中"', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AgentTemplateDraft? saved;
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['magpie'],
      catalogs: catalogs,
      availableTools: const ['read_file'],
      onSave: (draft) async => saved = draft,
    )));
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('template-name')), 'n2');
    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'manual/custom-model');
    await tester.enterText(
        find.byKey(const ValueKey('template-window')), '1234');
    await tester.pump();
    final hint = tester
        .widget<TextField>(find.byKey(const ValueKey('template-model')))
        .decoration
        ?.helperText;
    // ignore: avoid_print
    print('  [OBS] 手输目录外模型提示=$hint');
    expect(hint, contains('不在最近一次目录中'));

    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 保存草稿 model=${saved?.model} window=${saved?.maxContextTokensText}');
    expect(saved, isNotNull, reason: '目录外模型不得被拒绝');
    expect(saved!.model, 'manual/custom-model');
  });

  testWidgets('providers 为空：显示"请先在 Providers 页添加供应商"并禁用保存', (tester) async {
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const [],
      availableTools: const ['read_file'],
      onSave: (draft) async {},
    )));
    await tester.pump();

    final banner = find.byKey(const ValueKey('template-editor-no-providers'));
    final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('save-template')));
    // ignore: avoid_print
    print('  [OBS] 无 provider 提示文本='
        '${tester.widget<Text>(find.descendant(of: banner, matching: find.byType(Text))).data}；'
        '保存按钮 onPressed=${save.onPressed}');
    expect(banner, findsOneWidget);
    expect(
        tester
            .widget<Text>(
                find.descendant(of: banner, matching: find.byType(Text)))
            .data,
        '请先在 Providers 页添加供应商');
    expect(save.onPressed, isNull, reason: '没有 provider 时保存必须禁用');
  });
}

String _textOf(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  if (finder.evaluate().isEmpty) return '';
  final widget = tester.widget(finder);
  if (widget is Text) return widget.data ?? '';
  return '';
}
