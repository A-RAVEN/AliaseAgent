import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_provider.dart';
import 'package:alias_agent/services/compaction/summary_reference.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../integration/helpers/fake_sidecar.dart';

Message _msg(String role, String content, {String? toolCallsJson, int? seq}) {
  return Message(
    id: 'm${content.hashCode}',
    sessionId: 's',
    role: role,
    content: content,
    toolCallsJson: toolCallsJson,
    seq: seq,
    createdAt: content.length,
  );
}

AgentTypeConfig _config() => AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '',
      maxContextTokens: 200,
    );

ProviderResolver _resolver() => ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
      },
    ));

void main() {
  group('ModelSummaryProvider — tool-round summarizer CONTRACT', () {
    // NOTE scope: this is a summarizer CONTRACT test — it feeds a pre-built folded
    // list directly, so it does NOT exercise the production `_buildChatItems`
    // wiring that R-A2-5d actually changed (that is covered by the compaction_
    // projection_test 'R-A2-5d FIX' widget test, which drives `_loadMessages` ->
    // `_buildChatItems` -> fold input -> summarizer). It verifies the summarizer
    // RENDERS the tool round IF given one.
    test('a content-empty tool-call assistant input.path is rendered inline', () async {
      // A content-empty assistant carrying a tool_use (input.path = a re-execution
      // key, e.g. /Users/acme/src/config.dart). Per D7 it has no bubble text, but
      // its tool_use input must STILL reach the summarizer via _toolRoundText — else
      // the absolute path never enters the summary (the folded conversation would be
      // missing the tool round entirely).
      final sidecar = FakeSidecar()
        ..queueChunk('摘要：读取了 config.dart 并把连接超时改成了 30 秒。')
        ..queueDone(outputTokens: 24);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());

      final toolAssistant = _msg('assistant', '',
          toolCallsJson: jsonEncode([
            {
              'id': 'call_read_config',
              'toolName': 'read_file',
              'name': 'read_file',
              'input': {'path': '/Users/acme/src/config.dart'},
              'result': '// connection timeout (seconds)\nconst timeout = 120;',
            }
          ]));

      final result = await provider.summarize(folded: [toolAssistant], config: _config());
      expect(result.text, isNotEmpty, reason: 'the summarizer produced a summary');
      expect(result.tokens, greaterThan(0), reason: 'measured output_tokens are used');

      // The summarizer's request JSON must inline the tool round: the tool name and
      // the absolute path (the re-execution key) rendered by _toolRoundText.
      final sent = sidecar.lastMessagesJson!;
      expect(sent, contains('read_file'),
          reason: 'the tool name of a content-empty assistant must be in the folded '
              'transcript (kSummarizeInstruction demands tool call names + inputs)');
      expect(sent, contains('/Users/acme/src/config.dart'),
          reason: 'the tool_use input absolute path must reach the summarizer — it is '
              'the re-execution key the A-2 summary is asserted to preserve');
    });
  });

  group('ModelSummaryProvider — 图片被压缩时要留一句可见的省略说明（10.3）', () {
    test('被折叠的段里有一张图 ⇒ 摘要末尾追加"本段另有 1 张图片"', () async {
      final sidecar = FakeSidecar()
        ..queueChunk('摘要：用户贴了一张截图，问了配色。')
        ..queueDone(outputTokens: 20);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());

      final withImage = Message(
        id: 'u1',
        sessionId: 's',
        role: 'user',
        content: '看看这张图的配色',
        createdAt: 1,
        attachments: const ['C:/tmp/a.png'],
      );
      final reply = _msg('assistant', '图里的主色是深蓝。');

      final result = await provider.summarize(
          folded: [withImage, reply], config: _config());
      // ignore: avoid_print
      print('  [OBS] 摘要正文 => ${result.text}');

      expect(result.text, contains('本段另有 1 张图片'),
          reason: '图没进摘要却不说，就是静默丢内容');
      expect(result.text, contains('原始记录仍在本地数据库'),
          reason: '砍掉的内容要给出可恢复的去处');
      expect(result.text, contains('真实上下文'));
    });

    test('被折叠的段里没有图 ⇒ 一个字都不加', () async {
      final sidecar = FakeSidecar()
        ..queueChunk('摘要：只是聊天。')
        ..queueDone(outputTokens: 12);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());

      final result = await provider.summarize(
          folded: [_msg('user', '你好'), _msg('assistant', '你好，有什么可以帮你')],
          config: _config());
      expect(result.text, isNot(contains('本段另有')));
      expect(result.text, isNot(contains('图片')));
    });

    test('工具轮带回来的图也算在内（用户贴的 + 工具读的 = 2 张）', () async {
      final sidecar = FakeSidecar()
        ..queueChunk('摘要：贴了一张、又让模型读了一张。')
        ..queueDone(outputTokens: 18);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());

      final userImage = Message(
        id: 'u1',
        sessionId: 's',
        role: 'user',
        content: '贴一张',
        createdAt: 1,
        attachments: const ['C:/tmp/pasted.png'],
      );
      final toolRound = _msg('assistant', '', toolCallsJson: jsonEncode([
        {
          'id': 'call_img',
          'toolName': 'read_image',
          'name': 'read_image',
          'input': {'path': 'pic.png'},
          'result': '<path>pic.png</path>',
          'image': {'path': 'pic.png'},
        }
      ]));

      final result = await provider.summarize(
          folded: [userImage, toolRound], config: _config());
      // ignore: avoid_print
      print('  [OBS] 带工具轮的摘要 => ${result.text}');
      expect(result.text, contains('本段另有 2 张图片'));
    });
  });

  group('ModelSummaryProvider — 摘要调用的输入 token 观测（本变更新增）', () {
    // 本变更的判据：每一次摘要调用都要把"这次发了多少 token"留成读数。落点在
    // provider 内部（两个方法各自打），所以这里必须把**两个方法都驱动一次** ——
    // 只接住 summarize 而漏掉 summarizeText 时，这条用例要红。
    test('两个方法都把实测输入 token 带出来，并各打一行观测', () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      late SummaryResult foldResult;
      late SummaryResult rollUpResult;
      try {
        final sidecar1 = FakeSidecar()
          ..queueChunk('摘要一：读了配置文件。')
          ..queueDone(inputTokens: 421, outputTokens: 99);
        final p1 = ModelSummaryProvider(sidecar: sidecar1, resolver: _resolver());
        foldResult =
            await p1.summarize(folded: [_msg('user', '读一下配置')], config: _config());

        final sidecar2 = FakeSidecar()
          ..queueChunk('摘要二：把两条一级摘要合成一条。')
          ..queueDone(inputTokens: 421, outputTokens: 99);
        final p2 = ModelSummaryProvider(sidecar: sidecar2, resolver: _resolver());
        rollUpResult =
            await p2.summarizeText(text: '一级摘要一\n\n一级摘要二', config: _config());
      } finally {
        debugPrint = original;
      }

      final inLines = logs.where((l) => l.contains('[OBS] summary in=421')).toList();
      debugPrint('[OBS] captured summary observation lines: $inLines');
      debugPrint('[OBS] fold inputTokens=${foldResult.inputTokens} '
          'outputTokens=${foldResult.tokens}');
      debugPrint('[OBS] roll-up inputTokens=${rollUpResult.inputTokens} '
          'outputTokens=${rollUpResult.tokens}');

      expect(foldResult.inputTokens, 421,
          reason: '一级折叠那次调用的实测输入 token 必须带出来');
      expect(rollUpResult.inputTokens, 421,
          reason: '二级合一那次调用的实测输入 token 也必须带出来；只接一个方法就会漏');
      expect(foldResult.tokens, 99,
          reason: '决定摘要是否合格的仍然是实测输出大小，不是输入');
      expect(inLines.length, 2,
          reason: '两次摘要调用各打一行 —— 只打一行说明有一个方法没接住');
    });
  });

  group('ModelSummaryProvider — 参考上下文与待压缩原文分开（本变更新增）', () {
    // 本变更的判据第二条：参考与原文必须是两条不同的消息、各带抬头；有参考时
    // system 保留今天那两句再加禁令；没有参考时 system 与消息形状与过去逐字相同。
    test('有参考时：分属两条消息、参考正文不许混进待压缩原文、system 是"原文 + 禁令"',
        () async {
      final sidecar = FakeSidecar()
        ..queueChunk('摘要')
        ..queueDone(inputTokens: 10, outputTokens: 5);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());
      final r = await provider.summarize(
        folded: [_msg('user', '这一段的正文')],
        config: _config(),
        reference: const [
          SummaryReference(
              level: 1, coveredMinSeq: 1, coveredMaxSeq: 4, text: '更早那一段的摘要正文'),
        ],
      );

      final sent = jsonDecode(sidecar.lastMessagesJson!) as List;
      final contents =
          sent.map((m) => (m as Map<String, dynamic>)['content'] as String).toList();
      final refIdx = contents.indexWhere((c) => c.contains(kReferenceContextHeader));
      final textIdx = contents.indexWhere((c) => c.contains(kSummarizeTextHeader));
      debugPrint('[OBS] 有参考时的消息条数=${sent.length} 参考下标=$refIdx 原文下标=$textIdx');
      debugPrint('[OBS] system=${sidecar.lastSystemPrompt}');

      expect(refIdx, isNot(-1), reason: '参考那条消息必须带自己的抬头');
      expect(textIdx, isNot(-1), reason: '待压缩原文那条消息必须带自己的抬头');
      expect(refIdx, isNot(textIdx), reason: '参考与待压缩原文必须是两条不同的消息');
      expect(refIdx, lessThan(textIdx), reason: '参考在前、原文在后');
      expect(contents[refIdx], contains('更早那一段的摘要正文'));
      expect(contents[refIdx], contains('第 1..4 段摘要'),
          reason: '参考要带上它覆盖的序号范围，模型才能判断这段参考是不是在本批之前');
      expect(contents[textIdx], isNot(contains('更早那一段的摘要正文')),
          reason: '参考正文绝不能混进待压缩原文那条消息里');
      expect(contents[textIdx], contains('这一段的正文'));
      expect(contents.last, kSummarizeInstruction, reason: '输出要求仍然殿后');

      expect(sidecar.lastSystemPrompt, contains('请忠实、精简地用纯文本总结此前的对话'),
          reason: '有参考时也要保留今天那句"忠实、精简"');
      expect(sidecar.lastSystemPrompt, contains('请用与对话正文相同的语言输出摘要'),
          reason: '有参考时也要保留语言要求');
      expect(sidecar.lastSystemPrompt, contains(kReferenceOnlyProhibition),
          reason: '有参考时 system 要追加禁令句（只用来解析指代，禁止写进摘要）');
      expect(r.inputTokens, 10);
    });

    test('没有参考时：system 与消息形状与过去逐字相同', () async {
      final sidecar = FakeSidecar()
        ..queueChunk('摘要')
        ..queueDone(inputTokens: 10, outputTokens: 5);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());
      await provider.summarize(
          folded: [_msg('user', '正文一'), _msg('assistant', '正文二')], config: _config());

      debugPrint('[OBS] 无参考时的 system=${sidecar.lastSystemPrompt}');
      expect(sidecar.lastSystemPrompt, kSummarySystemPrompt,
          reason: '没有参考时 system 必须与过去逐字相同（不许带禁令句）');

      final sent = jsonDecode(sidecar.lastMessagesJson!) as List;
      debugPrint('[OBS] 无参考时的消息条数=${sent.length}');
      expect(sent.length, 3, reason: '过去就是"每条折叠消息一条 + 末尾指令一条"');
      expect((sent[0] as Map<String, dynamic>)['content'], 'USER: 正文一');
      expect((sent[1] as Map<String, dynamic>)['content'], 'ASSISTANT: 正文二');
      expect((sent[2] as Map<String, dynamic>)['content'], kSummarizeInstruction);
      expect(sidecar.lastMessagesJson, isNot(contains(kSummarizeTextHeader)),
          reason: '没有参考时不许出现任何抬头');
      expect(sidecar.lastMessagesJson, isNot(contains(kReferenceContextHeader)));
    });
  });

  group('ModelSummaryProvider — 摘要正文不许以角色标签开头（本变更新增）', () {
    // 2026-10-03 人工看质量时实测：5 条一级摘要里 3 条正文以 `ASSISTANT` / `ASSISTANT:`
    // 开头（模型把渲染用的 `ROLE: 正文` 前缀抄进了摘要）。修法是在 provider 出口削掉这
    // 一种形态，请求体一个字不改。
    test('标签 + 冒号 / 标签紧跟中文：三种实测形态都要削掉', () async {
      for (final pair in const [
        ['ASSISTANT用户是一名开发协作代理，目标是…', '用户是一名开发协作代理，目标是…'],
        ['ASSISTANT: 用户目标：对项目做重构', '用户目标：对项目做重构'],
        ['ASSISTANT:本次对话为重复循环的第240–320轮', '本次对话为重复循环的第240–320轮'],
      ]) {
        final sidecar = FakeSidecar()
          ..queueChunk(pair[0])
          ..queueDone(inputTokens: 10, outputTokens: 5);
        final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());
        final r = await provider.summarize(
            folded: [_msg('user', '正文')], config: _config());
        debugPrint('[OBS] 角色标签：输入="${pair[0]}" 输出="${r.text}"');
        expect(r.text, pair[1], reason: '开头的角色标签必须削掉');
      }
    });

    test('二级合一那条路径同样削（两个方法都要覆盖）', () async {
      final sidecar = FakeSidecar()
        ..queueChunk('ASSISTANT: 合成结果')
        ..queueDone(inputTokens: 10, outputTokens: 5);
      final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());
      final r = await provider.summarizeText(text: '两条一级摘要', config: _config());
      expect(r.text, '合成结果');
    });

    test('不许误伤：英文正文开头的 ASSISTANT、以及正文中间的标签都要原样保留', () async {
      for (final keep in const [
        'ASSISTANT worked on the config module and kept email untouched.',
        '这段摘要在正文里提到 ASSISTANT: 这个词，但它不在开头。',
      ]) {
        final sidecar = FakeSidecar()
          ..queueChunk(keep)
          ..queueDone(inputTokens: 10, outputTokens: 5);
        final provider = ModelSummaryProvider(sidecar: sidecar, resolver: _resolver());
        final r = await provider.summarize(
            folded: [_msg('user', '正文')], config: _config());
        debugPrint('[OBS] 必须原样保留："$keep" → "${r.text}"');
        expect(r.text, keep, reason: '只削开头那一种形态，别误伤正常措辞');
      }
    });
  });
}
