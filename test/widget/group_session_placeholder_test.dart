// Flutter 侧的组会话占位（change `agent-group-chat` 任务 7.6 / design D16）。
//
// 组视图本期只做 web：会话列表仍显示组会话，但点开只显示「请在 web 组视图打开」
// 占位，**不**进入单 Agent 对话界面、**不**加载整份原文当聊天历史。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/session.dart';

import '../integration/helpers/fake_sidecar.dart';
import 'helpers/fakes.dart';

const _testConfig = AppConfig(version: 1);

/// 记录消息读取次数：组会话被打开时必须是 0（不许把整份原文当聊天历史）。
class _CountingMessageRepository extends FakeMessageRepository {
  _CountingMessageRepository(super.messages);

  final List<String> queriedSessions = [];

  @override
  Future<List<Message>> queryBySession(String sessionId) async {
    queriedSessions.add(sessionId);
    return super.queryBySession(sessionId);
  }
}

Session _groupSession(String id) => Session(
      id: id,
      title: '测试组',
      kind: Session.kindGroup,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

Session _singleSession(String id) => Session(
      id: id,
      title: '单会话',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

void main() {
  tearDown(() {
    registry.clear();
    resolver = null;
  });

  testWidgets('打开组会话显示「请在 web 组视图打开」占位，且不加载消息', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;

    // 组会话排在第一位 ⇒ 启动后自动被选中（正是"打开组会话"那条路径）。
    final sessions = [_groupSession('g1'), _singleSession('s1')];
    final msgRepo = _CountingMessageRepository([
      // 即便库里真有原文，也不该为组会话加载它。
      Message(
        id: 'm1',
        seq: 1,
        sessionId: 'g1',
        role: 'user',
        content: '组里的历史原文',
        createdAt: 1,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatScreen(
          config: _testConfig,
          sessionRepo: FakeSessionRepository(sessions),
          msgRepo: msgRepo,
          sidecar: FakeSidecar(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ignore: avoid_print
    print('[OBS] 已查询过消息的会话=${msgRepo.queriedSessions}');
    // ignore: avoid_print
    print('[OBS] 占位文案在树上=${find.text('请在 web 组视图打开').evaluate().isNotEmpty}');

    expect(find.text('请在 web 组视图打开'), findsOneWidget,
        reason: '组会话打开只显示占位');
    expect(msgRepo.queriedSessions, isNot(contains('g1')),
        reason: '不得为组会话加载整份原文当聊天历史');
    // 会话列表里仍然显示组会话（可见但不可用单 Agent 界面）。
    expect(find.text('测试组'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
