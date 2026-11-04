// 只读工具并行执行的端到端假 sidecar 用例（change
// `parallelize-readonly-tool-calls` 任务 5.1，覆盖 delta spec 的全部可自动化场景）。
//
// 用**真实的** Agent 工具循环 + 假 sidecar：FakeSidecar 现在记录每一次工具入口的
// 开始/结束时刻与所经入口（sync / worker / async），用例据此断言时间窗、交付顺序
// 与取消语义。所有毫秒延迟都是**测试构造值**（不是产品里的任何限制），只用来把
// "并发 vs 串行"的差别放大到可观测。
//
// 与 spec 场景的对应：
//   ① 连续三个只读调用重叠执行            → 01
//   ② 写类调用前后的只读不被提前          → 02
//   ③ 完成顺序与发出顺序相反时请求体不变形 → 03
//   ④ 组内一个成员失败不影响其它成员      → 04
//   ⑤ 单个只读调用维持现有执行路径        → 05
//   ⑥ 连续写类调用保持逐个执行            → 06
//   ⑦ 配置了并发上限时段按上限拆分        → 07
//   ⑧ 取消先于组启动                      → 08
//   ⑨ 取消发生在组执行途中                → 09
//   ⑩ 取消后重放历史带取消标记            → 10
//   ⑪ 子 Agent 轮内的连续只读同样并发      → 11
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/models/tool_call_activity.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/subagent_runner.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 按句柄记录每一次模型请求（FakeSidecar 只留最后一次）。
class _RecordingSidecar extends FakeSidecar {
  final List<({String handle, String messagesJson})> requests = [];

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
  }) {
    requests.add((handle: handle, messagesJson: messagesJson));
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
}

Map<String, dynamic> _def(String name) => {
      'name': name,
      'description': 'fake $name',
      'input_schema': {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
    };

/// 本轮发给模型的请求体里，最后一个 user 消息的 tool_result 块（按请求体顺序）。
List<Map<String, dynamic>> _lastToolResultBlocks(String messagesJson) {
  final messages = (jsonDecode(messagesJson) as List<dynamic>)
      .cast<Map<String, dynamic>>();
  for (var i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m['role'] != 'user') continue;
    final content = m['content'];
    if (content is! List) continue;
    final blocks = <Map<String, dynamic>>[];
    for (final b in content) {
      if (b is Map && b['type'] == 'tool_result') {
        blocks.add(Map<String, dynamic>.from(b));
      }
    }
    if (blocks.isNotEmpty) return blocks;
  }
  return const [];
}

/// tool_result 的 content 可能是一段字符串，也可能是块数组（带图片时）。
String _toolResultText(Map<String, dynamic> block) {
  final content = block['content'];
  if (content is String) return content;
  if (content is List) {
    final sb = StringBuffer();
    for (final part in content) {
      if (part is Map) {
        final text = part['text'];
        if (text is String) sb.write(text);
      }
    }
    return sb.toString();
  }
  return '';
}

/// 两个调用时间窗的重叠毫秒数（负数表示不重叠）。
int _overlapMs(FakeToolCall a, FakeToolCall b) {
  final start = a.startedAt.isAfter(b.startedAt) ? a.startedAt : b.startedAt;
  final end = a.endedAt!.isBefore(b.endedAt!) ? a.endedAt! : b.endedAt!;
  return end.difference(start).inMilliseconds;
}

DateTime _earliestStart(List<FakeToolCall> calls) =>
    calls.map((c) => c.startedAt).reduce((a, b) => a.isBefore(b) ? a : b);

DateTime _latestEnd(List<FakeToolCall> calls) =>
    calls.map((c) => c.endedAt!).reduce((a, b) => a.isAfter(b) ? a : b);

