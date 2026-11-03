import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/models/summary_node.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_session_controller.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/session_repository.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
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
  Future<Session> create({String? title, String? agentType, String? parentSessionId}) async {
    final s = Session(
      id: 'new-${sessions.length}',
      title: title ?? 'New Chat',
      agentType: agentType ?? 'general',
      parentSessionId: parentSessionId,
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
  Future<List<Session>> listChildren(String parentSessionId) async =>
      sessions.where((s) => s.parentSessionId == parentSessionId).toList();

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

  @override
  Future<Session> updateAgentType(String id, String agentType) async {
    final i = sessions.indexWhere((s) => s.id == id);
    if (i < 0) {
      throw SessionAgentTypeUpdateException(
        sessionId: id,
        agentType: agentType,
        updatedRows: 0,
        message: '会话 "$id" 不存在：没有更新到唯一既有行。',
      );
    }
    sessions[i] = sessions[i].copyWith(agentType: agentType);
    ledger.record('session-update-agent-type');
    return sessions[i];
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

/// 5.2 用：把活动子运行的 cancel / dispose 也写进同一本事件台账。
class _SubagentDeleteSidecar extends FakeSidecar {
  _SubagentDeleteSidecar(this.ledger);

  final _Ledger ledger;

  /// 非空时，子句柄（非 s1 / s2）的 sendMessage 等它完成后才回放事件。
  Completer<void>? childGate;
  final List<String> cancelled = [];
  final List<String> disposed = [];

  @override
  Future<void> sendMessage({
    required String handle,
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required String thinkingMode,
    required String thinkingEffort,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  }) async {
    final gate = childGate;
    if (handle != 's1' && handle != 's2' && gate != null) {
      await gate.future;
    }
    return super.sendMessage(
      handle: handle,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      systemPrompt: systemPrompt,
      messagesJson: messagesJson,
      toolsJson: toolsJson,
      thinkingMode: thinkingMode,
      thinkingEffort: thinkingEffort,
      onChunk: onChunk,
      onToolCall: onToolCall,
      onThinking: onThinking,
      onDone: onDone,
    );
  }

  @override
  void cancelRequest(String handle) {
    cancelled.add(handle);
    super.cancelRequest(handle);
  }

  @override
  Future<void> disposeContext(String sessionId) async {
    disposed.add(sessionId);
    ledger.record('dispose-$sessionId');
    return super.disposeContext(sessionId);
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
  required FakeSidecar sidecar,
  required _RecordingSessionRepo sessionRepo,
  required _RecordingMessageRepo msgRepo,
  required List<Session> sessions,
  bool backgroundFoldEnabled = false,
  SummaryNodeRepository? summaryNodeRepo,
  AgentRegistry? agents,
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
        agentRegistry: agents,
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
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

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

  test('切换进行中删除：等切换结束并重读 Session；删除中切换被拒绝', () async {
    final ledger = _Ledger();
    final sessions = [_session('s1')];
    final msgRepo = _RecordingMessageRepo(ledger);
    final sessionRepo = _RecordingSessionRepo(ledger, sessions);
    final sidecar = _GatedSidecar();
    final agents = AgentRegistry();
    registry.register(const AgentTypeConfig(
      name: 'reviewer',
      provider: 'test',
      model: 'reviewer-model',
      systemPrompt: 'REVIEWER',
      maxContextTokens: 50000,
    ));
    final factory = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
    );
    await factory.create(sessions.first);

    final gate = Completer<void>();
    final started = Completer<void>();
    final controller = AgentSessionController(
      factory: factory,
      sessionRepo: sessionRepo,
      retireAgent: (agent) async {
        started.complete();
        await gate.future;
        await agent.retire();
      },
    );

    final switchFuture = controller.switchTemplate(sessions.first, 'reviewer',
        callbacks: const AgentCallbacks());
    await started.future;

    Session? reread;
    var deleteReturned = false;
    final deleteFuture = controller.beginDelete('s1').then((s) {
      reread = s;
      deleteReturned = true;
    });
    await Future<void>.delayed(Duration.zero);
    // ignore: avoid_print
    print('  [OBS] 切换进行中删除：deleteReturned=$deleteReturned '
        '台账=${ledger.events}');
    expect(deleteReturned, isFalse, reason: '切换还没结束，删除不得先返回');
    expect(ledger.events, isNot(contains('session-delete')));

    // 删除登记之后，同一会话的切换一律被拒。
    var deletingError = '';
    try {
      await controller.switchTemplate(sessions.first, 'general',
          callbacks: const AgentCallbacks());
      fail('删除进行中切换必须被拒绝');
    } on AgentSwitchException catch (e) {
      deletingError = e.toString();
      expect(e.stage, AgentSwitchStage.deleting);
    }
    // ignore: avoid_print
    print('  [OBS] 删除中切换报错：$deletingError');
    expect(deletingError, contains('删除'));

    gate.complete();
    await switchFuture;
    await deleteFuture;
    // ignore: avoid_print
    print('  [OBS] 删除前重读：agentType=${reread?.agentType} '
        '台账=${ledger.events}');
    expect(reread, isNotNull);
    expect(reread!.agentType, 'reviewer', reason: '删除必须重读到切换后的值');
    expect(ledger.events, contains('session-update-agent-type'));

    await sessionRepo.delete('s1');
    expect(ledger.events.last, 'session-delete');
    expect(ledger.events.indexOf('session-update-agent-type'),
        lessThan(ledger.events.indexOf('session-delete')),
        reason: '删库晚于切换的持久化');
    controller.endDelete('s1');
    expect(controller.isDeleting('s1'), isFalse);
  });

  // ---------------------------------------------------------------------------
  // 5.2 删除父会话：活动子运行先被取消并清理，父子上下文都在删库前销毁；
  // 另一个无父子关系的会话不受影响。
  // ---------------------------------------------------------------------------
  testWidgets('删除父会话：先取消并清理活动子运行，再删库；另一个会话不受影响',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final ledger = _Ledger();
    final sessions = [_session('s1'), _session('s2')];
    final msgRepo = _RecordingMessageRepo(ledger);
    final sessionRepo = _RecordingSessionRepo(ledger, sessions);
    final sidecar = _SubagentDeleteSidecar(ledger);
    sidecar.childGate = Completer<void>();
    final agents = AgentRegistry();

    await tester.pumpWidget(_buildApp(
        sidecar: sidecar,
        sessionRepo: sessionRepo,
        msgRepo: msgRepo,
        sessions: sessions,
        agents: agents));
    await tester.pumpAndSettle();
    final s2Before = agents.lookup('s2');
    expect(s2Before, isNotNull, reason: '启动时两个顶层会话都应有实例');

    // 父这一轮调用 spawn_subagent；子 Agent 被闸门卡在 sendMessage 里。
    sidecar.queueToolCall('{"type":"tool_use","id":"spawn-1",'
        '"name":"spawn_subagent","input":{"task":"子任务-删除用例",'
        '"agent_type":"general"}}');
    sidecar.queueDone();
    sidecar.queueChunk('子文本');
    sidecar.queueDone();

    await tester.enterText(find.byType(TextField), '触发子运行');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    for (var i = 0;
        i < 100 &&
            !sessionRepo.sessions.any((s) => s.parentSessionId == 's1');
        i++) {
      await tester.pump();
    }
    final childId = sessionRepo.sessions
        .firstWhere((s) => s.parentSessionId == 's1')
        .id;

    // 侧栏有两个会话，各有自己的删除按钮：点 s1 那一行里的那个。
    final s1Delete = find.descendant(
      of: find.ancestor(
          of: find.text('Session s1'), matching: find.byType(ListTile)),
      matching: find.byTooltip('Delete session'),
    );
    await tester.tap(s1Delete);
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    // ignore: avoid_print
    print('[OBS] 删除等待中：childId=$childId ledger=${ledger.events} '
        'cancelled=${sidecar.cancelled} disposed=${sidecar.disposed}');
    expect(ledger.hasDelete, isFalse,
        reason: '子运行还在飞（闸门没开），删库不得提前发生');
    expect(sidecar.cancelled, contains(childId),
        reason: '删除父会话必须先取消活动子 Agent');
    expect(sidecar.disposed, isNot(contains(childId)),
        reason: '子整轮没结束前不得提前销毁子上下文');

    sidecar.childGate!.complete();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // ignore: avoid_print
    print('[OBS] 删除完成：ledger=${ledger.events} '
        'cancelled=${sidecar.cancelled} disposed=${sidecar.disposed} '
        'sendHandles=${sidecar.sendHandles}');
    expect(ledger.hasDelete, isTrue);
    expect(ledger.events.last, 'session-delete',
        reason: '删库必须是最后一步，之后不许再有写库');
    expect(sidecar.disposed, contains(childId));
    expect(sidecar.disposed, contains('s1'));
    expect(ledger.indexOf('dispose-$childId'),
        lessThan(ledger.indexOf('session-delete')),
        reason: '子上下文必须在删库前销毁');
    expect(ledger.indexOf('dispose-s1'), lessThan(ledger.indexOf('session-delete')),
        reason: '父上下文必须在删库前销毁');

    // 另一个无父子关系的会话：实例、请求、消息与上下文都不动。
    expect(identical(agents.lookup('s2'), s2Before), isTrue,
        reason: '另一个会话的实例不得被替换');
    expect(sidecar.sendHandles.where((h) => h == 's2'), isEmpty,
        reason: '另一个会话没有发起模型请求');
    expect(msgRepo.messages.where((m) => m.sessionId == 's2'), isEmpty,
        reason: '另一个会话没有写任何消息');
    expect(sidecar.cancelled.where((h) => h == 's2'), isEmpty,
        reason: '另一个会话没有被取消');
    expect(sidecar.disposed, isNot(contains('s2')),
        reason: '另一个会话的上下文没有被销毁');
  });

  // ---------------------------------------------------------------------------
  // 2.2 真实 SQLite：父会话删除必须级联删除子运行记录、消息与摘要。
  // 这里不用替身仓库，也不只看建表语句里的 REFERENCES —— 直接数行。
  // ---------------------------------------------------------------------------
  test('真实 SQLite：删父会话级联删除子记录、消息与摘要，其它会话不受影响', () async {
    final tempDir = Directory.systemTemp.createTempSync('delete_cascade_');
    try {
      await DatabaseService.openAt(tempDir.path);
      final db = await DatabaseService.database;
      final fk = await db.rawQuery('PRAGMA foreign_keys');
      // ignore: avoid_print
      print('  [OBS] PRAGMA foreign_keys => ${fk.first.values.first}');
      expect(fk.first.values.first, 1,
          reason: '真实连接必须打开外键，否则 ON DELETE CASCADE 不会发生');

      final sessionRepo = SessionRepository();
      final messageRepo = MessageRepository();
      final summaryRepo = SummaryNodeRepository();

      final parent = await sessionRepo.create(title: '父会话');
      final child =
          await sessionRepo.create(title: '子运行', parentSessionId: parent.id);
      final other = await sessionRepo.create(title: '另一个顶层会话');
      final otherChild = await sessionRepo.create(
          title: '另一个子运行', parentSessionId: other.id);

      await messageRepo.insert(
          sessionId: parent.id, role: 'user', content: '父消息');
      await messageRepo.insert(
          sessionId: child.id, role: 'assistant', content: '子消息');
      await messageRepo.insert(
          sessionId: other.id, role: 'user', content: '别人的消息');
      await messageRepo.insert(
          sessionId: otherChild.id, role: 'assistant', content: '别人的子消息');

      await summaryRepo.insert(SummaryNode(
        id: 0,
        sessionId: child.id,
        level: 1,
        startSeq: 1,
        endSeq: 1,
        nodeType: 'leaf',
        summaryJson: '{"summary":"子摘要"}',
        coveredMinSeq: 1,
        coveredMaxSeq: 1,
      ));
      await summaryRepo.insert(SummaryNode(
        id: 0,
        sessionId: otherChild.id,
        level: 1,
        startSeq: 1,
        endSeq: 1,
        nodeType: 'leaf',
        summaryJson: '{"summary":"别人的摘要"}',
        coveredMinSeq: 1,
        coveredMaxSeq: 1,
      ));

      Future<int> count(String table,
          {String? where, List<Object?>? whereArgs}) async {
        final rows = await db.query(table, where: where, whereArgs: whereArgs);
        return rows.length;
      }

      // 删除前：4 个会话、4 条消息、2 条摘要，列表只露两个顶层会话。
      expect(await count('sessions'), 4);
      expect(await count('messages'), 4);
      expect(await count('summary_nodes'), 2);
      final beforeList = await sessionRepo.list();
      expect(beforeList.map((s) => s.id).toSet(), {parent.id, other.id});

      await sessionRepo.delete(parent.id);

      // 直接数行：父、子及其消息、摘要都真的没了（不能只断言外键文本）。
      final afterSessions = await count('sessions');
      final afterMessages = await count('messages');
      final afterSummaries = await count('summary_nodes');
      // ignore: avoid_print
      print('  [OBS] 删除父会话后行数 sessions=$afterSessions '
          'messages=$afterMessages summary_nodes=$afterSummaries');
      expect(afterSessions, 2, reason: '父与子会话记录必须都删除（级联）');
      expect(afterMessages, 2, reason: '父与子的消息必须都删除（级联）');
      expect(afterSummaries, 1, reason: '子的摘要必须随父删除（级联）');

      // 另一个会话及其子记录、消息、摘要原样保留。
      expect(
          await count('sessions',
              where: 'id IN (?, ?)', whereArgs: [other.id, otherChild.id]),
          2);
      expect(
          await count('messages',
              where: 'session_id IN (?, ?)',
              whereArgs: [other.id, otherChild.id]),
          2);
      expect(
          await count('summary_nodes',
              where: 'session_id = ?', whereArgs: [otherChild.id]),
          1);
      final afterList = await sessionRepo.list();
      expect(afterList.map((s) => s.id).toList(), [other.id],
          reason: '普通列表仍只剩别人的顶层会话');
      expect(await sessionRepo.listChildren(parent.id), isEmpty,
          reason: '父会话的子记录必须已随父删除');
      expect((await sessionRepo.listChildren(other.id)).single.id, otherChild.id,
          reason: '别人的子记录必须仍在');
    } finally {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });
}
