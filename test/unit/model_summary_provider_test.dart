import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
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
}
