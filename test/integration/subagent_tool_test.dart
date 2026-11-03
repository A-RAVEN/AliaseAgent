// 父子模型—工具循环与结果映射（add-spawn-subagent-tool 任务 4.3 / 4.4）。
//
// 用假 sidecar 驱动**真实**的父子 Agent：
//   父模型调用 spawn_subagent → 子模型执行工具后给出结论 → 父模型收到工具结果继续。
// 这里的每个独特标记都只属于一个上下文，任何一处串用都会让断言失败：
//   - 父历史/父问题不得出现在子 Agent 的首次请求里；
//   - 子的中间文本、思考、工具输入与工具输出不得进入父请求；
//   - 子的实际工具定义不含 spawn_subagent（不能嵌套），父仍保留；
//   - 子用指定模板的模型与推理强度，工作区从父句柄继承；
//   - 父界面回调只收到父自己的事件；
//   - 成功结果的 child_session_id / 模板 / 模型 / 子计量只写进父工具活动与
//     toolCallsJson，父模型内容仍只有最终结论；
//   - 模型失败、取消、空回复、实例忙、未预期异常都是可区分的 ok:false；
//   - 超长结论在当轮与从历史重建的父请求里都完整保留（不套通用省略规则）。
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/main.dart';
import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/session.dart';
import 'package:alias_agent/services/agent.dart';
import 'package:alias_agent/services/agent_factory.dart';
import 'package:alias_agent/services/agent_registry.dart';
import 'package:alias_agent/services/compaction/model_summary_provider.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/provider_resolver.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'package:alias_agent/services/subagent_runner.dart';
import 'package:alias_agent/services/summary_node_repository.dart';
import 'package:alias_agent/services/tool_catalog.dart';
import 'package:alias_agent/services/tool_result_text.dart';

import '../widget/helpers/fakes.dart';
import 'helpers/fake_sidecar.dart';

/// 按句柄记录每次模型请求（FakeSidecar 只留最后一次）。
class _RecordingSidecar extends FakeSidecar {
  final List<
      ({
        String handle,
        String messagesJson,
        String model,
        String systemPrompt,
        String toolsJson,
        String thinkingEffort,
      })> requests = [];

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
    requests.add((
      handle: handle,
      messagesJson: messagesJson,
      model: model,
      systemPrompt: systemPrompt,
      toolsJson: toolsJson,
      thinkingEffort: thinkingEffort,
    ));
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

/// 写**子会话**的助手消息时抛异常：制造模型循环里的未预期异常。
/// （父会话的写库正常，否则异常发生在父子循环之外。）
class _ExplodingChildWriteRepo extends FakeMessageRepository {
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
    if (role == 'assistant' && sessionId != 'parent-1') {
      throw StateError('子会话写库炸了-独特');
    }
    return super.insert(
      sessionId: sessionId,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      thinkingJson: thinkingJson,
      tokenCount: tokenCount,
      outputTokenCount: outputTokenCount,
      attachments: attachments,
    );
  }
}

