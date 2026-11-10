import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
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

  // change `model-truth-from-gateway` 3.2（D4）：脏模型名可见提示。
  //
  // 判据钉死为 `discovered_at`（**不是**"目录是否为空"）：
  // - 已探测且目录不含该模型 ⇒ 警示（error 色）；
  // - 从未探测 ⇒ 中性文案（onSurfaceVariant 色），不声称模型不存在；
  // - 提示按"编辑器打开那一刻"的快照算，刷新后重开编辑器重算（无实时通道）。
  testWidgets('已探测且目录不含该模型：警示文案点名模型名，且不阻断保存、不改写配置', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    AgentTemplateDraft? saved;
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['magpie'],
      catalogs: catalogs,
      discoveredAtByProvider: const {'magpie': '2026-11-09T00:00:00.000Z'},
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
    final warning = _textOf(
        tester, const ValueKey('template-model-catalog-warning'));
    // ignore: avoid_print
    print('  [OBS] 已探测缺失模型：helperText=$hint；警示=$warning；'
        '中性文案=${find.byKey(const ValueKey('template-model-catalog-unprobed')).evaluate().length}');
    expect(hint, contains('当前目录没有这个模型'));
    expect(warning, contains('manual/custom-model'),
        reason: '警示必须点名该模型名');
    expect(
        tester
            .widget<Text>(
                find.byKey(const ValueKey('template-model-catalog-warning')))
            .style
            ?.color,
        isNotNull,
        reason: '警示要有独立视觉权重（error 色），不能和中性说明同色');
    expect(find.byKey(const ValueKey('template-model-catalog-unprobed')),
        findsNothing);

    // 只提示不改写：目录外的名字照样能保存，存的就是用户写的那个。
    await tester.tap(find.byKey(const ValueKey('save-template')));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('  [OBS] 保存草稿 model=${saved?.model} window=${saved?.maxContextTokensText}');
    expect(saved, isNotNull, reason: '提示不是拦截：目录外模型仍可保存');
    expect(saved!.model, 'manual/custom-model');
  });

  testWidgets('从未探测：中性文案"目录未探测"，不声称模型不存在', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(AgentTemplateEditor(
      providers: const ['magpie'],
      // 目录里**有**条目（证明判据不是"目录为空"），但这个 Provider 从未探测。
      catalogs: catalogs,
      discoveredAtByProvider: const {'magpie': null},
      availableTools: const ['read_file'],
      onSave: (draft) async {},
    )));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'manual/custom-model');
    await tester.pump();

    final hint = tester
        .widget<TextField>(find.byKey(const ValueKey('template-model')))
        .decoration
        ?.helperText;
    final neutral = _textOf(
        tester, const ValueKey('template-model-catalog-unprobed'));
    // ignore: avoid_print
    print('  [OBS] 未探测：helperText=$hint；中性=$neutral；'
        '警示=${find.byKey(const ValueKey('template-model-catalog-warning')).evaluate().length}');
    expect(hint, contains('目录未探测'));
    expect(neutral, contains('这不代表模型不存在'));
    expect(find.byKey(const ValueKey('template-model-catalog-warning')),
        findsNothing, reason: '未探测时不许出现"不存在"级别的警示');
  });

  testWidgets('刷新后重开编辑器：新目录包含该模型 ⇒ 警示消失、不留残留', (tester) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget editor(String key) => wrap(AgentTemplateEditor(
          key: ValueKey(key),
          providers: const ['magpie'],
          catalogs: catalogs,
          discoveredAtByProvider: const {'magpie': '2026-11-09T00:00:00.000Z'},
          availableTools: const ['read_file'],
          onSave: (draft) async {},
        ));

    await tester.pumpWidget(editor('before-refresh'));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('template-model')), 'deepseek/other');
    await tester.pump();
    expect(find.byKey(const ValueKey('template-model-catalog-warning')),
        findsOneWidget, reason: '刷新前：目录里没有 deepseek/other');
    // ignore: avoid_print
    print('  [OBS] 刷新前警示='
        '${_textOf(tester, const ValueKey('template-model-catalog-warning'))}');

    // 用户在 Providers 页刷新了目录（新目录包含该模型），然后重开编辑器。
    final refreshed = <String, List<ModelCatalogEntry>>{
      'magpie': [...catalogs['magpie']!, deepseekOther],
    };
    await tester.pumpWidget(wrap(AgentTemplateEditor(
      key: const ValueKey('after-refresh'),
      original: AgentTypeConfig(
        name: 'general',
        provider: 'magpie',
        model: 'deepseek/other',
        systemPrompt: '',
        tools: const ['read_file'],
      ),
      providers: const ['magpie'],
      catalogs: refreshed,
      discoveredAtByProvider: const {'magpie': '2026-11-10T00:00:00.000Z'},
      availableTools: const ['read_file'],
      onSave: (draft) async {},
    )));
    await tester.pump();

    // ignore: avoid_print
    print('  [OBS] 刷新后：警示='
        '${find.byKey(const ValueKey('template-model-catalog-warning')).evaluate().length} '
        '中性=${find.byKey(const ValueKey('template-model-catalog-unprobed')).evaluate().length} '
        'helperText=${tester.widget<TextField>(find.byKey(const ValueKey('template-model'))).decoration?.helperText}');
    expect(find.byKey(const ValueKey('template-model-catalog-warning')),
        findsNothing, reason: '新目录包含该模型 ⇒ 警示必须消失');
    expect(find.byKey(const ValueKey('template-model-catalog-unprobed')),
        findsNothing, reason: '已探测的 Provider 不该退回中性文案');
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
