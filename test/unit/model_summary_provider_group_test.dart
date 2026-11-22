// 摘要请求的归属纪律（change `agent-group-chat` 任务 4.7）。
//
// 打**输入通道**：摘要请求实际发出的系统文本与被折叠文本。
//   - 系统文本追加 `kGroupSummaryPromptSuffix`（只有归属纪律）；
//   - 被折叠文本里他人的话仍是「甲 说：」（归属不被改写）。
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/group_prompts.dart';
import 'package:alias_agent/services/group_view_projection.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../integration/helpers/fake_sidecar.dart';
import 'group_view_fixtures.dart';

void main() {
  test('系统文本含归属纪律、被折叠文本保留「甲 说：」', () async {
    final sidecar = FakeSidecar();
    sidecar.queueChunk('甲说改完了 lib/a.dart；乙随后确认。');
    sidecar.queueDone(inputTokens: 12, outputTokens: 8);

    final config = AppConfig(
      version: 1,
      providers: {
        'test-provider': const ProviderConfig(
            apiKey: 'k', baseUrl: 'http://127.0.0.1:9'),
      },
      agentTypes: const {},
    );
    final provider = ModelSummaryProvider(
      sidecar: sidecar,
      resolver: ProviderResolver(config),
    );
    const template = AgentTypeConfig(
      name: 'general',
      provider: 'test-provider',
      model: 'test-model',
      systemPrompt: '',
      maxContextTokens: 200000,
    );

    // 乙的视图：甲、乙的公开回复都以「X 说：」出现在 user 轮。
    final view = GroupViewProjection.project(
      raw: [
        publicRow(2, 'member-a', '已改完 lib/a.dart'),
        publicRow(3, 'member-b', '收到，我读 lib/b.dart'),
      ],
      memberId: 'member-b',
      displayNames: kNames,
    );

    await provider.summarize(
      folded: view.messages,
      config: template,
      systemPromptSuffix: kGroupSummaryPromptSuffix,
      sessionId: 'group-1',
    );

    final systemPrompt = sidecar.lastSystemPrompt ?? '';
    final messagesJson = sidecar.lastMessagesJson ?? '';
    // ignore: avoid_print
    print('[OBS] 摘要系统文本=$systemPrompt');
    // ignore: avoid_print
    print('[OBS] 摘要请求 messages=$messagesJson');

    expect(systemPrompt, contains(kGroupSummaryPromptSuffix),
        reason: '摘要系统文本必须追加归属纪律');
    expect(systemPrompt, contains('忠实、精简'),
        reason: '既有两句必须留着（追加，不替换）');
    expect(systemPrompt, isNot(contains('自包含')));

    // 被折叠文本：甲的话仍是「甲 说：」（视图里的合成 user 行原样进入请求）。
    expect(messagesJson, contains('甲 说：已改完 lib/a.dart'),
        reason: '他人的话在摘要输入里仍保留归属');
    // 乙自己的话在乙的视图里是第一人称（ASSISTANT 行）。
    expect(messagesJson, contains('ASSISTANT: 收到，我读 lib/b.dart'));
  });
}
