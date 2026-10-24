// `read_image` 工具的 Dart 侧分发与能力门（add-image-input 任务 9.5）。
//
// 关键断言是**调用次数**：模型没声明图片输入时，`read_image` 必须在调 sidecar
// 之前就失败（`readImageCallCount == 0`）—— 实测 `deepseek-v4-pro` 会收下图片却不看，
// 让它读文件只会白烧一轮请求。已声明时应当真的调一次（`== 1`）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import '../widget/helpers/test_utils.dart';
import 'helpers/fake_sidecar.dart';

const _readImageOk = '{"ok":true,'
    '"content":"<path>pic.png</path>\\n<type>image</type>\\n<content>\\n'
    'image/png image, 4x3 px, 98 bytes\\n</content>",'
    '"image":{"path":"pic.png","media_type":"image/png",'
    '"width":4,"height":3,"bytes":98}}';

void _registerAgent({required bool images}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: images ? 'vision-model' : 'text-only-model',
    systemPrompt: '',
    tools: const ['read_file', 'list_dir'],
    inputModalities: images ? const ['text', 'image'] : const ['text'],
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Future<FakeSidecar> _runReadImage(
  WidgetTester tester, {
  required bool images,
}) async {
  _registerAgent(images: images);
  final sidecar = FakeSidecar()
    ..stubReadImage(_readImageOk)
    ..queueToolCall('{"name":"read_image","input":{"path":"pic.png"}}')
    ..queueChunk('看图完毕')
    ..queueDone();

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: FakeSessionRepository(testSessions(1)),
        msgRepo: FakeMessageRepository(),
        sidecar: sidecar,
        summaryProvider: FakeSummaryProvider(),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();

  await tester.enterText(find.byType(TextField), '看看 pic.png');
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
  return sidecar;
}

void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  testWidgets('声明了 image：真的调一次 sidecar，卡片是 Done', (tester) async {
    final sidecar = await _runReadImage(tester, images: true);

    // ignore: avoid_print
    print('  [OBS] readImageCallCount=${sidecar.readImageCallCount} '
        'lastRequest=${sidecar.lastReadImageRequest}');
    expect(sidecar.readImageCallCount, 1,
        reason: '模型能看图时必须真的去读这张图');
    expect(jsonDecode(sidecar.lastReadImageRequest!)['path'], 'pic.png');
    expect(find.text('Done'), findsWidgets);
  });

  testWidgets('没声明 image：sidecar 一次都没被调，卡片是 Error 并写清原因', (tester) async {
    final sidecar = await _runReadImage(tester, images: false);

    // ignore: avoid_print
    print('  [OBS] readImageCallCount=${sidecar.readImageCallCount}');
    expect(sidecar.readImageCallCount, 0,
        reason: '模型看不见图时不该走到 sidecar，白烧一轮请求');

    // 失败文案要能看出是哪一层拒绝的
    await tester.tap(find.text('Error').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('does not declare image input'), findsWidgets,
        reason: '错误里必须说清是"模型没声明图片输入"');
    expect(find.textContaining('text-only-model'), findsWidgets);
  });
}