void main() {
  late _RecordingSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentTypeRegistry templates;
  late ProviderResolver resolver;
  late AgentRegistry agents;

  Session session(String id) => Session(
        id: id,
        title: 'Session $id',
        agentType: 'general',
        createdAt: 1,
        updatedAt: 1,
      );

  setUp(() {
    final defs = <String, Map<String, dynamic>>{
      for (final name in <String>[
        ...ToolCatalog.kBaseToolNames,
        'web_search',
        'web_fetch',
        'browser_navigate',
        'browser_click',
        'browser_type',
        'browser_snapshot',
      ])
        name: _def(name),
    };
    ToolCatalog.instance.seed(defs);

    templates = AgentTypeRegistry();
    templates.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'test-model',
      systemPrompt: '并行执行测试',
      tools: [
        'read_file',
        'list_dir',
        'glob_file',
        'grep_file',
        'read_spill',
        'read_image',
        'get_current_time',
        'web_search',
        'web_fetch',
        'write_file',
        'edit_file',
        'run_command',
        'browser_navigate',
        'browser_click',
        'browser_type',
        'browser_snapshot',
        'spawn_subagent',
      ],
      maxContextTokens: 100000,
    ));
    templates.register(const AgentTypeConfig(
      name: 'worker',
      provider: 'test',
      model: 'worker-model',
      systemPrompt: '子角色',
      tools: ['read_file', 'grep_file'],
      maxContextTokens: 100000,
    ));

    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'fake-key', baseUrl: ''),
      },
    ));

    sidecar = _RecordingSidecar();
    sessionRepo = FakeSessionRepository([session('s1')]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
  });

  tearDown(() {
    ToolCatalog.instance.reset();
  });

  AgentFactory makeFactory({
    int toolParallelMax = 0,
    SubagentRunner? runner,
    MessageRepository? messageRepo,
  }) {
    return AgentFactory(
      templates: templates,
      providerResolver: () => resolver,
      config: AppConfig(version: 1, toolParallelMax: toolParallelMax),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: messageRepo ?? msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: agents,
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
      subagentRunner: runner,
    );
  }

  Future<Agent> makeAgent({
    AgentCallbacks callbacks = const AgentCallbacks(),
    int toolParallelMax = 0,
    SubagentRunner? runner,
    MessageRepository? messageRepo,
    String sessionId = 's1',
  }) {
    return makeFactory(
      toolParallelMax: toolParallelMax,
      runner: runner,
      messageRepo: messageRepo,
    ).create(session(sessionId), callbacks: callbacks);
  }

  void queueToolCall(String id, String name, Map<String, dynamic> input) {
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': id,
      'name': name,
      'input': input,
    }));
  }

  /// 让模型这一轮只发这些工具调用。
  void queueToolTurn(List<({String id, String name, Map<String, dynamic> input})> calls) {
    for (final c in calls) {
      queueToolCall(c.id, c.name, c.input);
    }
    sidecar.queueDone();
  }

  void queueFinalTurn(String text) {
    sidecar.queueChunk(text);
    sidecar.queueDone();
  }

  const readFileResult = '{"ok":true,"content":"READ-①-独特","total_lines":1,'
      '"start_line":1,"end_line":1}';

  // ---------------------------------------------------------------------------
  // ① 连续三个只读调用重叠执行
  // ---------------------------------------------------------------------------
  test('① 一轮 3 个 read_file 各 200ms：三个时间窗两两重叠、总耗时 < 400ms', () async {
    sidecar.stubReadFile(readFileResult);
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 200));
    queueToolTurn([
      for (var i = 0; i < 3; i++)
        (id: 'r$i', name: 'read_file', input: {'path': 'f$i.txt'}),
    ]);
    queueFinalTurn('最终回复-①');
    final agent = await makeAgent();
    final result = await agent.send('并发三个读');

    final calls = sidecar.callsOf('read_file');
    final total = calls.isEmpty
        ? -1
        : _latestEnd(calls).difference(_earliestStart(calls)).inMilliseconds;
    // ignore: avoid_print
    print('[OBS] ① 结果=${result.status.name} 调用数=${calls.length} '
        '入口=${calls.map((c) => c.entry).toList()} '
        '时间窗=${calls.map((c) => c.durationMs).toList()} 段总耗时=${total}ms');

    expect(calls.length, 3);
    expect(calls[0].entry, 'worker', reason: '段长 ≥2 的同步只读工具必须走 worker 入口');
    expect(_overlapMs(calls[0], calls[1]), greaterThan(0));
    expect(_overlapMs(calls[0], calls[2]), greaterThan(0));
    expect(_overlapMs(calls[1], calls[2]), greaterThan(0));
    expect(total, lessThan(400),
        reason: '串行 3×200ms 必 ≥600ms；并发应接近最慢一个');
    expect(result.status, AgentRunStatus.completed);
  });

  // ---------------------------------------------------------------------------
  // ② 写类调用前后的只读不被提前
  // ---------------------------------------------------------------------------
  test('② [grep_file, write_file, read_file]：写类前后严格按序、互不重叠', () async {
    sidecar.stubGrepFile(
        '{"ok":true,"matches":[{"path":"a.txt","line":1,"text":"GREP-②"}],"count":1}');
    sidecar.stubReadFile('{"ok":true,"content":"READ-②","total_lines":1,'
        '"start_line":1,"end_line":1}');
    sidecar.stubToolDelay('grep_file', const Duration(milliseconds: 200));
    sidecar.stubToolDelay('write_file', const Duration(milliseconds: 150));
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 100));
    queueToolTurn([
      (id: 'g0', name: 'grep_file', input: {'pattern': 'GREP-②'}),
      (id: 'w1', name: 'write_file', input: {'path': 'a.txt', 'content': 'x'}),
      (id: 'r2', name: 'read_file', input: {'path': 'a.txt'}),
    ]);
    queueFinalTurn('最终回复-②');
    final agent = await makeAgent();
    await agent.send('写前写后');

    final grep = sidecar.callsOf('grep_file').single;
    final write = sidecar.callsOf('write_file').single;
    final read = sidecar.callsOf('read_file').single;
    // ignore: avoid_print
    print('[OBS] ② grep=${grep.durationMs}ms write=${write.durationMs}ms '
        'read=${read.durationMs}ms '
        '写开始≥ grep 结束: ${!write.startedAt.isBefore(grep.endedAt!)} '
        '读开始≥写结束: ${!read.startedAt.isBefore(write.endedAt!)}');

    expect(write.startedAt.isBefore(grep.endedAt!), isFalse,
        reason: 'write_file 必须在 grep_file 结束之后才开始');
    expect(read.startedAt.isBefore(write.endedAt!), isFalse,
        reason: 'read_file 必须在 write_file 结束之后才开始（读到写入后的状态）');
    expect(grep.entry, 'sync');
    expect(write.entry, 'sync');
    expect(read.entry, 'sync');
  });

  // ---------------------------------------------------------------------------
  // ③ 完成顺序与发出顺序相反时，三处产物都按发出顺序
  // ---------------------------------------------------------------------------
  test('③ 并发段 300/50/100ms 倒序完成：请求体/界面回调/落库都按发出顺序', () async {
    sidecar.stubGrepFile(
        '{"ok":true,"matches":[{"path":"g.txt","line":1,"text":"GREP-③-独特"}],"count":1}');
    sidecar.stubReadFile('{"ok":true,"content":"READ-③-独特","total_lines":1,'
        '"start_line":1,"end_line":1}');
    sidecar.stubListDir('{"ok":true,"content":"[{\\"name\\":\\"L-③-独特\\"}]"}');
    sidecar.stubToolDelay('grep_file', const Duration(milliseconds: 300));
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 50));
    sidecar.stubToolDelay('list_dir', const Duration(milliseconds: 100));

    queueToolTurn([
      (id: 'g0', name: 'grep_file', input: {'pattern': 'GREP-③'}),
      (id: 'r1', name: 'read_file', input: {'path': 'r.txt'}),
      (id: 'l2', name: 'list_dir', input: {'path': '.'}),
    ]);
    queueFinalTurn('最终回复-③');

    final uiResults = <ToolCallActivity>[];
    final agent = await makeAgent(callbacks: AgentCallbacks(
      onToolResult: uiResults.add,
    ));
    await agent.send('倒序完成');

    // 完成顺序（按结束时刻）：read(50) → list(100) → grep(300)，与发出顺序相反。
    final finishOrder = sidecar.toolCalls.toList()
      ..sort((a, b) => a.endedAt!.compareTo(b.endedAt!));
    // 请求体里 tool_result 的顺序。
    final requestBlocks =
        _lastToolResultBlocks(sidecar.requests[1].messagesJson);
    final requestIds = [for (final b in requestBlocks) b['tool_use_id']];
    // 界面回调顺序。
    final uiIds = [for (final a in uiResults) a.id];
    // 落库富化顺序。
    final enriched = msgRepo.messages
        .where((m) => m.role == 'assistant' && m.toolCallsJson != null)
        .last;
    final storedIds = [
      for (final t in (jsonDecode(enriched.toolCallsJson!) as List<dynamic>))
        (t as Map<String, dynamic>)['id'],
    ];
    // ignore: avoid_print
    print('[OBS] ③ 完成顺序=${finishOrder.map((c) => c.toolName).toList()} '
        '请求体顺序=$requestIds 界面顺序=$uiIds 落库顺序=$storedIds '
        '请求体内容=${requestBlocks.map((b) => _toolResultText(b)).toList()}');

    expect(finishOrder.map((c) => c.toolName).toList(),
        ['read_file', 'list_dir', 'grep_file'],
        reason: '延迟 50/100/300 决定完成顺序是倒着的');
    expect(requestIds, ['g0', 'r1', 'l2']);
    expect(uiIds, ['g0', 'r1', 'l2']);
    expect(storedIds, ['g0', 'r1', 'l2']);
    expect(_toolResultText(requestBlocks[0]), contains('GREP-③-独特'));
    expect(_toolResultText(requestBlocks[1]), contains('READ-③-独特'));
    expect(_toolResultText(requestBlocks[2]), contains('L-③-独特'));
  });

  // ---------------------------------------------------------------------------
  // ④ 组内一个成员失败不影响其它成员（错误文本含工具名与原因）
  // ---------------------------------------------------------------------------
  test('④ 段内 web_fetch 抛错、两个成功：三个结果按序齐发，失败者带工具名与原因', () async {
    sidecar.stubToolThrow('web_fetch', 'FETCH-BOOM-④：网络炸了');
    sidecar.stubReadFile('{"ok":true,"content":"READ-④-独特","total_lines":1,'
        '"start_line":1,"end_line":1}');
    sidecar.stubGrepFile(
        '{"ok":true,"matches":[{"path":"g.txt","line":1,"text":"GREP-④-独特"}],"count":1}');

    queueToolTurn([
      (id: 'f0', name: 'web_fetch', input: {'url': 'https://example.com/x'}),
      (id: 'r1', name: 'read_file', input: {'path': 'r.txt'}),
      (id: 'g2', name: 'grep_file', input: {'pattern': 'GREP-④'}),
    ]);
    queueFinalTurn('最终回复-④');
    final agent = await makeAgent();
    final result = await agent.send('一个失败两个成功');

    final blocks = _lastToolResultBlocks(sidecar.requests[1].messagesJson);
    final texts = [for (final b in blocks) _toolResultText(b)];
    // ignore: avoid_print
    print('[OBS] ④ 结果=${result.status.name} 请求数=${sidecar.requests.length} '
        'ids=${blocks.map((b) => b['tool_use_id']).toList()} '
        '失败者文本=${texts.isEmpty ? "" : texts[0]} '
        '成功者=${texts.skip(1).map((t) => t.substring(0, t.length > 30 ? 30 : t.length)).toList()}');

    expect(result.status, AgentRunStatus.completed);
    expect(blocks.length, 3);
    expect(blocks.map((b) => b['tool_use_id']).toList(), ['f0', 'r1', 'g2']);
    expect(texts[0], contains('web_fetch'), reason: '错误文本必须带工具名');
    expect(texts[0], contains('FETCH-BOOM-④'), reason: '错误文本必须带实际原因');
    expect(texts[1], contains('READ-④-独特'));
    expect(texts[2], contains('GREP-④-独特'));
    expect(sidecar.requests.length, 2, reason: '下一轮模型请求照常组装');
  });

  // ---------------------------------------------------------------------------
  // ⑤ 单个只读调用维持现有执行路径
  // ---------------------------------------------------------------------------
  test('⑤ 单只读一轮：走同步入口，callToolOnWorker 零调用', () async {
    sidecar.stubReadFile(readFileResult);
    queueToolTurn([
      (id: 'r0', name: 'read_file', input: {'path': 'one.txt'}),
    ]);
    queueFinalTurn('最终回复-⑤');
    final agent = await makeAgent();
    await agent.send('单个读');

    final calls = sidecar.callsOf('read_file');
    // ignore: avoid_print
    print('[OBS] ⑤ 调用数=${calls.length} 入口=${calls.map((c) => c.entry).toList()} '
        'worker 条目数=${sidecar.entriesUsed.where((e) => e == 'worker').length}');

    expect(calls.length, 1);
    expect(calls.single.entry, 'sync', reason: '段长 1 必须走原来的同步路径');
    expect(sidecar.entriesUsed.contains('worker'), isFalse);
  });

  // ---------------------------------------------------------------------------
  // ⑥ 连续写类调用保持逐个执行
  // ---------------------------------------------------------------------------
  test('⑥ 连续两个 write_file：都走逐个入口，时间窗不重叠', () async {
    sidecar.stubToolDelay('write_file', const Duration(milliseconds: 100));
    queueToolTurn([
      (id: 'w0', name: 'write_file', input: {'path': 'a.txt', 'content': 'A'}),
      (id: 'w1', name: 'write_file', input: {'path': 'b.txt', 'content': 'B'}),
    ]);
    queueFinalTurn('最终回复-⑥');
    final agent = await makeAgent();
    await agent.send('连写两个');

    final calls = sidecar.callsOf('write_file')..sort(
        (a, b) => a.startedAt.compareTo(b.startedAt));
    // ignore: avoid_print
    print('[OBS] ⑥ 调用数=${calls.length} 入口=${calls.map((c) => c.entry).toList()} '
        '第二个开始≥第一个结束: ${!calls[1].startedAt.isBefore(calls[0].endedAt!)}');

    expect(calls.length, 2);
    expect(calls.map((c) => c.entry).toList(), ['sync', 'sync']);
    expect(calls[1].startedAt.isBefore(calls[0].endedAt!), isFalse,
        reason: '两个写类调用的执行时间窗不许重叠');
  });

  // ---------------------------------------------------------------------------
  // ⑦ tool.parallel_max = 2 + 4 个只读：2+2 两批、交付仍按发出顺序
  // ---------------------------------------------------------------------------
  test('⑦ parallel_max=2 + 4 个只读：分 2+2 两批，第二批不早于第一批结束', () async {
    sidecar.stubReadFile(readFileResult);
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 100));
    queueToolTurn([
      for (var i = 0; i < 4; i++)
        (id: 'r$i', name: 'read_file', input: {'path': 'f$i.txt'}),
    ]);
    queueFinalTurn('最终回复-⑦');
    final agent = await makeAgent(toolParallelMax: 2);
    await agent.send('四连读');

    final calls = sidecar.callsOf('read_file')
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final firstBatch = calls.sublist(0, 2);
    final secondBatch = calls.sublist(2);
    final blocks = _lastToolResultBlocks(sidecar.requests[1].messagesJson);
    // ignore: avoid_print
    print('[OBS] ⑦ 调用数=${calls.length} 入口=${calls.map((c) => c.entry).toList()} '
        '第一批结束=${_latestEnd(firstBatch).microsecondsSinceEpoch} '
        '第二批开始=${_earliestStart(secondBatch).microsecondsSinceEpoch} '
        '请求体顺序=${blocks.map((b) => b['tool_use_id']).toList()}');

    expect(calls.length, 4);
    expect(_overlapMs(firstBatch[0], firstBatch[1]), greaterThan(0));
    expect(_overlapMs(secondBatch[0], secondBatch[1]), greaterThan(0),
        reason: '第二批的两个成员也必须并发');
    expect(_earliestStart(secondBatch).isBefore(_latestEnd(firstBatch)), isFalse,
        reason: 'maxParallel=2 时第二批只能在第一批全部结束后启动');
    expect(blocks.map((b) => b['tool_use_id']).toList(), ['r0', 'r1', 'r2', 'r3'],
        reason: '拆分不改变交付顺序');
  });

  // ---------------------------------------------------------------------------
  // ⑧ 取消先于组启动
  // ---------------------------------------------------------------------------
  test('⑧ 工具轮到达后、段启动前取消：FakeSidecar 零工具调用记录', () async {
    sidecar.stubReadFile(readFileResult);
    queueToolTurn([
      (id: 'r0', name: 'read_file', input: {'path': 'a.txt'}),
      (id: 'r1', name: 'read_file', input: {'path': 'b.txt'}),
    ]);
    queueFinalTurn('不该出现-⑧');

    late Agent agent;
    final result = await () async {
      agent = await makeAgent(callbacks: AgentCallbacks(
        onToolCall: (activity) {
          // 第一个 tool_use 刚到达就取消：段还没启动。
          agent.cancel();
        },
      ));
      return agent.send('取消先于执行');
    }();

    // ignore: avoid_print
    print('[OBS] ⑧ 结果=${result.status.name} 工具调用记录=${sidecar.toolCalls}');
    expect(result.status, AgentRunStatus.cancelled);
    expect(sidecar.toolCalls, isEmpty,
        reason: '组启动前取消 ⇒ 组内没有任何工具被实际执行');
  });

  // ---------------------------------------------------------------------------
  // ⑨ 取消发生在组执行途中
  // ---------------------------------------------------------------------------
  test('⑨ 段执行中取消：成员自然结束、结果丢弃、卡片与落库都写取消说明', () async {
    sidecar.stubReadFile(readFileResult);
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 200));
    queueToolTurn([
      for (var i = 0; i < 3; i++)
        (id: 'r$i', name: 'read_file', input: {'path': 'f$i.txt'}),
    ]);
    queueFinalTurn('不该出现-⑨');

    final uiResults = <ToolCallActivity>[];
    final agent = await makeAgent(callbacks: AgentCallbacks(
      onToolResult: uiResults.add,
    ));
    final running = agent.send('执行中取消');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    agent.cancel();
    final result = await running;

    final calls = sidecar.callsOf('read_file');
    final stored = msgRepo.messages
        .where((m) => m.role == 'assistant' && m.toolCallsJson != null)
        .last;
    final storedEntries =
        (jsonDecode(stored.toolCallsJson!) as List<dynamic>)
            .cast<Map<String, dynamic>>();
    // ignore: avoid_print
    print('[OBS] ⑨ 结果=${result.status.name} 已启动=${calls.length} '
        '全部结束=${calls.every((c) => c.finished)} 请求数=${sidecar.requests.length} '
        '卡片=${uiResults.map((a) => '${a.id}/${a.status.name}/${a.result}').toList()} '
        '落库=${storedEntries.map((t) => t['result']).toList()}');

    expect(result.status, AgentRunStatus.cancelled);
    expect(calls.length, 3, reason: '三个成员必须都已启动（并发段同时启动）');
    expect(calls.every((c) => c.finished), isTrue,
        reason: '已启动的成员必须各自自然结束，不泄漏后台执行单元');
    expect(sidecar.requests.length, 1,
        reason: '取消后不再发下一轮请求 ⇒ 本轮的 tool_result 没有进入模型请求');
    expect(uiResults.length, 3);
    for (final activity in uiResults) {
      expect(activity.status, ToolCallStatus.error,
          reason: '被丢弃的卡片必须置为终态，不能停在"执行中"');
      expect(activity.result ?? '', contains('因取消未取回结果'));
    }
    expect(storedEntries.length, 3);
    for (final t in storedEntries) {
      expect((t['result'] ?? '').toString(), contains('因取消未取回结果'),
          reason: 'toolCallsJson 富化必须写入同一条取消说明');
    }
  });

  // ---------------------------------------------------------------------------
  // ⑩ 取消后重放历史带取消标记
  // ---------------------------------------------------------------------------
  test('⑩ 取消后同会话再发一条消息：重放的 tool_result 是取消说明而非空串', () async {
    sidecar.stubReadFile(readFileResult);
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 200));
    queueToolTurn([
      for (var i = 0; i < 2; i++)
        (id: 'r$i', name: 'read_file', input: {'path': 'f$i.txt'}),
    ]);
    queueFinalTurn('不该出现-⑩');

    final agent = await makeAgent();
    final running = agent.send('执行中取消-⑩');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    agent.cancel();
    final cancelled = await running;
    expect(cancelled.status, AgentRunStatus.cancelled);

    // 同一会话继续发一条：走历史重放。
    sidecar.queueChunk('取消后的回复-⑩');
    sidecar.queueDone();
    await agent.send('取消后再发');

    final replayed = _lastToolResultBlocks(sidecar.requests[1].messagesJson);
    final texts = [for (final b in replayed) _toolResultText(b)];
    // ignore: avoid_print
    print('[OBS] ⑩ 重放结果块数=${replayed.length} 内容=$texts');
    expect(replayed.length, 2);
    for (final text in texts) {
      expect(text, isNotEmpty, reason: '不许是空字符串');
      expect(text, contains('因取消未取回结果'));
    }
  });

  // ---------------------------------------------------------------------------
  // ⑪ 子 Agent 轮内的连续只读同样并发
  // ---------------------------------------------------------------------------
  test('⑪ 子 Agent 一轮发 2 个连续只读：时间窗重叠', () async {
    sidecar.stubReadFile(readFileResult);
    sidecar.stubToolDelay('read_file', const Duration(milliseconds: 150));
    sidecar.stubWorkspace('parent-1', 'E:/parent-workspace');

    late AgentFactory factory;
    final runner = SubagentRunner(factory: () => factory, sidecar: sidecar);
    factory = makeFactory(runner: runner);

    // 父第一轮：调用 spawn_subagent。
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'spawn-1',
      'name': 'spawn_subagent',
      'input': {'task': '读两个文件并给结论', 'agent_type': 'worker'},
    }));
    sidecar.queueDone();
    // 子第一轮：连续两个 read_file。
    queueToolCall('c0', 'read_file', {'path': 'c0.txt'});
    queueToolCall('c1', 'read_file', {'path': 'c1.txt'});
    sidecar.queueDone();
    // 子第二轮：最终结论。
    queueFinalTurn('子结论-⑪');
    // 父第二轮：最终回复。
    queueFinalTurn('父最终回复-⑪');

    final parent = await factory.create(session('parent-1'));
    final result = await parent.send('派个子任务');

    final calls = sidecar.callsOf('read_file');
    final overlap = calls.length >= 2 ? _overlapMs(calls[0], calls[1]) : -1;
    // ignore: avoid_print
    print('[OBS] ⑪ 父结果=${result.status.name} 子读调用=${calls.length} '
        '时间窗=${calls.map((c) => c.durationMs).toList()} 重叠=${overlap}ms');

    expect(result.status, AgentRunStatus.completed);
    expect(calls.length, 2);
    expect(calls[0].entry, 'worker');
    expect(overlap, greaterThan(0), reason: '子 Agent 的一轮连续只读也必须并发');
  });
}
