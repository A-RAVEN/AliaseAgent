import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../integration/helpers/fake_sidecar.dart';

/// 摘要与分缝请求必须带**被压缩会话自己的句柄**（change `add-context-handles`，
/// 任务 2.8）。这里用 FakeSidecar 记录每次 sendMessage 的 handle，断言：
///   ① 后台摘要的句柄等于被压缩会话；
///   ② 两个会话交替压缩时各自用自己的句柄，不会都变成"最后一个"。
void main() {
  Message msg(String content) => Message(
        id: 'm${content.hashCode}',
        sessionId: 's',
        role: 'user',
        content: content,
        createdAt: content.length,
      );

  AgentTypeConfig config() => AgentTypeConfig(
        name: 'general',
        provider: 'test',
        model: 'test-model',
        systemPrompt: '',
        maxContextTokens: 100000,
      );

  ProviderResolver resolver() => ProviderResolver(const AppConfig(
        version: 1,
        providers: {
          'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
        },
      ));

  test('后台摘要带被压缩会话的句柄；会话交替时互不覆盖', () async {
    final sidecar = FakeSidecar();
    final provider = ModelSummaryProvider(sidecar: sidecar, resolver: resolver());

    sidecar
      ..queueChunk('会话甲的摘要')
      ..queueDone(outputTokens: 3);
    final s1 = await provider.summarize(
        folded: [msg('甲的内容')], config: config(), sessionId: 'session-a');
    debugPrint('[2.8] 第一次摘要 handle -> ${sidecar.sendHandles}');
    expect(s1.text, contains('甲'));

    sidecar
      ..queueChunk('会话乙的摘要')
      ..queueDone(outputTokens: 3);
    await provider.summarize(
        folded: [msg('乙的内容')], config: config(), sessionId: 'session-b');

    // 两轮摘要各带自己的句柄（不是"都用最后一个"）。
    expect(sidecar.sendHandles, ['session-a', 'session-b']);

    // 2-pass 摘要同样带句柄。
    sidecar
      ..queueChunk('二级摘要')
      ..queueDone(outputTokens: 2);
    await provider.summarizeText(
        text: '一级摘要的拼接', config: config(), sessionId: 'session-c');
    expect(sidecar.sendHandles, ['session-a', 'session-b', 'session-c']);
    expect(sidecar.lastSendHandle, 'session-c');
  });

  test('漏传句柄时不会退回"当前会话"（空句柄会由 C++ 报 unknown_context）',
      () async {
    final sidecar = FakeSidecar();
    final provider = ModelSummaryProvider(sidecar: sidecar, resolver: resolver());
    sidecar
      ..queueChunk('摘要')
      ..queueDone(outputTokens: 1);
    await provider.summarize(folded: [msg('内容')], config: config());
    // ignore: avoid_print
    debugPrint('[2.8] 未传 sessionId 时的 handle -> ${sidecar.sendHandles}');
    expect(sidecar.sendHandles, [''],
        reason: '没有句柄就传空串，绝不读全局 _currentId 冒充');
  });
}
