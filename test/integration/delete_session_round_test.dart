import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/models/summary_node.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/summary_node_repository.dart';

import 'helpers/fake_sidecar.dart';

/// 删除会话必须等**整轮**结束才删数据库（change `add-context-handles` 任务 2.9）。
///
/// 事件台账记录每一次写库与删除的先后，断言：
///   - 流式请求还在飞时，删除不会提前发生；
///   - `disposeContext` 早于数据库删除；
///   - 删除之后没有任何写入到达。
///
/// 桥的 `_chain` 只包 `sendMessage` 那一段，等它不够 —— 所以这里盯的是外层
/// `insert` / `touch` / `updateToolCalls` 与 `disposeContext` 的相对顺序。

/// 所有仓库共用一本事件台账。
class _Ledger {
  final List<String> events = [];
  void record(String event) => events.add(event);
  int indexOf(String event) => events.indexOf(event);
  bool get hasDelete => events.contains('session-delete');
}

class _RecordingSessionRepo implements SessionRepository {
  _RecordingSessionRepo(this.ledger, this.sessions);

  final _Ledger ledger;
  final List<Session> sessions;

  @override
  Future<Session> create({String? title, String? agentType}) async {
    final s = Session(
      id: 'new-${sessions.length}',
      title: title ?? 'New Chat',
      agentType: agentType ?? 'general',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    sessions.insert(0, s);
    return s;
  }

  @override
  Future<Session?> get(String id) async {
    try {
      return sessions.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<Session>> list() async => sessions.toList();

  @override
  Future<void> delete(String id) async {
    sessions.removeWhere((s) => s.id == id);
    ledger.record('session-delete');
  }

  @override
  Future<void> updateTitle(String id, String title) async {}

  @override
  Future<bool> updateTitleIfDefault(String id, String text) async => false;

  @override
  Future<void> touch(String id) async {
    ledger.record('session-touch');
  }
}

class _RecordingMessageRepo implements MessageRepository {
  _RecordingMessageRepo(this.ledger);

  final _Ledger ledger;
  final List<Message> messages = [];

  @override
  Future<Message> insert({
    required String sessionId,
    required String role,
    required String content,
    String? toolCallsJson,
    String? thinkingJson,
    int? tokenCount,
    int? outputTokenCount,
    List<String> attachments = const [],
  }) async {
    final msg = Message(
      id: 'msg-${messages.length}',
      // 真实仓库由数据库 rowid 给 seq；这里按插入顺序给一个稳定的单调序号，
      // 后台压缩的摘要区间（minSeq/maxSeq）才有非空值可落库。
      seq: messages.length + 1,
      sessionId: sessionId,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      thinkingJson: thinkingJson,
      tokenCount: tokenCount,
      outputTokenCount: outputTokenCount,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      attachments: attachments,
    );
    messages.add(msg);
    ledger.record('message-insert-$role');
    return msg;
  }

  /// 直接种一条历史（不记台账、不经过界面）：用来把历史撑过压缩阈值。
  void seed(String sessionId, int seq) {
    messages.add(Message(
      id: 'seed-$seq',
      seq: seq,
      sessionId: sessionId,
      role: seq.isEven ? 'user' : 'assistant',
      content: 'A' * 100,
      createdAt: seq,
    ));
  }

  @override
  Future<List<Message>> queryBySession(String sessionId) async =>
      messages.where((m) => m.sessionId == sessionId).toList();

  @override
  Future<void> updateToolCalls(String id, String toolCallsJson) async {
    ledger.record('message-update-tool-calls');
  }
}

/// FakeSidecar + 可选闸门：让 `run_command` 停在 Future 上（模拟长命令）。
class _GatedSidecar extends FakeSidecar {
  Completer<void>? runGate;
  bool runStarted = false;

  @override
  Future<String> runCommand(String handle, String requestJson) async {
    runStarted = true;
    final gate = runGate;
    if (gate != null) await gate.future;
    return super.runCommand(handle, requestJson);
  }
}

/// 摘要树仓库替身：`materialize` 可以停在 Completer 上（模拟后台压缩正在写库），
/// 每次写库都记进同一本事件台账，用来核对「删库」与「最后一次写库」的先后。
class _RecordingSummaryRepo implements SummaryNodeRepository {
  _RecordingSummaryRepo(this.ledger);

  final _Ledger ledger;
  final List<SummaryNode> nodes = [];
  int _nextId = 1;
  Completer<void>? materializeGate;
  bool materializeStarted = false;

  @override
  Future<SummaryNode> insert(SummaryNode node) async {
    final stored = _copy(node, id: _nextId++);
    nodes.add(stored);
    return stored;
  }

  @override
  Future<SummaryNode> materialize({
    required String sessionId,
    required int level,
    required int startSeq,
    required int endSeq,
    required String nodeType,
    int? parentId,
    String? summaryJson,
    int? tokenCost,
    int? summaryPromptVersion,
    String? model,
    required int coveredMinSeq,
    required int coveredMaxSeq,
  }) async {
    materializeStarted = true;
    ledger.record('summary-materialize-start');
    final gate = materializeGate;
    if (gate != null) await gate.future;
    ledger.record('summary-materialize-end');
    final stored = SummaryNode(
      id: _nextId++,
      sessionId: sessionId,
      level: level,
      startSeq: startSeq,
      endSeq: endSeq,
      nodeType: nodeType,
      parentId: parentId,
      summaryJson: summaryJson,
      tokenCost: tokenCost,
      summaryPromptVersion: summaryPromptVersion,
      model: model,
      coveredMinSeq: coveredMinSeq,
      coveredMaxSeq: coveredMaxSeq,
    );
    nodes.add(stored);
    return stored;
  }

  @override
  Future<List<SummaryNode>> queryBySession(String sessionId) async =>
      nodes.where((n) => n.sessionId == sessionId).toList();

  @override
  Future<SummaryNode?> findCovering(
      String sessionId, int startSeq, int endSeq, {int? level}) async {
    final hits = nodes
        .where((n) =>
            n.sessionId == sessionId &&
            n.coveredMinSeq == startSeq &&
            n.coveredMaxSeq == endSeq &&
            (level == null || n.level == level))
        .toList()
      ..sort((a, b) => b.level - a.level);
    return hits.isEmpty ? null : hits.first;
  }

  @override
  Future<int> treeVersion(String sessionId) async => 0;

  @override
  Future<void> bumpTreeVersion(String sessionId) async {}

  @override
  Future<int> dirtySinceSeq(String sessionId) async => 0;

  @override
  Future<void> markDirty(String sessionId, int seq) async {}

  @override
  Future<void> clearDirty(String sessionId) async {}

  static SummaryNode _copy(SummaryNode n, {required int id}) => SummaryNode(
        id: id,
        sessionId: n.sessionId,
        level: n.level,
        startSeq: n.startSeq,
        endSeq: n.endSeq,
        nodeType: n.nodeType,
        parentId: n.parentId,
        summaryJson: n.summaryJson,
        tokenCost: n.tokenCost,
        summaryPromptVersion: n.summaryPromptVersion,
        model: n.model,
        coveredMinSeq: n.coveredMinSeq,
        coveredMaxSeq: n.coveredMaxSeq,
      );
}

void _setupRegistry({int maxContextTokens = 100000}) {
  registry.clear();
  registry.register(AgentTypeConfig(
    name: 'general',
    provider: 'test',
    model: 'test-model',
    systemPrompt: '',
    maxContextTokens: maxContextTokens,
  ));
  resolver = ProviderResolver(const AppConfig(
    version: 1,
    providers: {
      'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
    },
  ));
}

Widget _buildApp({
  required _GatedSidecar sidecar,
  required _RecordingSessionRepo sessionRepo,
  required _RecordingMessageRepo msgRepo,
  required List<Session> sessions,
  bool backgroundFoldEnabled = false,
  SummaryNodeRepository? summaryNodeRepo,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatScreen(
        config: const AppConfig(version: 1),
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sidecar: sidecar,
        summaryProvider: FakeSummaryProvider(),
        summaryNodeRepo: summaryNodeRepo,
        backgroundFoldEnabled: backgroundFoldEnabled,
      ),
    ),
  );
}

Session _session(String id) => Session(
      id: id,
      title: 'Session $id',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );

void main() {
  setUp(_setupRegistry);

  testWidgets('流式请求在飞时删会话：等整轮结束后才删库，删除后没有写入', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ledger = _Ledger();
    final sessions = [_session('s1')];
    final msgRepo = _RecordingMessageRepo(ledger);
    final sessionRepo = _RecordingSessionRepo(ledger, sessions);
    final sidecar = _GatedSidecar();
    sidecar.queueChunk('streaming...');
    sidecar.queueDone(stopReason: 'end_turn');
    sidecar.gateNextSend();  // 请求停在闸门上（流还没结束）

    await tester.pumpWidget(_buildApp(
        sidecar: sidecar, sessionRepo: sessionRepo, msgRepo: msgRepo,
        sessions: sessions));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    // 用户消息已落库；请求卡在闸门 → 整轮未结束。
    expect(ledger.events, contains('message-insert-user'));
    expect(sidecar.disposeContextCalls, isEmpty);

    // 此时删除会话：必须等整轮结束，不能先删库。
    await tester.tap(find.byTooltip('Delete session'));
    await tester.pump();
    expect(ledger.hasDelete, isFalse,
        reason: '整轮还在飞（流未结束），数据库删除不得提前发生');
    expect(sessionRepo.sessions.length, 1);

    // 放行流：done 到达 → 整轮收尾 → disposeContext → 才允许删库。
    sidecar.releaseGate();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('[2.9] 事件顺序: ${ledger.events}');
    expect(ledger.hasDelete, isTrue);
    expect(ledger.events.last, 'session-delete',
        reason: '删除必须是最后一步，之后不许再有写入');
    expect(ledger.indexOf('message-insert-user'),
        lessThan(ledger.indexOf('session-delete')));
    expect(ledger.indexOf('message-insert-assistant'),
        lessThan(ledger.indexOf('session-delete')));
    expect(sidecar.disposeContextCalls, contains('s1'));
    // disposeContext 没有被提前调用（上面断言过），删除前已经调用：
    expect(sidecar.disposeContextCalls.length, 1);
    expect(sidecar.cancelHandles, contains('s1'),
        reason: '删除前必须取消该会话自己的模型请求');
    // 删除之后没有到达任何写入。
    final deleteAt = ledger.indexOf('session-delete');
    expect(
        ledger.events
            .skip(deleteAt + 1)
            .where((e) => e.startsWith('message-') || e.startsWith('session-')),
        isEmpty);
  });

  testWidgets('长命令在飞时删会话：等命令结束才删库', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ledger = _Ledger();
    final sessions = [_session('s1')];
    final msgRepo = _RecordingMessageRepo(ledger);
    final sessionRepo = _RecordingSessionRepo(ledger, sessions);
    final sidecar = _GatedSidecar();
    sidecar.stubRunCommand(
        '{"ok":true,"exit_code":0,"stdout":"done","stderr":"","timed_out":false,'
        '"duration_ms":1,"truncated":{"stdout":false,"stderr":false}}');
    sidecar.runGate = Completer<void>();
    sidecar.queueToolCall(
        '{"name":"run_command","input":{"command":"Start-Sleep -Seconds 2"}}');
    sidecar.queueDone(stopReason: 'tool_use');
    // 工具结果回来之后，模型还要再走一轮：给它一个 done。
    sidecar.queueDone(stopReason: 'end_turn');

    await tester.pumpWidget(_buildApp(
        sidecar: sidecar, sessionRepo: sessionRepo, msgRepo: msgRepo,
        sessions: sessions));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'run the long command');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(sidecar.runStarted, isTrue, reason: '长命令必须已经在飞');

    await tester.tap(find.byTooltip('Delete session'));
    await tester.pump();
    expect(ledger.hasDelete, isFalse,
        reason: '长命令还没结束，数据库删除不得提前发生');

    sidecar.runGate!.complete();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('[2.9] 长命令事件顺序: ${ledger.events}');
    expect(ledger.hasDelete, isTrue);
    expect(ledger.events.last, 'session-delete');
    expect(sidecar.disposeContextCalls, contains('s1'));
    final deleteAt = ledger.indexOf('session-delete');
    expect(
        ledger.events
            .skip(deleteAt + 1)
            .where((e) => e.startsWith('message-') || e.startsWith('session-')),
        isEmpty);
  });

  testWidgets('后台压缩写摘要库时删会话：等最后一次写库结束才删库', (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 小窗口 + 长历史 = 后台压缩一定会落一条一级摘要（写摘要库）。
    _setupRegistry(maxContextTokens: 2000);

    final ledger = _Ledger();
    final sessions = [_session('s1')];
    final msgRepo = _RecordingMessageRepo(ledger);
    final sessionRepo = _RecordingSessionRepo(ledger, sessions);
    final summaryRepo = _RecordingSummaryRepo(ledger);
    final sidecar = _GatedSidecar();
    sidecar..queueChunk('Reply')..queueDone();

    // 首轮之前只有 2 条历史：整轮在预算内，不会触发内联压缩。
    msgRepo.seed('s1', 1);
    msgRepo.seed('s1', 2);

    await tester.pumpWidget(_buildApp(
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sessions: sessions,
        backgroundFoldEnabled: true,
        summaryNodeRepo: summaryRepo));
    await tester.pumpAndSettle();

    // 跑完一轮：这一轮结束后会挂上 2 秒空闲计时器，到点开始后台压缩。
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 离线上长历史（不过界面）：让后台压缩这次真的超过阈值、要写摘要库。
    // 序号从 5 起：上面 2 条 seed 占 1、2，这一轮的用户/助手消息占 3、4。
    for (var seq = 5; seq <= 84; seq++) {
      msgRepo.seed('s1', seq);
    }
    summaryRepo.materializeGate = Completer<void>();

    // 触发空闲计时器，带后台压缩走到「正在写摘要库」并停住。
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 50 && !summaryRepo.materializeStarted; i++) {
      await tester.pump();
    }
    expect(summaryRepo.materializeStarted, isTrue,
        reason: '后台压缩必须先走到写摘要库，否则这条用例测不到"写库中删除"这个时点');

    // 此时删除会话：摘要库写入还没回来，删库必须等它。
    await tester.tap(find.byTooltip('Delete session'));
    await tester.pump();
    expect(ledger.hasDelete, isFalse,
        reason: '后台压缩还在写摘要库，数据库删除不得提前发生');
    expect(sidecar.disposeContextCalls, isEmpty,
        reason: '整轮（含后台压缩写库）未结束前不得调用 disposeContext');

    // 放行最后一次写库：整轮随即收尾 → disposeContext → 才允许删库。
    summaryRepo.materializeGate!.complete();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('[2.9] 后台压缩事件顺序: ${ledger.events}');
    expect(ledger.hasDelete, isTrue);
    expect(ledger.events.last, 'session-delete',
        reason: '删除必须是最后一步，之后不许再有写库');
    expect(ledger.indexOf('summary-materialize-end'),
        lessThan(ledger.indexOf('session-delete')),
        reason: '数据库删除必须晚于后台压缩最后一次写库结束');
    expect(sidecar.disposeContextCalls, contains('s1'));
    final deleteAt = ledger.indexOf('session-delete');
    expect(
        ledger.events
            .skip(deleteAt + 1)
            .where((e) => e.startsWith('message-') ||
                e.startsWith('session-') ||
                e.startsWith('summary-')),
        isEmpty);
  });
}
