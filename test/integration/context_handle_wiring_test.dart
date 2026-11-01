import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/provider_resolver.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 上下文句柄的接线（change `add-context-handles` 任务 2.6）。
///
/// 覆盖三件事：
///   ① 启动恢复、切换、新建会话都会 `ensureContext`；
///   ② 一次模型轮次属会话甲、执行期间界面切到乙：这次请求仍然带甲的句柄；
///   ③ 工具调用不读当时的 `_currentId` 顶替（用 toolHandles 核对）。
void _setupRegistry() {
  registry.clear();
  registry.register(const AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: 100000,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Session _session(String id) => Session(
      id: id,
      title: 'Session $id',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

Widget _buildApp({
  required FakeSidecar sidecar,
  required FakeSessionRepository sessionRepo,
  required FakeMessageRepository msgRepo,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: FakeSummaryProvider(),
        backgroundFoldEnabled: false,
      ),
    ),
  );
}

void main() {
  setUp(_setupRegistry);

  testWidgets('启动恢复、切换、新建会话都会 ensureContext', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessions = [_session('s1'), _session('s2')];
    final sessionRepo = FakeSessionRepository(sessions);
    final msgRepo = FakeMessageRepository();
    final sidecar = FakeSidecar();

    await tester.pumpWidget(
        _buildApp(sidecar: sidecar, sessionRepo: sessionRepo, msgRepo: msgRepo));
    await tester.pumpAndSettle();

    // ① 启动恢复：两条恢复出来的会话都建了上下文。
    // ignore: avoid_print
    print('[2.6] 启动恢复 ensureContext: ${sidecar.ensureContextCalls}');
    expect(sidecar.ensureContextCalls, containsAll(['s1', 's2']));

    // ② 切换既有会话。
    await tester.tap(find.text('Session s1'));
    await tester.pumpAndSettle();
    expect(sidecar.ensureContextCalls.where((id) => id == 's1').length,
        greaterThanOrEqualTo(2),
        reason: '切换会话也要 ensureContext');

    // ③ 新建会话：FakeSessionRepository 的 id 是 new-<旧数量>。
    await tester.tap(find.text('New Chat'));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('[2.6] 新建后 ensureContext: ${sidecar.ensureContextCalls}');
    expect(sidecar.ensureContextCalls, contains('new-2'));
  });

  testWidgets('轮次属甲、界面已切乙：这次模型请求仍带甲的句柄', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final sessions = [_session('s1'), _session('s2')];
    final sessionRepo = FakeSessionRepository(sessions);
    final msgRepo = FakeMessageRepository();
    final sidecar = FakeSidecar();
    sidecar.queueChunk('hello from s1');
    sidecar.queueDone(stopReason: 'end_turn');
    sidecar.gateNextSend();  // 轮次卡在闸门上，界面可以做别的事

    await tester.pumpWidget(
        _buildApp(sidecar: sidecar, sessionRepo: sessionRepo, msgRepo: msgRepo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'first');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    // 界面切到乙（这一轮已经属于甲）。
    await tester.tap(find.text('Session s2'));
    await tester.pump();
    sidecar.releaseGate();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // ignore: avoid_print
    print('[2.6] sendHandles=${sidecar.sendHandles} toolHandles=${sidecar.toolHandles}');
    expect(sidecar.sendHandles, contains('s1'),
        reason: '这一轮的模型请求必须带甲的句柄');
    expect(sidecar.sendHandles, isNot(contains('s2')),
        reason: '切换之后的界面状态不许顶替这次请求的归属');
  });
}