void main() {
  late _RecordingSidecar sidecar;
  late FakeSessionRepository sessionRepo;
  late FakeMessageRepository msgRepo;
  late AgentRegistry agents;

  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'fake $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  Session session(String id, String agentType) => Session(
        id: id,
        title: 'Session $id',
        agentType: agentType,
        createdAt: 1,
        updatedAt: 1,
      );

  setUp(() {
    ToolCatalog.instance.seed({
      'read_file': def('read_file'),
      'spawn_subagent': def('spawn_subagent'),
    });
    registry.clear();
    registry.register(const AgentTypeConfig(
      name: 'general',
      provider: 'test',
      model: 'parent-model',
      systemPrompt: 'PARENT-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      thinkingEffort: 'high',
      maxContextTokens: 100000,
    ));
    registry.register(const AgentTypeConfig(
      name: 'worker',
      provider: 'test',
      model: 'worker-model',
      systemPrompt: 'WORKER-PROMPT',
      tools: ['read_file', 'spawn_subagent'],
      thinkingEffort: 'max',
      maxContextTokens: 80000,
    ));
    resolver = ProviderResolver(const AppConfig(
      version: 1,
      providers: {
        'test': ProviderConfig(apiKey: 'sk-parent-secret', baseUrl: ''),
      },
    ));
    sidecar = _RecordingSidecar();
    sidecar.stubReadFile('{"ok":true,"content":"子工具输出-独特","total_lines":1,'
        '"start_line":1,"end_line":1}');
    sessionRepo = FakeSessionRepository([]);
    msgRepo = FakeMessageRepository();
    agents = AgentRegistry();
  });

  tearDown(() {
    ToolCatalog.instance.reset();
    registry.clear();
    resolver = null;
  });

  /// 建一个父 Agent 与配套工厂（工厂带子运行服务，延迟回调避免构造循环）。
  Future<(Agent, AgentFactory)> buildParent({
    AgentCallbacks callbacks = const AgentCallbacks(),
    MessageRepository? messageRepo,
  }) async {
    late AgentFactory factory;
    final runner = SubagentRunner(factory: () => factory, sidecar: sidecar);
    factory = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
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
    final parent = await factory.create(session('parent-1', 'general'),
        callbacks: callbacks);
    sidecar.stubWorkspace('parent-1', 'E:/parent-workspace');
    return (parent, factory);
  }

  Map<String, dynamic> queueSpawnToolCall() {
    final call = {
      'type': 'tool_use',
      'id': 'spawn-1',
      'name': 'spawn_subagent',
      'input': {'task': '调查子任务-独特：读 note.txt 并给结论', 'agent_type': 'worker'},
    };
    sidecar.queueToolCall(jsonEncode(call));
    return call;
  }

  List<String> toolNames(String json) => [
        for (final t in jsonDecode(json) as List<dynamic>)
          (t as Map<String, dynamic>)['name'] as String,
      ];

  test('父子模型—工具循环：子历史隔离、工作区继承、无嵌套、父只收结论', () async {
    // 父会话先有一条独特历史：它绝不能出现在子 Agent 的请求里。
    msgRepo.messages.add(Message(
      id: 'parent-hist-1',
      seq: 1,
      sessionId: 'parent-1',
      role: 'user',
      content: '父历史-独特',
      createdAt: 1,
    ));

    final parentChunks = <String>[];
    final parentToolEvents = <String>[];
    final parentAssistant = <Message>[];
    final (parent, _) = await buildParent(callbacks: AgentCallbacks(
      onChunk: parentChunks.add,
      onToolCall: (activity) => parentToolEvents.add(activity.toolName),
      onAssistantMessage: (message, isFinal) => parentAssistant.add(message),
    ));

    // 父第一轮：思考 + 一段中间文本 + 调用 spawn_subagent。
    sidecar.queueThinking(
        '{"type":"thinking","thinking":"父思考-独特","signature":"sig-parent"}');
    sidecar.queueChunk('父中间文本-独特');
    queueSpawnToolCall();
    sidecar.queueDone(inputTokens: 30, outputTokens: 10);
    // 子第一轮：自己的思考 + 中间文本 + 工具调用。
    sidecar.queueThinking(
        '{"type":"thinking","thinking":"子思考-独特","signature":"sig-child"}');
    sidecar.queueChunk('子中间文本-独特');
    sidecar.queueToolCall(jsonEncode({
      'type': 'tool_use',
      'id': 'child-read-1',
      'name': 'read_file',
      'input': {'path': 'child-only-note.txt'},
    }));
    sidecar.queueDone(inputTokens: 5, outputTokens: 2);
    // 子第二轮：最终结论。
    sidecar.queueChunk('子最终结论-独特');
    sidecar.queueDone(inputTokens: 6, outputTokens: 4);
    // 父第二轮：最终回复。
    sidecar.queueChunk('父最终回复-独特');
    sidecar.queueDone(inputTokens: 40, outputTokens: 8);

    final result = await parent.send('父问题-独特');
    final childSession =
        sessionRepo.sessions.firstWhere((s) => s.parentSessionId == 'parent-1');

    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    final childRequests =
        sidecar.requests.where((r) => r.handle == childSession.id).toList();
    // ignore: avoid_print
    print('[OBS] 父结果 status=${result.status.name} finalText=${result.finalText}\n'
        '[OBS] 子会话=${childSession.id} parent=${childSession.parentSessionId} '
        '子实例已清理=${!agents.contains(childSession.id)} 子工作区='
        '${sidecar.defaultWorkspaceByHandle[childSession.id]}\n'
        '[OBS] 父请求数=${parentRequests.length} 子请求数=${childRequests.length} '
        '父回调 chunks=$parentChunks tools=$parentToolEvents '
        '父助手消息=${parentAssistant.map((m) => m.content).toList()}\n'
        '[OBS] 子首请求 messages=${childRequests.first.messagesJson}\n'
        '[OBS] 父第二请求 messages=${parentRequests.last.messagesJson}');

    expect(result.status, AgentRunStatus.completed);
    expect(result.finalText, '父最终回复-独特');

    // ---- 子历史独立：首次请求不含父历史与父问题 ----
    expect(childRequests, hasLength(2),
        reason: '子 Agent 自己走了两轮（工具轮 + 最终回复）');
    expect(childRequests.first.messagesJson, isNot(contains('父历史-独特')),
        reason: '子 Agent 首次请求不得包含父会话历史');
    expect(childRequests.first.messagesJson, isNot(contains('父问题-独特')),
        reason: '子 Agent 不得复制父对话消息');
    expect(childRequests.first.messagesJson, contains('调查子任务-独特'));
    expect(childRequests.first.systemPrompt, contains('WORKER-PROMPT'));
    expect(childRequests.first.systemPrompt, contains(kSubagentRolePrompt));

    // ---- 指定模板的模型与推理强度 ----
    expect(childRequests.first.model, 'worker-model');
    expect(childRequests.first.thinkingEffort, 'max');

    // ---- 不能嵌套：子的工具定义不含 spawn_subagent；父仍保留 ----
    expect(toolNames(childRequests.first.toolsJson),
        isNot(contains('spawn_subagent')),
        reason: '子 Agent 的实际模型请求不能含 spawn_subagent');
    expect(toolNames(childRequests.first.toolsJson), contains('read_file'));
    expect(toolNames(parentRequests.first.toolsJson),
        contains('spawn_subagent'),
        reason: '父 Agent 的请求仍保留 spawn_subagent');

    // ---- 工作区按父句柄继承 ----
    expect(sidecar.defaultWorkspaceByHandle[childSession.id],
        'E:/parent-workspace',
        reason: '子上下文必须初始化到父句柄读取到的工作区');
    expect(sidecar.getWorkspaceCalls, contains('parent-1'));

    // ---- 父第二轮只增加结论，不含子的中间内容 ----
    final parentSecond = parentRequests.last.messagesJson;
    expect(parentSecond, contains('子最终结论-独特'),
        reason: '父后续请求必须含子的最终结论');
    expect(parentSecond, isNot(contains('子中间文本-独特')),
        reason: '子的中间助手文本不得进入父请求');
    expect(parentSecond, isNot(contains('子思考-独特')),
        reason: '子的思考不得进入父请求');
    expect(parentSecond, isNot(contains('child-only-note.txt')),
        reason: '子的工具输入不得进入父请求');
    expect(parentSecond, isNot(contains('子工具输出-独特')),
        reason: '子的工具输出不得进入父请求');

    // ---- 子历史里只有自己的内容，父历史里没有子的中间内容 ----
    // 子实例在工具返回时已被清理（5.1），所以它的历史只能从子会话落库的行来核对；
    // "首次请求不含父历史"由上面对 childRequests.first 的断言直接证明。
    expect(agents.contains(childSession.id), isFalse,
        reason: '子实例必须在工具返回前完成清理');
    expect(parent.messageHistory.any((m) => m.content == '子最终结论-独特'), isFalse,
        reason: '子最终结论只作为工具结果进入父请求，不写成父的助手消息');
    expect(parent.messageHistory.any((m) => m.content == '父最终回复-独特'), isTrue);

    // ---- 父界面回调只收到父自己的事件 ----
    expect(parentChunks, isNot(contains('子中间文本-独特')));
    expect(parentChunks, isNot(contains('子最终结论-独特')));
    expect(parentToolEvents, ['spawn_subagent'],
        reason: '子的 read_file 事件不得进入父回调');
    expect(parentAssistant.map((m) => m.content).toList(),
        ['父中间文本-独特', '父最终回复-独特']);

    // ---- 子的中间内容只写进子会话 ----
    final childWrites = msgRepo.messages
        .where((m) => m.sessionId == childSession.id)
        .map((m) => m.content)
        .toList();
    debugPrint('[OBS] 子会话落库='
        '${msgRepo.messages.where((m) => m.sessionId == childSession.id).map((m) => '${m.role}:${m.content}').toList()}');
    expect(childWrites, contains('子中间文本-独特'));
    expect(childWrites, contains('子最终结论-独特'));
    expect(childWrites, isNot(contains('父历史-独特')));

    // ---- 成功元数据：只进父工具活动 / toolCallsJson，不进父模型内容 ----
    final toolMsg = msgRepo.messages
        .firstWhere((m) => m.toolCallsJson?.contains('spawn_subagent') == true);
    final persisted = (jsonDecode(toolMsg.toolCallsJson!) as List).first
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('[OBS] 落库的父工具调用=${jsonEncode(persisted)}');
    expect(persisted['child_session_id'], childSession.id);
    expect(persisted['child_agent_type'], 'worker');
    expect(persisted['child_model'], 'worker-model');
    expect(persisted['child_metering'], {
      'input_tokens': 11,
      'output_tokens': 6,
      'total_tokens': 17,
      'requests': 2,
      'tool_calls': 1,
    });
    expect(persisted['result'], '子最终结论-独特');
    expect(jsonEncode(persisted), isNot(contains('sk-parent-secret')),
        reason: '持久化元数据不得包含 provider 密钥');
    // 父计量独立：子计量没有并进父实例。
    expect(parent.metering.inputTokens, 70);
    expect(parent.metering.outputTokens, 18);
    expect(parent.metering.requests, 2);
    expect(parent.metering.toolCalls, 1);
  });

  test('子 Agent 模型失败：父结果是 ok:false + subagent_failed，父可继续', () async {
    final (parent, _) = await buildParent();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueDone(code: 1, error: '子模型炸了-独特');
    sidecar.queueChunk('父收到失败后继续-独特');
    sidecar.queueDone();

    final result = await parent.send('父问题');
    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    final parentSecond = parentRequests.last.messagesJson;
    final toolMsg = msgRepo.messages
        .firstWhere((m) => m.toolCallsJson?.contains('spawn_subagent') == true);
    final persisted = (jsonDecode(toolMsg.toolCallsJson!) as List).first
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('[OBS] 模型失败：父结果=${result.status.name}/${result.finalText} '
        '父第二请求=$parentSecond 落库工具调用=${jsonEncode(persisted)}');

    expect(result.status, AgentRunStatus.completed);
    expect(result.finalText, '父收到失败后继续-独特');
    expect(parentSecond, contains('子模型炸了-独特'),
        reason: '父模型必须看到子的失败原文');
    expect(parentSecond, isNot(contains('子最终结论')),
        reason: '失败不得伪装成成功结论');
    expect(persisted['child_session_id'], isNotNull,
        reason: '失败结果也要带已知的 child_session_id');
    expect(persisted['result'], isNot(contains('子最终结论')));
  });

  test('子 Agent 被取消：父结果是 ok:false + subagent_cancelled', () async {
    final (parent, _) = await buildParent();
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueDone(code: -1, error: 'cancelled');
    sidecar.queueChunk('父取消后继续-独特');
    sidecar.queueDone();

    final result = await parent.send('父问题');
    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    // ignore: avoid_print
    print('[OBS] 取消：父结果=${result.status.name}/${result.finalText} '
        '父第二请求=${parentRequests.last.messagesJson}');

    expect(result.status, AgentRunStatus.completed);
    expect(parentRequests.last.messagesJson, contains('子 Agent 被取消'),
        reason: '取消必须以可区分错误交给父模型，不得当成空成功');
    expect(parentRequests.last.messagesJson, isNot(contains('子最终结论')));
  });

  test('子 Agent 完成但空回复：父结果是 ok:false + empty_final_response', () async {
    final (parent, _) = await buildParent();
    queueSpawnToolCall();
    sidecar.queueDone();
    // 子只有 done、没有任何文本。
    sidecar.queueDone();
    sidecar.queueChunk('父收到空回复后继续-独特');
    sidecar.queueDone();

    final result = await parent.send('父问题');
    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    // ignore: avoid_print
    print('[OBS] 空回复：父结果=${result.status.name}/${result.finalText} '
        '父第二请求=${parentRequests.last.messagesJson}');

    expect(result.status, AgentRunStatus.completed);
    expect(parentRequests.last.messagesJson, contains('没有最终文本'),
        reason: '空回复不得作为成功结论交给父模型');
  });

  test('子 Agent 未预期异常：父结果是 ok:false，不伪装成空成功', () async {
    final exploding = _ExplodingChildWriteRepo();
    final (parent, _) =
        await buildParent(messageRepo: exploding);
    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk('子要写库的回复');
    sidecar.queueDone();
    sidecar.queueChunk('父收到异常后继续-独特');
    sidecar.queueDone();

    final result = await parent.send('父问题');
    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    // ignore: avoid_print
    print('[OBS] 未预期异常：父结果=${result.status.name}/${result.finalText} '
        '父第二请求=${parentRequests.last.messagesJson}');

    expect(result.status, AgentRunStatus.completed);
    expect(parentRequests.last.messagesJson, contains('未预期异常'),
        reason: '未预期异常必须作为失败错误交给父模型');
    expect(parentRequests.last.messagesJson, contains('子会话写库炸了-独特'));
  });

  test('实例忙：结果映射为 ok:false + subagent_busy（不会开始第二次调用）', () async {
    final (parent, _) = await buildParent();
    // 新建的子实例不会“忙”，这里直接验证映射函数：忙必须是可区分的失败。
    final mapped = SubagentRunner.mapRunResult(
      parent,
      AgentRunResult.busy(
        metering: AgentMeteringSnapshot.of(parent.metering),
      ),
    );
    // ignore: avoid_print
    print('[OBS] 实例忙映射=$mapped');
    expect(mapped['ok'], isFalse);
    expect(mapped['code'], 'subagent_busy');
    expect(mapped['child_session_id'], 'parent-1');
  });

  test('超长结论：当轮工具结果、父后续请求与恢复后重建都逐字完整', () async {
    const head = '长结论头-独特|';
    const middle = '|长结论中段-独特|';
    const tail = '|长结论尾-独特';
    final filler =
        List.filled(kToolResultElisionThreshold ~/ 2 + 500, 'A').join();
    final longReply = '$head$filler$middle$filler$tail';
    expect(longReply.length, greaterThan(kToolResultElisionThreshold),
        reason: '结论必须超过通用省略阈值，才测得到“不省略”');

    msgRepo.messages.add(Message(
      id: 'parent-hist-1',
      seq: 1,
      sessionId: 'parent-1',
      role: 'user',
      content: '父历史-超长结论用例',
      createdAt: 1,
    ));
    final (parent, _) = await buildParent();

    queueSpawnToolCall();
    sidecar.queueDone();
    sidecar.queueChunk(longReply);
    sidecar.queueDone(inputTokens: 9, outputTokens: 3000);
    sidecar.queueChunk('父看到长结论-独特');
    sidecar.queueDone();

    final result = await parent.send('父问题-长结论');
    final parentRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    final parentSecond = parentRequests.last.messagesJson;
    final toolMsg = msgRepo.messages
        .firstWhere((m) => m.toolCallsJson?.contains('spawn_subagent') == true);
    final persisted = (jsonDecode(toolMsg.toolCallsJson!) as List).first
        as Map<String, dynamic>;
    // ignore: avoid_print
    print('[OBS] 长结论：长度=${longReply.length} 父结果=${result.status.name} '
        '当轮结果长度=${(persisted['result'] as String).length} '
        '父第二请求含中段=${parentSecond.contains('长结论中段-独特')} '
        '含省略标记=${parentSecond.contains('[tool_result body elided')}');

    expect(result.status, AgentRunStatus.completed);
    expect(persisted['result'], longReply,
        reason: '当轮工具结果必须逐字等于子的最终回复');
    expect(parentSecond, contains('长结论中段-独特'),
        reason: '父后续请求必须保留结论中段（未按通用阈值省略）');
    expect(parentSecond, isNot(contains('[tool_result body elided')),
        reason: '不得出现通用省略标记');
    expect(parentSecond, isNot(contains('...[truncated middle of')));

    // 从持久化历史恢复一个新父实例，再发一轮：重建请求仍逐字完整。
    late AgentFactory factory2;
    final runner2 = SubagentRunner(factory: () => factory2, sidecar: sidecar);
    factory2 = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: const AppConfig(version: 1),
      sidecar: sidecar,
      sessionRepo: sessionRepo,
      messageRepo: msgRepo,
      summaryNodeRepo: SummaryNodeRepository(),
      registry: AgentRegistry(),
      summaryProvider: FakeSummaryProvider(),
      backgroundFoldEnabled: false,
      summaryStoreOpen: () => false,
      subagentRunner: runner2,
    );
    final restored = await factory2.create(session('parent-1', 'general'));
    sidecar.queueChunk('恢复后回复-独特');
    sidecar.queueDone();
    final restoredResult = await restored.send('恢复后再发-独特');
    final restoredRequests =
        sidecar.requests.where((r) => r.handle == 'parent-1').toList();
    final rebuilt = restoredRequests.last.messagesJson;
    // ignore: avoid_print
    print('[OBS] 恢复后：结果=${restoredResult.status.name} '
        '重建请求含中段=${rebuilt.contains('长结论中段-独特')} '
        '含省略标记=${rebuilt.contains('[tool_result body elided')} '
        '含恢复后问题=${rebuilt.contains('恢复后再发-独特')}');

    expect(restoredResult.status, AgentRunStatus.completed);
    expect(rebuilt, contains('长结论中段-独特'),
        reason: '从数据库恢复后重建的父请求仍必须逐字保留结论');
    expect(rebuilt, isNot(contains('[tool_result body elided')));
  });
}
