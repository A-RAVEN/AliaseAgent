// 带图消息怎么变成请求里的内容块（add-image-input 任务 9.1 / 9.2）。
//
// 断言的是 FakeSidecar 收到的 `messagesJson` 原文，也就是模型真正会看到的东西 ——
// 不去读 `_buildApiMessages` 的返回值，免得测的是实现而不是产物。
//
// 覆盖：带文字带图时块顺序是 text → 说明文本 → image；只有图片时不发空文本块；
// 源文件被删掉时该位置是 `[图片已丢失：<path>]`，同一条消息的其它内容照发。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';
import '../widget/helpers/test_utils.dart';

/// 4×3 的合法 PNG（与 sidecar 夹具同款颜色布局，base64 内联以免依赖外部文件）。
const _png4x3Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAKklEQVR4AWP8z8DAwMDAwMDA'
    'xMDAwMDAwMDAxMDAwMDAwMDAxMDAwMDAwMAAAB4kA0QAAAAASUVORK5CYII=';

void main() {
  late Directory tempDir;

  setUp(() {
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      tools: ['read_file', 'list_dir'],
      // 声明能收图：这条路 9.1 要验的是"能发就发"，能力门是 9.3 的事
      inputModalities: ['text', 'image'],
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
      },
    ));
    tempDir = Directory.systemTemp.createTempSync('img_req_test_');
  });

  tearDown(() {
    registry.clear();
    resolver = null;
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  String writePng({String name = 'pic.png'}) {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(base64Decode(_png4x3Base64));
    return file.path;
  }

  Future<List<dynamic>> sendAndCaptureRequest(
    WidgetTester tester, {
    required List<Message> history,
    required String text,
    required String sessionId,
  }) async {
    final sessions = testSessions(1);
    final sessionRepo = FakeSessionRepository(sessions);
    final msgRepo = FakeMessageRepository(history);
    final sidecar = FakeSidecar()..queueChunk('Reply')..queueDone();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: const AppConfig(version: 1),
          sessionRepo: sessionRepo,
          msgRepo: msgRepo,
          sidecar: sidecar,
          summaryProvider: FakeSummaryProvider(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    if (text.isNotEmpty) {
      await tester.enterText(find.byType(TextField), text);
    }
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();

    final raw = sidecar.lastMessagesJson ?? '';
    // ignore: avoid_print
    print('  [OBS] 请求体（节选）=> '
        '${raw.length > 600 ? raw.substring(0, 600) : raw}');
    expect(raw, isNotEmpty, reason: '请求必须真的发出去了');
    return jsonDecode(raw) as List<dynamic>;
  }

  testWidgets('带文字带图：块顺序是 text → 说明文本 → image', (tester) async {
    final path = writePng();
    final sessionId = testSessions(1).first.id;

    final body = await sendAndCaptureRequest(
      tester,
      sessionId: sessionId,
      history: [
        Message(
          id: 'u1', seq: 1, sessionId: sessionId, role: 'user',
          content: '看看这张图', createdAt: 1, attachments: [path],
        ),
      ],
      text: '继续',
    );

    final userTurn = body.firstWhere(
      (m) => m['role'] == 'user' &&
          (m['content'] as List).any((b) => b['type'] == 'image'),
      orElse: () => null,
    );
    expect(userTurn, isNotNull, reason: '请求里必须出现带 image 块的 user 消息');

    final blocks = (userTurn!['content'] as List).cast<Map<String, dynamic>>();
    final types = blocks.map((b) => b['type']).toList();
    // ignore: avoid_print
    print('  [OBS] 用户消息块类型 => $types');
    expect(types, containsAllInOrder(['text', 'text', 'image']),
        reason: '顺序必须是：正文 → 说明文本 → image 块');

    final imageBlock = blocks.firstWhere((b) => b['type'] == 'image');
    final source = imageBlock['source'] as Map<String, dynamic>;
    expect(source['type'], 'base64');
    expect(source['media_type'], 'image/png');
    expect((source['data'] as String).isNotEmpty, isTrue);

    // 说明文本里要有路径、类型、宽高、字节数
    final note = blocks[1]['text'] as String;
    expect(note, contains(path));
    expect(note, contains('image/png'));
    expect(note, contains('4x3px'));
  });

  testWidgets('只有图片：不发空的 text 块', (tester) async {
    final path = writePng();
    final sessionId = testSessions(1).first.id;

    final body = await sendAndCaptureRequest(
      tester,
      sessionId: sessionId,
      history: [
        Message(
          id: 'u1', seq: 1, sessionId: sessionId, role: 'user',
          content: '', createdAt: 1, attachments: [path],
        ),
      ],
      // ????????"??";?????**????????????**????????
      text: '??',
    );

    final userTurn = body.firstWhere(
      (m) => m['role'] == 'user' &&
          (m['content'] as List).any((b) => b['type'] == 'image'),
    );
    final blocks = (userTurn['content'] as List).cast<Map<String, dynamic>>();
    // ignore: avoid_print
    print('  [OBS] 只有图片时的块 => '
        '${blocks.map((b) => b['type'] == 'text' ? 'text("${b['text']}")' : b['type']).toList()}');

    expect(
      blocks.where((b) => b['type'] == 'text' && (b['text'] as String).isEmpty),
      isEmpty,
      reason: '正文为空时不许发空 text 块',
    );
    expect(blocks.first['type'], 'text',
        reason: '第一块是这张图的说明文本');
    expect(blocks[1]['type'], 'image');
  });

  testWidgets('模型没声明 image：不发图，留一句可见标记', (tester) async {
    // 覆盖 setUp 里"能收图"的那个 agent：这一条要验的是能力门
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'text-only-model',
      systemPrompt: '',
      tools: ['read_file', 'list_dir'],
      // 不写 input_modalities ⇒ 只有 text
    ));

    final path = writePng();
    final sessionId = testSessions(1).first.id;

    final body = await sendAndCaptureRequest(
      tester,
      sessionId: sessionId,
      history: [
        Message(
          id: 'u1', seq: 1, sessionId: sessionId, role: 'user',
          content: '看看这张图', createdAt: 1, attachments: [path],
        ),
      ],
      text: '继续',
    );

    final allBlocks = body
        .expand((m) => (m['content'] as List))
        .cast<Map<String, dynamic>>();
    // ignore: avoid_print
    print('  [OBS] 纯文本模型下的块 => '
        '${allBlocks.map((b) => b['type']).toList()}');

    expect(allBlocks.where((b) => b['type'] == 'image'), isEmpty,
        reason: '模型没声明 image 时，请求里不许出现任何 image 块');

    final marker = allBlocks.firstWhere(
      (b) => b['type'] == 'text' && (b['text'] as String).contains('图片未发送'),
      orElse: () => <String, dynamic>{},
    );
    expect(marker, isNotEmpty, reason: '图没发出去必须留一句可见的说明');
    final text = marker['text'] as String;
    expect(text, contains('text-only-model'));
    expect(text, contains(path));
    expect(text, contains('input_modalities'));
  });

  testWidgets('源文件被删掉：该位置是 [图片已丢失：<path>]，其余照发', (tester) async {
    final path = writePng(name: 'gone.png');
    File(path).deleteSync(); // 模拟"历史里记的路径，文件已经不在了"
    final sessionId = testSessions(1).first.id;

    final body = await sendAndCaptureRequest(
      tester,
      sessionId: sessionId,
      history: [
        Message(
          id: 'u1', seq: 1, sessionId: sessionId, role: 'user',
          content: '这张图你看下', createdAt: 1, attachments: [path],
        ),
      ],
      text: '继续',
    );

    final userTurn = body.firstWhere(
      (m) => m['role'] == 'user' &&
          (m['content'] as List).any(
              (b) => b['type'] == 'text' && (b['text'] as String).contains('图片已丢失')),
    );
    final blocks = (userTurn['content'] as List).cast<Map<String, dynamic>>();
    final marker = blocks
        .firstWhere((b) => b['type'] == 'text' && (b['text'] as String).contains('图片已丢失'));
    expect(marker['text'], '[图片已丢失：$path]');
    expect(blocks.any((b) => b['type'] == 'image'), isFalse,
        reason: '文件不在了就不该有 image 块');
    expect(blocks.first['text'], '这张图你看下',
        reason: '同一条消息的正文要照发');
  });

  testWidgets('带图的工具结果：tool_result.content 是 [文字, image] 数组，正文照旧截断', (tester) async {
    final path = writePng(name: 'tool.png');
    final sessionId = testSessions(1).first.id;

    // 正文远超 8000 字符的截断阈值，用来验证"截断只作用在文字上，图片块不受影响"
    final oversizedResult =
        'line of the read_image envelope that is repeated a lot\n' * 200;

    final body = await sendAndCaptureRequest(
      tester,
      sessionId: sessionId,
      history: [
        Message(
          id: 'u1', seq: 1, sessionId: sessionId, role: 'user',
          content: '读一下那张图', createdAt: 1,
        ),
        Message(
          id: 'a1', seq: 2, sessionId: sessionId, role: 'assistant',
          content: '',
          toolCallsJson: jsonEncode([
            {
              'id': 'call_img',
              'toolName': 'read_image',
              'name': 'read_image',
              'input': {'path': path},
              'result': oversizedResult,
              'image': {'path': path},
            }
          ]),
          createdAt: 2,
        ),
        Message(
          id: 'a2', seq: 3, sessionId: sessionId, role: 'assistant',
          content: '看到了。', createdAt: 3,
        ),
      ],
      text: '继续',
    );

    final toolResultTurn = body.firstWhere(
      (m) => m['role'] == 'user' &&
          (m['content'] as List).any((b) => b['type'] == 'tool_result'),
    );
    final toolResult = (toolResultTurn['content'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((b) => b['type'] == 'tool_result');
    final content = toolResult['content'];
    // ignore: avoid_print
    print('  [OBS] tool_result.content 类型=${content.runtimeType} '
        '块数=${content is List ? content.length : 1}');

    expect(content, isA<List<dynamic>>(),
        reason: '带图的工具结果必须是数组形态');
    final blocks = (content as List).cast<Map<String, dynamic>>();
    expect(blocks, hasLength(2));
    expect(blocks[0]['type'], 'text');
    expect(blocks[0]['text'], contains('tool_result body elided'),
        reason: '正文照旧走截断（这一条验证"截断只作用在文字上"）');
    expect(blocks[1]['type'], 'image');
    final source = blocks[1]['source'] as Map<String, dynamic>;
    expect(source['media_type'], 'image/png');
  });

  testWidgets('请求体不夹带工具活动里的 image 字段（tool_use 只带模型给的四个键）',
      (tester) async {
    final path = writePng(name: 'nodirty.png');
    final sessionId = testSessions(1).first.id;

    final body = await sendAndCaptureRequest(
      tester,
      sessionId: sessionId,
      history: [
        Message(
          id: 'u1', seq: 1, sessionId: sessionId, role: 'user',
          content: '读一下那张图', createdAt: 1,
        ),
        Message(
          id: 'a1', seq: 2, sessionId: sessionId, role: 'assistant',
          content: '',
          toolCallsJson: jsonEncode([
            {
              'id': 'call_img',
              'toolName': 'read_image',
              'name': 'read_image',
              'input': {'path': path},
              'result': '<path>$path</path>',
              'resultPreview': '<path>$path</path>',
              // 这两样都只给界面用：一个是图片路径、一个是活动状态
              'image': {'path': path},
              'status': 'done',
            }
          ]),
          createdAt: 2,
        ),
        Message(
          id: 'a2', seq: 3, sessionId: sessionId, role: 'assistant',
          content: '看到了。', createdAt: 3,
        ),
      ],
      text: '继续',
    );

    final toolUseBlocks = body
        .expand((m) => (m['content'] as List))
        .cast<Map<String, dynamic>>()
        .where((b) => b['type'] == 'tool_use')
        .toList();
    // ignore: avoid_print
    print('  [OBS] tool_use 块 => $toolUseBlocks');
    expect(toolUseBlocks, hasLength(1));

    final block = toolUseBlocks.single;
    expect(block.keys.toSet(), {'type', 'id', 'name', 'input'},
        reason: 'tool_use 只许带这四个键：image / status 这类界面字段不许漏进请求体');
    expect(block['input'], {'path': path});
  });
}
