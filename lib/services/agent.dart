import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/agent_type_config.dart';
import '../models/compaction_status.dart';
import '../models/context_breakdown.dart';
import '../models/message.dart';
import '../models/provider_config.dart' as provider_model;
import '../models/resolved_agent_config.dart';
import '../models/tool_call_activity.dart';
import 'compaction/compaction_plan.dart';
import 'compaction/guard_anchors.dart';
import 'compaction/seam_selector.dart';
import 'compaction/summary_provider.dart';
import 'compaction/summary_reference.dart';
import 'config_service.dart';
import 'context_estimator.dart';
import 'context_snapshot.dart';
import 'database_service.dart';
import 'image_budget.dart';
import 'image_request.dart';
import 'message_repository.dart';
import 'search_text_assembly.dart';
import 'session_repository.dart';
import 'sidecar_bridge.dart';
import 'subagent_runner.dart';
import 'summary_node_repository.dart';
import 'tool_catalog.dart';
import 'tool_result_text.dart';

/// 界面订阅 Agent 事件的通道。
///
/// Agent 是执行与写库的**所有者**；界面只接收这里的事件去更新自己那份展示状态。
/// 事件不带"当前会话"判断 —— 那份判断属于界面，Agent 不读界面当前选中了谁。
class AgentCallbacks {
  final void Function(String text)? onChunk;
  final void Function(ToolCallActivity activity)? onToolCall;
  final void Function(int index, String delta)? onThinkingDelta;
  final void Function(int index, String thinking, String? signature)?
      onThinkingBlock;
  final void Function(ToolCallActivity activity)? onToolResult;
  final void Function(Message message, bool isFinal)? onAssistantMessage;
  final void Function(Message message)? onUserMessage;
  final void Function(bool streaming)? onStreamingChanged;

  /// 一次模型请求结束（一次工具轮 / 最终轮）：界面据此把流式文本与"正在思考"
  /// 标记收尾，但**整轮还没结束**（工具轮后还会再发一次请求）。
  final void Function()? onTurnCompleted;

  final void Function(ContextSnapshot snapshot)? onSnapshot;
  final void Function()? onCompactionStatusChanged;
  final void Function(String title)? onTitleChanged;
  final void Function()? onMeteringChanged;

  const AgentCallbacks({
    this.onChunk,
    this.onToolCall,
    this.onThinkingDelta,
    this.onThinkingBlock,
    this.onToolResult,
    this.onAssistantMessage,
    this.onUserMessage,
    this.onStreamingChanged,
    this.onTurnCompleted,
    this.onSnapshot,
    this.onCompactionStatusChanged,
    this.onTitleChanged,
    this.onMeteringChanged,
  });
}

/// 一个 Agent 实例的计量（这一轮 / 累计）。
class AgentMetering {
  int inputTokens = 0;
  int outputTokens = 0;
  int requests = 0;
  int toolCalls = 0;

  int get totalTokens => inputTokens + outputTokens;

  Map<String, dynamic> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'total_tokens': totalTokens,
        'requests': requests,
        'tool_calls': toolCalls,
      };
}

/// 一次 [Agent.send] 的结果类别。现有界面可以忽略返回值；子 Agent 运行器必须
/// 据此区分成功、失败、取消与"实例正忙"，不得把失败当成空成功。
enum AgentRunStatus {
  /// 模型循环自然结束。[AgentRunResult.finalText] 是**没有工具调用的最终模型轮**
  /// 的文本，可能是空串（完成但没有最终文本）。
  completed,

  /// 模型返回错误、超过工具轮上限或发生未预期异常。
  failed,

  /// 本实例的整轮被取消（父取消、切换会话、销毁等）。
  cancelled,

  /// 实例正忙：本次调用没有开始，也没有产生任何消息。
  busy,
}

/// 本实例计量在某一刻的不可变快照。结果里带一份，调用方读到的是发送结束那一刻
/// 的值，不会被之后的请求改写。
class AgentMeteringSnapshot {
  const AgentMeteringSnapshot({
    required this.inputTokens,
    required this.outputTokens,
    required this.requests,
    required this.toolCalls,
  });

  factory AgentMeteringSnapshot.of(AgentMetering metering) =>
      AgentMeteringSnapshot(
        inputTokens: metering.inputTokens,
        outputTokens: metering.outputTokens,
        requests: metering.requests,
        toolCalls: metering.toolCalls,
      );

  final int inputTokens;
  final int outputTokens;
  final int requests;
  final int toolCalls;

  int get totalTokens => inputTokens + outputTokens;

  Map<String, dynamic> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'total_tokens': totalTokens,
        'requests': requests,
        'tool_calls': toolCalls,
      };
}

/// [Agent.send] 的不可变结构化结果：四类状态 + 最终文本 + 错误 + 计量快照。
class AgentRunResult {
  const AgentRunResult._({
    required this.status,
    required this.metering,
    this.finalText,
    this.error,
  });

  /// 整轮自然结束；[finalText] 只来自没有工具调用的最终模型轮。
  const AgentRunResult.completed({
    required String finalText,
    required AgentMeteringSnapshot metering,
  }) : this._(
          status: AgentRunStatus.completed,
          metering: metering,
          finalText: finalText,
        );

  /// 失败并带可归因错误文本。
  const AgentRunResult.failed({
    required String error,
    required AgentMeteringSnapshot metering,
  }) : this._(
          status: AgentRunStatus.failed,
          metering: metering,
          error: error,
        );

  /// 整轮被取消（不携带成功结论）。
  const AgentRunResult.cancelled({
    required AgentMeteringSnapshot metering,
  }) : this._(status: AgentRunStatus.cancelled, metering: metering);

  /// 实例正忙：这次调用没有开始。
  const AgentRunResult.busy({
    required AgentMeteringSnapshot metering,
  }) : this._(status: AgentRunStatus.busy, metering: metering);

  final AgentRunStatus status;
  final AgentMeteringSnapshot metering;
  final String? finalText;
  final String? error;

  bool get isCompleted => status == AgentRunStatus.completed;
  bool get isFailed => status == AgentRunStatus.failed;
  bool get isCancelled => status == AgentRunStatus.cancelled;
  bool get isBusy => status == AgentRunStatus.busy;

  @override
  String toString() => 'AgentRunResult(${status.name}, '
      'finalText=${finalText == null ? 'null' : '"$finalText"'}, '
      'error=$error, metering=${metering.toJson()})';
}
/// 异常：实例已销毁还被要求发送。
class AgentDisposedException implements Exception {
  final String sessionId;
  const AgentDisposedException(this.sessionId);

  @override
  String toString() => 'Agent($sessionId) 已销毁：拒绝新的调用。';
}

/// 异常：实例已退役（切换模板时被替换下来），不再接受新的调用。
///
/// 退役与销毁不同：退役**不**取消在途请求、**不**释放上下文。它只是拒绝新调用，
/// 让当前整轮与后台压缩写库自然结束，同 Session 的句柄、工作区、工具输出溢出文件
/// 与序号继续留给新实例使用。
class AgentRetiredException implements Exception {
  final String sessionId;
  final String agentTypeName;
  const AgentRetiredException(this.sessionId, this.agentTypeName);

  @override
  String toString() => 'Agent($sessionId, 模板 "$agentTypeName") 已退役：'
      '不再接受新的调用（在途整轮仍会自然结束）。';
}

/// 一个真正执行模型—工具循环的 Agent 实例。
///
/// 它持有：上下文句柄、创建时冻结的 [ResolvedAgentConfig]、私有 provider 执行依赖、
/// 独立消息历史、请求 / 取消状态、计量与销毁状态。模型调用、工具执行、摘要调用以及
/// 这些调用产生的数据库写入都在这里完成；`ChatScreen` 只保留会话列表与展示职责。
///
/// **并发约定**：同一实例同一时刻只允许一轮（与原来"正在发送时忽略新发送"一致）。
/// 不同实例之间没有共享的可变列表或请求队列：消息历史各一份，句柄各自一个。
class Agent {
  final String sessionId;

  /// 会话引用的模板名（`Session.agentType`），错误消息要带它。
  final String agentTypeName;

  /// 创建时冻结的生效配置；运行中只读它，不回头读模板注册表。
  final ResolvedAgentConfig config;

  /// 创建时冻结的模板副本（摘要提供者接口仍按模板取模型等字段）。
  final AgentTypeConfig template;

  final SessionRepository sessionRepo;
  final MessageRepository messageRepo;
  final SummaryNodeRepository summaryNodeRepo;
  final ISidecar sidecar;
  final SummaryProvider summaryProvider;
  final SeamSelector? seamSelector;
  final GuardAnchors guard;
  final bool backgroundFoldEnabled;

  /// `summary_nodes` 存储是否可用（注入的仓库永远可用；生产仓库要数据库已打开）。
  final bool summaryStoreOpen;

  AgentCallbacks callbacks;

  /// provider 密钥与地址**只作为本实例的执行依赖**保存在这个私有字段里；
  /// 它不进入 [ResolvedAgentConfig] 的可序列化快照、不写日志、不显示在界面。
  final provider_model.ProviderConfig _provider;

  final List<Message> _history = [];

  /// 一次性子运行服务（add-spawn-subagent-tool）。为 null 时 `spawn_subagent`
  /// 调用显式失败，不假装执行。
  final SubagentRunner? subagentRunner;

  /// 累计计量（输入 / 输出 token、请求数、工具调用数）。
  final AgentMetering metering = AgentMetering();

  /// 正在跑的整轮 Future（模型循环、工具、写库、后台压缩写库）。
  final Set<Future<void>> _rounds = {};

  ContextSnapshot? _contextSnapshot;

  CompactionStatus _compactionStatus = CompactionStatus.idle;
  Object? _compactionOwner;

  bool _streaming = false;
  bool _disposed = false;
  bool _restored = false;
  bool _workspaceInitialized = false;

  /// 退役状态：**独立于** [_disposed]。退役中只拒绝新调用，不设 `_disposed`、
  /// 不推进 [_cancelledEpoch]、不调用 `cancelRequest` —— 在途整轮据此继续跑完。
  bool _retiring = false;
  Future<void>? _retireFuture;

  int _requestEpoch = 0;
  int _cancelledEpoch = -1;

  Timer? _foldIdleTimer;
  bool _foldInFlight = false;
  int _foldGen = 0;

  Agent({
    required this.sessionId,
    required this.agentTypeName,
    required this.config,
    required this.template,
    required provider_model.ProviderConfig provider,
    required this.sessionRepo,
    required this.messageRepo,
    required this.summaryNodeRepo,
    required this.sidecar,
    required this.summaryProvider,
    required this.seamSelector,
    required this.guard,
    required this.backgroundFoldEnabled,
    required this.summaryStoreOpen,
    this.subagentRunner,
    this.callbacks = const AgentCallbacks(),
  }) : _provider = provider;

  // ---------------------------------------------------------------------------
  // 只读状态出口
  // ---------------------------------------------------------------------------

  List<Message> get messageHistory => List<Message>.unmodifiable(_history);

  bool get isStreaming => _streaming;

  bool get isDisposed => _disposed;

  /// 是否已进入退役（旧 Agent 对象正在让位给新实例）。
  bool get isRetiring => _retiring;

  ContextSnapshot? get contextSnapshot => _contextSnapshot;

  CompactionStatus get compactionStatus => _compactionStatus;

  bool get isFolding => _foldInFlight;

  bool get workspaceInitialized => _workspaceInitialized;

  /// 当前工具目录里本实例真正会发送的工具定义。
  List<Map<String, dynamic>> get toolDefinitions => ToolCatalog.instance
      .resolve(config.tools, context: '模板 "$agentTypeName"');

  /// 这个实例能不能接收图片输入（来自它自己的生效配置，不读注册表）。
  bool get acceptsImages => config.acceptsImages;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 确保该会话的上下文存在；只有 `created == true` 时才设置缺省工作区。
  ///
  /// [defaultWorkspace] 缺省是应用主目录；一次性子运行创建时传入父上下文实际
  /// 保存的工作区，避免把"父子工作区相同"建立在主目录这个默认值上。
  Future<bool> ensureContext({String? defaultWorkspace}) async {
    if (_disposed) throw AgentDisposedException(sessionId);
    if (_retiring) throw AgentRetiredException(sessionId, agentTypeName);
    final created = await sidecar.ensureContext(sessionId,
        defaultWorkspace: defaultWorkspace ?? ConfigService.homeDir);
    if (created) _workspaceInitialized = true;
    return created;
  }

  /// 从数据库恢复消息历史（新建实例与恢复既有会话都走这里）。
  Future<void> restore() async {
    if (_disposed) throw AgentDisposedException(sessionId);
    if (_retiring) throw AgentRetiredException(sessionId, agentTypeName);
    final messages = await messageRepo.queryBySession(sessionId);
    _history
      ..clear()
      ..addAll(messages);
    _restored = true;
  }

  void _registerRound(Future<void> round) {
    _rounds.add(round);
    round.then((_) {}, onError: (_) {}).whenComplete(() => _rounds.remove(round));
  }

  /// 等待本实例所有整轮 Future（含后台压缩写库）结束。
  Future<void> waitForRounds() async {
    while (_rounds.isNotEmpty) {
      final snapshot = List<Future<void>>.from(_rounds);
      try {
        await Future.wait(snapshot, eagerError: false);
      } catch (_) {
        // 单轮失败不影响销毁；循环重新快照剩余的 Future。
      }
    }
  }

  /// 停止新调用并取消在途请求；**不**释放上下文（[dispose] 才做）。
  ///
  /// 先取消本实例正在运行的活动子 Agent，再取消自己的请求：父不留下仍在跑的子树。
  void cancel() {
    subagentRunner?.cancelChildrenOf(sessionId);
    _cancelledEpoch = _requestEpoch;
    _foldGen++;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = null;
    sidecar.cancelRequest(sessionId);
    if (_streaming) _endStreaming();
  }

  /// 销毁：先停新调用、等整轮 Future 与后台压缩写库，再 `disposeContext`
  /// 排空桥内队列与 C++ 在途调用，最后标记释放。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // 父销毁先取消活动子 Agent，再等子整轮与清理随父整轮一起结清。
    subagentRunner?.cancelChildrenOf(sessionId);
    _foldGen++;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = null;
    _cancelledEpoch = _requestEpoch;
    try {
      sidecar.cancelRequest(sessionId);
    } catch (_) {}
    await waitForRounds();
    await sidecar.disposeContext(sessionId);
  }

  /// 退役：把实例让位给同一 Session 的新 Agent 对象。
  ///
  /// 只做三件事：① 设退役状态，拒绝**新的** [send] / [ensureContext] / [restore]；
  /// ② 取消**尚未开始**的后台空闲折叠计时器（它还没开始，不取消的话会在旧对象
  /// 退役后凭空跑一轮压缩）；③ 等本实例所有在途整轮与后台压缩写库**自然结束**。
  ///
  /// 明确**不**做：不调用 `cancelRequest`、不调用 `disposeContext`、不设
  /// [_disposed]、不推进 [_cancelledEpoch]。所以在途模型请求、工具、消息写库与
  /// 后台压缩写库都按原来的路径跑完；同一 Session 的上下文句柄、工作区、浏览器
  /// 上下文、工具输出溢出目录与序号全部保留给新实例。
  Future<void> retire() {
    final running = _retireFuture;
    if (running != null) return running;
    final future = _retire();
    _retireFuture = future;
    return future;
  }

  Future<void> _retire() async {
    if (_disposed) return;
    _retiring = true;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = null;
    await waitForRounds();
  }

  /// 等待在途的退役动作结束（没有退役时立即返回）。
  Future<void> waitForRetirement() => _retireFuture ?? Future<void>.value();

  // ---------------------------------------------------------------------------
  // 发送
  // ---------------------------------------------------------------------------

  /// 发送一条用户消息并跑完整轮（模型循环 → 工具 → 写库 → 可选的空闲后台压缩）。
  ///
  /// 返回不可变 [AgentRunResult]：界面可以忽略它（消息、流式事件与错误展示照旧），
  /// 子 Agent 运行器据此区分成功、失败、取消与实例正忙。
  Future<AgentRunResult> send(String text,
      {List<String> attachments = const []}) async {
    if (_disposed) throw AgentDisposedException(sessionId);
    if (_retiring) throw AgentRetiredException(sessionId, agentTypeName);
    if (_streaming) {
      // 实例正忙：这次调用没有开始，也没有产生任何消息。
      return AgentRunResult.busy(metering: _meteringSnapshot());
    }
    // 用户这一轮优先：抢占任何已排期或正在跑的后台压缩（原 `_sendMessage` 的
    // preempt 路径）。bump 代次让折叠里的 isAborted 立刻成立，取消只打本实例
    // 自己的句柄，排期中的空闲定时器也清掉。
    if (_foldInFlight || _foldIdleTimer != null) {
      _foldGen++;
      sidecar.cancelRequest(sessionId);
      _foldIdleTimer?.cancel();
      _foldIdleTimer = null;
    }
    if (!_restored) await restore();
    final round = _sendMessageRound(text: text, attachments: attachments);
    _registerRound(round);
    return await round;
  }

  Future<AgentRunResult> _sendMessageRound({
    required String text,
    required List<String> attachments,
  }) async {
    final epoch = ++_requestEpoch;
    final userMsg = await messageRepo.insert(
      sessionId: sessionId,
      role: 'user',
      content: text,
      attachments: attachments,
    );
    await sessionRepo.touch(sessionId);
    _history.add(userMsg);
    callbacks.onUserMessage?.call(userMsg);
    _setStreaming(true);

    final titleUpdated = await sessionRepo.updateTitleIfDefault(sessionId, text);
    if (titleUpdated) {
      final session = await sessionRepo.get(sessionId);
      callbacks.onTitleChanged?.call(session?.title ?? 'New Chat');
    }

    final snapshotMessages = List<Message>.from(_history);
    try {
      return await _callModel(messages: snapshotMessages, epoch: epoch);
    } catch (e, st) {
      // 未预期异常（例如写库失败）不许把流式标记永远留在 true，也不许当成空成功；
      // 这里不额外写一条错误消息（界面路径原本也不写，避免同一错误重复写库）。
      debugPrint('[AliasAgent] _callModel error: $e\n$st');
      if (_isActive(epoch)) _endStreaming();
      return AgentRunResult.failed(
        error: '未预期异常：$e',
        metering: _meteringSnapshot(),
      );
    }
  }

  bool _isActive(int epoch) => !_disposed && _cancelledEpoch < epoch;

  /// 本实例当前的计量快照（结果里用不可变副本，不带可变引用出去）。
  AgentMeteringSnapshot _meteringSnapshot() =>
      AgentMeteringSnapshot.of(metering);

  AgentRunResult _cancelledRun() =>
      AgentRunResult.cancelled(metering: _meteringSnapshot());

  AgentRunResult _failedRun(String error) =>
      AgentRunResult.failed(error: error, metering: _meteringSnapshot());

  void _setStreaming(bool value) {
    if (_streaming == value) return;
    _streaming = value;
    callbacks.onStreamingChanged?.call(value);
  }

  // ---------------------------------------------------------------------------
  // 模型调用与工具循环（原 `lib/main.dart` 的 `_callModel`）
  // ---------------------------------------------------------------------------

  Future<AgentRunResult> _callModel({
    required List<Message> messages,
    required int epoch,
  }) async {
    final baseUrl = _provider.baseUrl.isNotEmpty
        ? _provider.baseUrl
        : 'https://api.anthropic.com';

    // 实际发送的工具定义 = 本实例生效配置 ∩ 工具目录；未知名字在这里显式失败（
    // 创建路径已经校验过一次，这里保持同一判据，避免绕过目录）。
    final toolsJson = jsonEncode(toolDefinitions);

    final maxContextTokens = config.maxContextTokens;
    final List<Map<String, dynamic>> apiMessages;
    List<ProjectionPiece> projectionTimeline = const [];
    if (maxContextTokens > 0) {
      final loaded = await _loadClosedSegments(messages);
      final waitPercent = config.compactionWaitThresholdPercent;
      final shareTokens = CompactionEngine.estimatedProjectionTokens(
        summaryMeasuredTokens: loaded.projected.map((c) => c.tokenCost),
        rawTail: [
          for (final m in messages)
            if ((m.seq ?? 0) > loaded.coveredThrough) m,
        ],
      );
      final waitForCompaction = CompactionEngine.exceedsWaitBound(
        projectedTokens: shareTokens,
        maxContextTokens: maxContextTokens,
        waitPercent: waitPercent,
      );
      debugPrint('[AliasAgent] 压缩等待门槛：不压就发的投影≈$shareTokens token / '
          '模型容量 $maxContextTokens（等待上界 '
          '${CompactionEngine.waitBoundTokens(maxContextTokens, waitPercent)}，'
          '$waitPercent%）⇒ ${waitForCompaction ? "这一轮等它压完再发" : "不等：照原文发，压缩留给空闲后台"}');
      final seamChooser = waitForCompaction
          ? await _prepareSeamChooser(messages, loaded.projected,
              coverageFloorSeq: loaded.coveredThrough)
          : null;
      final planned = CompactionEngine.buildTree(
        history: messages,
        maxContextTokens: maxContextTokens,
        closed: loaded.projected,
        coverageFloorSeq: loaded.coveredThrough,
        seamChooser: seamChooser,
        thresholdPercent: config.compactionThresholdPercent,
      );
      final plan = waitForCompaction
          ? planned
          : CompactionEngine.projectionWithoutNewSummaries(planned);
      if (plan.shouldCompact) {
        ({List<ProjectionPiece> timeline, List<SummaryResult> summaries})
            resolved = (timeline: const [], summaries: const []);
        try {
          resolved = await _resolveSummaries(plan,
              history: messages, generate: waitForCompaction);
        } catch (e) {
          debugPrint('[AliasAgent] compaction summary failed, sending verbatim: $e');
          resolved = (timeline: const [], summaries: const []);
        }
        if (resolved.timeline.isEmpty) {
          debugPrint('[AliasAgent] compaction produced no projection (far fully '
              'omit-worthy, no verbatim tail) — resending the full over-budget '
              'conversation (known pathological limit)');
          apiMessages = _buildApiMessages(messages);
        } else {
          apiMessages = _buildCompactionProjection(resolved.timeline);
          projectionTimeline = resolved.timeline;
        }
      } else {
        apiMessages = _buildApiMessages(messages);
      }
    } else {
      apiMessages = _buildApiMessages(messages);
    }

    final allTurnToolCalls = <Map<String, dynamic>>[];
    final projectionMessageCount = apiMessages.length;

    var turn = 0;
    while (true) {
      if (!_isActive(epoch)) return _cancelledRun();
      final messagesJson = jsonEncode(apiMessages);

      var turnText = '';
      final turnToolCalls = <Map<String, dynamic>>[];
      final turnThinkingBlocks = <Map<String, dynamic>>[];
      var doneCode = 0;
      String? doneError;
      var lastInputTokens = 0;
      var lastOutputTokens = 0;

      final thinkingMode = config.thinkingMode;
      final thinkingEffort = config.thinkingEffort;
      final systemPrompt =
          '${config.systemPrompt}\n${guard.inject()}\nCurrent date: ${DateTime.now().toIso8601String().substring(0, 10)}. For precise time-sensitive queries, use the get_current_time tool.';

      // 快照与拆分在同一次赋值里落定：两者描述同一份请求。
      final fixedOverheadTokens =
          ContextEstimator.estimateTokens(systemPrompt) +
              ContextEstimator.estimateTokens(toolsJson);
      final trailingRawMessages = apiMessages.sublist(projectionMessageCount);
      final breakdown = maxContextTokens <= 0
          ? null
          : projectionTimeline.isEmpty
              ? ContextBreakdown.verbatim(
                  messages: messages,
                  windowTokens: maxContextTokens,
                  fixedOverheadTokens: fixedOverheadTokens,
                  trailingRawMessages: trailingRawMessages,
                )
              : ContextBreakdown.fromTimeline(
                  timeline: projectionTimeline,
                  windowTokens: maxContextTokens,
                  fixedOverheadTokens: fixedOverheadTokens,
                  trailingRawMessages: trailingRawMessages,
                );
      final snapshot = ContextSnapshot(
        sessionId: sessionId,
        systemPrompt: systemPrompt,
        messages: (jsonDecode(messagesJson) as List<dynamic>)
            .cast<Map<String, dynamic>>(),
        toolsJson: toolsJson,
        model: config.model,
        thinkingMode: thinkingMode,
        thinkingEffort: thinkingEffort,
        capturedAt: DateTime.now(),
        windowTokens: maxContextTokens,
        agentType: agentTypeName,
        breakdown: breakdown,
      );
      _contextSnapshot = snapshot;
      callbacks.onSnapshot?.call(snapshot);

      metering.requests++;
      callbacks.onMeteringChanged?.call();

      await sidecar.sendMessage(
        handle: sessionId,
        apiKey: _provider.apiKey,
        baseUrl: baseUrl,
        model: config.model,
        systemPrompt: systemPrompt,
        messagesJson: messagesJson,
        toolsJson: toolsJson,
        thinkingMode: thinkingMode,
        thinkingEffort: thinkingEffort,
        onChunk: (text) {
          turnText += text;
          if (_isActive(epoch)) callbacks.onChunk?.call(text);
        },
        onToolCall: (json) {
          try {
            final tc = jsonDecode(json) as Map<String, dynamic>;
            tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}';
            turnToolCalls.add(tc);
            metering.toolCalls++;
            callbacks.onMeteringChanged?.call();
            if (_isActive(epoch)) {
              callbacks.onToolCall?.call(ToolCallActivity(
                id: tc['id'] as String,
                toolName: (tc['name'] as String?) ?? 'unknown',
                input: (tc['input'] as Map<String, dynamic>?) ?? {},
              ));
            }
          } catch (e) {
            debugPrint('[AliasAgent] onToolCall parse error: $e\nraw: $json');
          }
        },
        onThinking: (json) {
          try {
            final th = jsonDecode(json) as Map<String, dynamic>;
            final type = th['type'] as String?;
            final idx = (th['index'] as num?)?.toInt() ?? 0;
            if (type == 'thinking_delta') {
              final delta = (th['delta'] as String?) ?? '';
              if (_isActive(epoch)) callbacks.onThinkingDelta?.call(idx, delta);
            } else if (type == 'thinking') {
              turnThinkingBlocks.add(_thinkingBlockWithoutIndex(th));
              if (_isActive(epoch)) {
                callbacks.onThinkingBlock?.call(idx,
                    (th['thinking'] as String?) ?? '', th['signature'] as String?);
              }
            } else {
              debugPrint('[AliasAgent] onThinking: unknown event type: $type');
            }
          } catch (e) {
            debugPrint('[AliasAgent] onThinking parse error: $e\nraw: $json');
          }
        },
        onDone: (code, error, stopReason, int? inputTokens, int? outputTokens) {
          doneCode = code;
          doneError = error;
          lastInputTokens = inputTokens ?? 0;
          lastOutputTokens = outputTokens ?? 0;
        },
      );

      if (doneCode != 0) {
        final switchCancelled = !_isActive(epoch) || doneError == 'cancelled';
        if (!switchCancelled) _endStreaming();
        if (switchCancelled) return _cancelledRun();
        final error = doneError ?? 'Unknown error';
        await _storeError(error);
        return _failedRun(error);
      }

      if (!_isActive(epoch)) {
        _endStreaming();
        return _cancelledRun();
      }

      // 这一次模型请求结束了（工具轮后面还会再发一次）：让界面把这一轮的流式
      // 文本与"正在思考"收尾，但整轮的流式标记保持不变（与旧路径同一时序）。
      callbacks.onTurnCompleted?.call();

      final thinkingJsonStr = turnThinkingBlocks.isNotEmpty
          ? jsonEncode(turnThinkingBlocks)
          : null;

      metering.inputTokens += lastInputTokens;
      metering.outputTokens += lastOutputTokens;
      callbacks.onMeteringChanged?.call();

      // 没有工具调用 ⇒ 最终回复，落库并结束这一轮。只有这一条分支能产生成功
      // 结果的文本；中间工具轮的文本绝不作为最终结论。
      if (turnToolCalls.isEmpty) {
        if (turnText.isNotEmpty) {
          final toolCallsJson = allTurnToolCalls.isNotEmpty
              ? jsonEncode(allTurnToolCalls)
              : null;
          final assistantMsg = await messageRepo.insert(
            sessionId: sessionId,
            role: 'assistant',
            content: turnText,
            toolCallsJson: toolCallsJson,
            thinkingJson: thinkingJsonStr,
            tokenCount: lastInputTokens,
            outputTokenCount: lastOutputTokens,
          );
          await sessionRepo.touch(sessionId);
          _history.add(assistantMsg);
          callbacks.onAssistantMessage?.call(assistantMsg, true);
        }
        if (!_isActive(epoch)) return _cancelledRun();
        _endStreaming();
        _maybeScheduleBackgroundFold();
        return AgentRunResult.completed(
          finalText: turnText,
          metering: _meteringSnapshot(),
        );
      }

      // 有工具调用 ⇒ 先把中间 assistant 消息落库（工具调用记录在工具执行后补写）。
      if (!_isActive(epoch)) return _cancelledRun();
      allTurnToolCalls.addAll(turnToolCalls);
      final turnJson = jsonEncode(turnToolCalls);
      final intermediateMsg = await messageRepo.insert(
        sessionId: sessionId,
        role: 'assistant',
        content: turnText,
        toolCallsJson: turnJson,
        thinkingJson: thinkingJsonStr,
        tokenCount: lastInputTokens,
        outputTokenCount: lastOutputTokens,
      );
      await sessionRepo.touch(sessionId);
      _history.add(intermediateMsg);
      callbacks.onAssistantMessage?.call(intermediateMsg, false);

      final assistantBlocks = <Map<String, dynamic>>[];
      assistantBlocks.addAll(turnThinkingBlocks);
      if (turnText.isNotEmpty) {
        assistantBlocks.add({'type': 'text', 'text': turnText});
      }
      for (final tc in turnToolCalls) {
        assistantBlocks.add({
          'type': tc['type'] ?? 'tool_use',
          'id': tc['id'] ?? '',
          'name': tc['name'] ?? '',
          'input': tc['input'] ?? <String, dynamic>{},
        });
      }
      apiMessages.add({'role': 'assistant', 'content': assistantBlocks});

      final toolResults = <Map<String, dynamic>>[];
      for (final tc in turnToolCalls) {
        if (!_isActive(epoch)) break;
        final result = await _executeTool(tc);
        final resultContent = result['ok'] == true
            ? (result['content'] as String? ?? '')
            : (result['error'] as String? ?? 'Tool failed');

        final toolId = (tc['id'] as String?) ?? '';
        final toolName2 = (tc['name'] as String?) ?? '';
        final isSearchTool =
            toolName2 == 'web_search' || toolName2 == 'web_fetch';
        final activity = ToolCallActivity(
          id: toolId,
          toolName: toolName2,
          input: (tc['input'] as Map<String, dynamic>?) ?? {},
          status:
              result['ok'] == true ? ToolCallStatus.done : ToolCallStatus.error,
          result: resultContent,
          resultPreview: resultContent.length > 300
              ? '${resultContent.substring(0, 300)}...'
              : resultContent,
          resultSections:
              isSearchTool ? _buildResultSections(toolName2, result) : null,
          hunks: parseEditHunks(result['hunks']),
          hunksOmitted: result['hunks_omitted'] as String?,
          imagePath: _toolImagePath(result),
          // 子运行元数据（只有 spawn_subagent 会带；不含密钥，也不进入父模型内容）。
          childSessionId: result['child_session_id'] as String?,
          childAgentType: result['agent_type'] as String?,
          childModel: result['model'] as String?,
          childMetering: result['metering'] is Map
              ? Map<String, dynamic>.from(result['metering'] as Map)
              : null,
        );
        if (_isActive(epoch)) callbacks.onToolResult?.call(activity);

        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': tc['id'] ?? '',
          'content': _toolResultContent(
            text: resultContent,
            imagePath: _toolImagePath(result),
          ),
        });

        // 工具结果只写进这一轮的 toolCallsJson（DB）与下面的请求体。
        for (var i = 0; i < turnToolCalls.length; i++) {
          if (turnToolCalls[i]['id'] == toolId) {
            turnToolCalls[i].addAll(activity.toJson());
            break;
          }
        }
      }

      // 工具轮写库：整轮写库归属本实例，不读界面当前会话 id。
      final enrichedJson = jsonEncode(turnToolCalls);
      await messageRepo.updateToolCalls(intermediateMsg.id, enrichedJson);
      _replaceHistoryMessage(intermediateMsg.id, enrichedJson);
      if (DatabaseService.isOpen) {
        try {
          final dirtySeq = intermediateMsg.seq;
          if (dirtySeq != null) {
            await summaryNodeRepo.markDirty(sessionId, dirtySeq);
          }
        } catch (e) {
          debugPrint('[AliasAgent] mark dirty watermark failed: $e');
        }
      }

      apiMessages.add({'role': 'user', 'content': toolResults});

      turnText = '';
      turnToolCalls.clear();
      turnThinkingBlocks.clear();
      if (turn >= 50) {
        debugPrint('[AliasAgent] Max tool turns (50) exceeded — aborting');
        if (_isActive(epoch)) {
          _endStreaming();
          _maybeScheduleBackgroundFold();
        }
        await sessionRepo.touch(sessionId);
        // 上限已到却没有最终结论：这是失败，不是"完成但文本为空"。
        return _failedRun('超过最大工具轮次（50），本轮没有最终结论');
      }
      turn++;
    }
  }

  void _replaceHistoryMessage(String id, String toolCallsJson) {
    final index = _history.indexWhere((m) => m.id == id);
    if (index < 0) return;
    final old = _history[index];
    _history[index] = Message(
      id: old.id,
      seq: old.seq,
      sessionId: old.sessionId,
      role: old.role,
      content: old.content,
      toolCallsJson: toolCallsJson,
      thinkingJson: old.thinkingJson,
      tokenCount: old.tokenCount,
      outputTokenCount: old.outputTokenCount,
      createdAt: old.createdAt,
      attachments: old.attachments,
    );
  }

  /// Strip the internal `index` key from a thinking block before persisting
  /// or replaying it to the API.
  static Map<String, dynamic> _thinkingBlockWithoutIndex(
      Map<String, dynamic> th) {
    if (!th.containsKey('index')) return th;
    final cleaned = Map<String, dynamic>.from(th)..remove('index');
    return cleaned;
  }

  // ---------------------------------------------------------------------------
  // 压缩状态
  // ---------------------------------------------------------------------------

  void _setCompactionStatus(CompactionStatus status, {Object? owner}) {
    if (_disposed) return;
    if (owner != null) _compactionOwner = owner;
    _compactionStatus = status;
    callbacks.onCompactionStatusChanged?.call();
  }

  void _clearCompactionStatus({Object? owner}) {
    if (_disposed) return;
    if (owner != null &&
        _compactionOwner != null &&
        !identical(_compactionOwner, owner)) {
      return;
    }
    _compactionOwner = null;
    _compactionStatus = CompactionStatus.idle;
    callbacks.onCompactionStatusChanged?.call();
  }

  // ---------------------------------------------------------------------------
  // 后台空闲压缩
  // ---------------------------------------------------------------------------

  void _maybeScheduleBackgroundFold() {
    if (!backgroundFoldEnabled) return;
    if (_retiring || _disposed) return;
    if (_streaming || _foldInFlight) return;
    if (config.maxContextTokens <= 0) return;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = Timer(const Duration(seconds: 2), () {
      _foldIdleTimer = null;
      if (!_disposed && !_retiring && !_streaming && !_foldInFlight) {
        _registerRound(_runBackgroundFold());
      }
    });
  }

  Future<void> _runBackgroundFold() async {
    if (_foldInFlight || _disposed || _retiring) return;
    _foldInFlight = true;
    final myGen = _foldGen;
    try {
      final messages = await messageRepo.queryBySession(sessionId);
      if (messages.isEmpty) return;
      final loaded = await _loadClosedSegments(messages);
      final topClosedMax =
          loaded.coveredThrough < 0 ? 0 : loaded.coveredThrough;
      final seamChooser = await _prepareSeamChooser(
          messages, loaded.projected,
          coverageFloorSeq: loaded.coveredThrough,
          isAborted: () => _foldGen != myGen,
          background: true);
      final plan = CompactionEngine.buildTree(
        history: messages,
        maxContextTokens: config.maxContextTokens,
        closed: loaded.projected,
        coverageFloorSeq: loaded.coveredThrough,
        seamChooser: seamChooser,
        thresholdPercent: config.compactionThresholdPercent,
      );
      if (!plan.shouldCompact) {
        debugPrint('[AliasAgent] background fold: nothing to fold — the '
            'accumulated content has not passed the threshold yet '
            '(top closed seq=$topClosedMax) -> no-op');
        return;
      }
      final resolved = await _resolveSummaries(
        plan,
        history: messages,
        isAborted: () => _foldGen != myGen,
        background: true,
      );
      debugPrint('[AliasAgent] background fold: folded '
          '${resolved.summaries.length} summary segment(s) for session $sessionId, '
          'top closed seq=$topClosedMax');
    } catch (e) {
      debugPrint('[AliasAgent] background fold aborted for session $sessionId: $e');
    } finally {
      _foldInFlight = false;
    }
  }

  Future<({List<ClosedSummary> projected, int coveredThrough})>
      _loadClosedSegments(List<Message> history) async {
    if (!summaryStoreOpen) {
      return (projected: const <ClosedSummary>[], coveredThrough: -1);
    }
    try {
      final nodes = await summaryNodeRepo.queryBySession(sessionId);
      final candidates = nodes
          .where((n) =>
              n.level >= 1 && n.summaryJson != null && n.coveredMinSeq > 0)
          .toList();
      if (candidates.isEmpty) {
        return (projected: const <ClosedSummary>[], coveredThrough: -1);
      }
      final coveredThrough =
          candidates.map((n) => n.coveredMaxSeq).reduce((a, b) => a > b ? a : b);
      final t = CompactionEngine.thresholdTokens(
          config.maxContextTokens, config.compactionThresholdPercent);
      final distances = CompactionEngine.distancesFromNewest(history);
      final sorted = List.of(candidates)
        ..sort((a, b) {
          final c = a.coveredMinSeq - b.coveredMinSeq;
          if (c != 0) return c;
          final d = b.coveredMaxSeq - a.coveredMaxSeq;
          if (d != 0) return d;
          return b.level - a.level;
        });
      final picked = <ClosedSummary>[];
      var lastMax = 0;
      for (final n in sorted) {
        if (n.coveredMinSeq <= lastMax) continue;
        final span = CompactionEngine.spanIndices(
            history, n.coveredMinSeq, n.coveredMaxSeq);
        final farEnough = span != null &&
            CompactionEngine.substitutesSpan(
              distanceAtOldest: distances[span.oldest],
              distanceAtNewest: distances[span.newest],
              level: n.level,
              t: t,
            );
        if (!farEnough && n.level >= 2) continue;
        picked.add(ClosedSummary(
          level: n.level,
          coveredMinSeq: n.coveredMinSeq,
          coveredMaxSeq: n.coveredMaxSeq,
          tokenCost: n.tokenCost ?? 0,
        ));
        lastMax = n.coveredMaxSeq;
      }
      return (projected: picked, coveredThrough: coveredThrough);
    } catch (e) {
      debugPrint('[AliasAgent] closed segments load failed: $e');
      return (projected: const <ClosedSummary>[], coveredThrough: -1);
    }
  }

  Future<L1SeamChooser?> _prepareSeamChooser(
      List<Message> history, List<ClosedSummary> closed,
      {int? coverageFloorSeq,
      bool Function()? isAborted,
      bool background = false}) async {
    if (seamSelector == null) return null;
    final seamInputs = CompactionEngine.resolveFoldSeamInputs(
        history: history,
        maxContextTokens: config.maxContextTokens,
        closed: closed,
        coverageFloorSeq: coverageFloorSeq,
        thresholdPercent: config.compactionThresholdPercent);
    if (seamInputs == null) return null;
    final seamSel = seamSelector!;
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled(
          'background fold aborted before seam selection');
    }
    final seamOwner = Object();
    final coldSeam =
        seamSel.memoizedSeams(far: seamInputs.far, k: seamInputs.k) == null;
    if (coldSeam) {
      _setCompactionStatus(CompactionStatus.seam(background: background),
          owner: seamOwner);
    }
    try {
      await seamSel.ensure(
          far: seamInputs.far, k: seamInputs.k, config: template,
          sessionId: sessionId);
      return (far, k) => seamSel.memoizedSeams(far: far, k: k) ?? const [];
    } catch (e) {
      debugPrint('[AliasAgent] seam selection failed, using arithmetic skeleton: $e');
      return null;
    } finally {
      if (coldSeam) _clearCompactionStatus(owner: seamOwner);
    }
  }

  Future<String> _l1SummaryText(
      bool dbOpen, int dirtySince, List<Message> msgs,
      {bool Function()? isAborted}) async {
    if (msgs.isEmpty) return '';
    final minSeq = msgs.first.seq;
    final maxSeq = msgs.last.seq;
    if (dbOpen && minSeq != null && maxSeq != null) {
      try {
        final node = await summaryNodeRepo.findCovering(sessionId, minSeq, maxSeq,
            level: 1);
        if (node != null &&
            node.summaryJson != null &&
            (dirtySince == 0 || node.coveredMaxSeq < dirtySince)) {
          final t = _summaryTextFromJson(node.summaryJson!);
          if (t.isNotEmpty) return t;
        }
      } catch (e) {
        debugPrint('[AliasAgent] L1 sub-span reuse failed: $e');
      }
    }
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled(
          'background fold aborted during L1 sub-span');
    }
    final s = await summaryProvider.summarize(
        folded: msgs, config: template, sessionId: sessionId);
    if (dbOpen && minSeq != null && maxSeq != null) {
      try {
        await summaryNodeRepo.materialize(
          sessionId: sessionId,
          level: 1,
          startSeq: minSeq,
          endSeq: maxSeq,
          nodeType: 'summary',
          summaryJson: jsonEncode({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': s.text},
            ],
          }),
          tokenCost: s.tokens,
          summaryPromptVersion: 1,
          model: config.model,
          coveredMinSeq: minSeq,
          coveredMaxSeq: maxSeq,
        );
      } catch (e) {
        debugPrint('[AliasAgent] L1 sub-span persist failed: $e');
      }
    }
    return s.text;
  }

  Future<List<({CompactionSegment seg, String text, int tokens, bool isClosed})>>
      _resolveOpenLevel1(List<Message> msgs,
          {bool Function()? isAborted,
          void Function(int minSeq, int maxSeq)? onNotResummarized,
          List<SummaryReference> reference = const []}) async {
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled(
          'background fold aborted during open-batch resolve');
    }
    if (msgs.isEmpty) return const [];
    final raw = CompactionEngine.rawTokens(msgs);
    final summary = await summaryProvider.summarize(
        folded: msgs, config: template,
        reference: reference, sessionId: sessionId);
    if (CompactionEngine.summarySideWins(raw, summary.tokens)) {
      return [
        (seg: CompactionSegment(messages: msgs, summary: true, level: 1),
            text: summary.text, tokens: summary.tokens, isClosed: false),
      ];
    }
    if (onNotResummarized != null && msgs.isNotEmpty) {
      onNotResummarized(msgs.first.seq ?? 0, msgs.last.seq ?? 0);
    }
    return [
      (
        seg: CompactionSegment(
            messages: msgs, summary: true, level: 1, verbatimAtLevel: true),
        text: msgs
            .map((m) => m.content)
            .where((c) => c.isNotEmpty)
            .join('\n\n'),
        tokens: raw,
        isClosed: false,
      ),
    ];
  }

  Future<({List<ProjectionPiece> timeline, List<SummaryResult> summaries})>
      _resolveSummaries(CompactionPlan plan,
          {required List<Message> history,
          bool Function()? isAborted,
          bool background = false,
          bool generate = true}) async {
    final statusOwner = Object();
    try {
      return await _resolveSummariesInner(plan,
          history: history,
          isAborted: isAborted,
          background: background,
          generate: generate,
          statusOwner: statusOwner);
    } finally {
      _clearCompactionStatus(owner: statusOwner);
    }
  }

  Future<({List<ProjectionPiece> timeline, List<SummaryResult> summaries})>
      _resolveSummariesInner(CompactionPlan plan,
          {required List<Message> history,
          bool Function()? isAborted,
          bool background = false,
          bool generate = true,
          Object? statusOwner}) async {
    final dbOpen = summaryStoreOpen;
    var dirtySince = 0;
    if (dbOpen) {
      try {
        dirtySince = await summaryNodeRepo.dirtySinceSeq(sessionId);
      } catch (e) {
        debugPrint('[AliasAgent] dirty watermark read failed: $e');
      }
    }
    var persistFailed = false;

    final entries =
        <({CompactionSegment seg, String text, int tokens, bool isClosed})>[];
    final summarySegTotal = plan.segments
        .where((s) => s.summary && s.messages.isNotEmpty && s.reuse == null)
        .length;
    var summarySegNo = 0;
    final referenceCandidates = await _loadReferenceCandidates(dbOpen);
    for (final seg in plan.segments) {
      if (isAborted?.call() ?? false) {
        throw const _BackgroundFoldCancelled(
            'background fold aborted between segments');
      }
      if (!seg.summary || seg.messages.isEmpty) continue;
      if (seg.reuse == null) {
        summarySegNo++;
        _setCompactionStatus(
            CompactionStatus.level1(
                segment: summarySegNo,
                total: summarySegTotal,
                background: background),
            owner: statusOwner);
      }
      final minSeq = seg.messages.first.seq;
      final maxSeq = seg.messages.last.seq;

      if (seg.reuse != null) {
        if (!dbOpen) {
          throw StateError('closed segment ${seg.reuse!.coveredMinSeq}..'
              '${seg.reuse!.coveredMaxSeq} cache lookup requires an open DB');
        }
        final node = await summaryNodeRepo.findCovering(sessionId,
            seg.reuse!.coveredMinSeq, seg.reuse!.coveredMaxSeq,
            level: seg.reuse!.level);
        if (node == null || node.summaryJson == null) {
          throw StateError('closed segment ${seg.reuse!.coveredMinSeq}..'
              '${seg.reuse!.coveredMaxSeq} has no persisted summary — cannot re-summarize an immutable segment');
        }
        final text = _summaryTextFromJson(node.summaryJson!);
        if (text.isEmpty) {
          throw StateError('closed segment ${seg.reuse!.coveredMinSeq}..'
              '${seg.reuse!.coveredMaxSeq} persisted summary is empty');
        }
        entries
            .add((seg: seg, text: text, tokens: node.tokenCost ?? 0, isClosed: true));
        continue;
      }
      if (dbOpen && minSeq != null && maxSeq != null) {
        try {
          final node = await summaryNodeRepo.findCovering(
              sessionId, minSeq, maxSeq,
              level: seg.level);
          if (node != null &&
              node.summaryJson != null &&
              (dirtySince == 0 || node.coveredMaxSeq < dirtySince)) {
            final text = _summaryTextFromJson(node.summaryJson!);
            if (text.isNotEmpty) {
              entries.add((
                seg: seg,
                text: text,
                tokens: node.tokenCost ?? 0,
                isClosed: false
              ));
              continue;
            }
          }
        } catch (e) {
          debugPrint('[AliasAgent] summary reuse read failed: $e');
        }
      }

      if (seg.level == 2 &&
          seg.l2SubSpans != null &&
          seg.l2SubSpans!.isNotEmpty) {
        final l1Texts = <String>[];
        for (final span in seg.l2SubSpans!) {
          final lo = span[0];
          final hi = span[1];
          final l1Msgs = seg.messages
              .where((m) {
                final s = m.seq ?? 0;
                return s >= lo && s <= hi;
              })
              .toList();
          if (l1Msgs.isEmpty) continue;
          l1Texts.add(await _l1SummaryText(dbOpen, dirtySince, l1Msgs,
              isAborted: isAborted));
        }
        final summary = await summaryProvider.summarizeText(
            text: l1Texts.join('\n\n'), config: template,
            sessionId: sessionId);
        if (dbOpen && minSeq != null && maxSeq != null) {
          debugPrint('[AliasAgent] folding ${seg.messages.length} messages '
              '(seq $minSeq..$maxSeq) into a level-${seg.level} summary');
          try {
            await summaryNodeRepo.materialize(
              sessionId: sessionId,
              level: seg.level,
              startSeq: minSeq,
              endSeq: maxSeq,
              nodeType: 'summary',
              summaryJson: jsonEncode({
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': summary.text},
                ],
              }),
              tokenCost: summary.tokens,
              summaryPromptVersion: 1,
              model: config.model,
              coveredMinSeq: minSeq,
              coveredMaxSeq: maxSeq,
            );
          } catch (e) {
            persistFailed = true;
            debugPrint('[AliasAgent] persist summary failed: $e');
          }
        }
        entries.add(
            (seg: seg, text: summary.text, tokens: summary.tokens, isClosed: false));
        continue;
      }

      final leafEntries = await _resolveOpenLevel1(seg.messages,
          isAborted: isAborted,
          reference: selectSummaryReferences(
              persisted: referenceCandidates, batchOldestSeq: minSeq ?? 0),
          onNotResummarized: (minSeq, maxSeq) {
            if (dirtySince > 0 && maxSeq >= dirtySince) persistFailed = true;
          });
      for (final leaf in leafEntries) {
        if (dbOpen &&
            !leaf.seg.verbatimAtLevel &&
            leaf.seg.messages.isNotEmpty &&
            leaf.seg.messages.first.seq != null &&
            leaf.seg.messages.last.seq != null) {
          final lo = leaf.seg.messages.first.seq!;
          final hi = leaf.seg.messages.last.seq!;
          debugPrint('[AliasAgent] folding ${leaf.seg.messages.length} messages '
              '(seq $lo..$hi) into a level-${leaf.seg.level} summary');
          try {
            await summaryNodeRepo.materialize(
              sessionId: sessionId,
              level: leaf.seg.level,
              startSeq: lo,
              endSeq: hi,
              nodeType: 'summary',
              summaryJson: jsonEncode({
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': leaf.text},
                ],
              }),
              tokenCost: leaf.tokens,
              summaryPromptVersion: 1,
              model: config.model,
              coveredMinSeq: lo,
              coveredMaxSeq: hi,
            );
          } catch (e) {
            persistFailed = true;
            debugPrint('[AliasAgent] persist summary failed: $e');
          }
        }
        entries.add(leaf);
      }
    }

    final verbatimRaw = CompactionEngine.rawTokens(plan.verbatim);
    final T = CompactionEngine.thresholdTokens(
        config.maxContextTokens, config.compactionThresholdPercent);
    final distances = CompactionEngine.distancesFromNewest(history);
    final spanCache =
        Map<CompactionSegment, ({int oldest, int newest})?>.identity();
    ({int oldest, int newest})? spanOf(CompactionSegment seg) =>
        spanCache.putIfAbsent(seg, () {
          if (seg.messages.isEmpty) return null;
          final oldest = history.indexOf(seg.messages.first);
          final newest = history.indexOf(seg.messages.last);
          if (oldest < 0 || newest < 0) return null;
          return (oldest: oldest, newest: newest);
        });

    bool sentAsSummary(
        ({CompactionSegment seg, String text, int tokens, bool isClosed}) e) {
      final span = spanOf(e.seg);
      if (span == null) return false;
      return CompactionEngine.substitutesSpan(
        distanceAtOldest: distances[span.oldest],
        distanceAtNewest: distances[span.newest],
        level: e.seg.level,
        t: T,
      );
    }

    int projectedTotal(
            List<({CompactionSegment seg, String text, int tokens, bool isClosed})>
                t) =>
        t.fold(
            0,
            (m, e) =>
                m +
                (sentAsSummary(e)
                    ? e.tokens
                    : CompactionEngine.rawTokens(e.seg.messages))) +
        verbatimRaw;

    var table = List.of(entries);
    var total = projectedTotal(table);
    bool omittable(
            ({CompactionSegment seg, String text, int tokens, bool isClosed}) e) =>
        CompactionEngine.mayBeLeftOut(
            level: e.seg.level, sentAsSummary: sentAsSummary(e));
    final attempted = Set<Object>.identity();
    var rollUpNo = 0;
    while (generate && table.isNotEmpty) {
      if (isAborted?.call() ?? false) {
        throw const _BackgroundFoldCancelled(
            'background fold aborted during coarsen');
      }
      final overCapacity = total > config.maxContextTokens;
      var candStart = -1;
      var candCount = 0;
      var candGroup =
          <({CompactionSegment seg, String text, int tokens, bool isClosed})>[];
      var i = 0;
      while (i < table.length) {
        if (!table[i].seg.rollable) {
          i++;
          continue;
        }
        final runStart = i;
        while (i < table.length && table[i].seg.rollable) {
          i++;
        }
        var fresh = runStart;
        while (fresh < i && attempted.contains(table[fresh])) {
          fresh++;
        }
        if (fresh >= i) continue;
        final freshTokens = <int>[
          for (var k = fresh; k < i; k++) table[k].tokens,
        ];
        final count = CompactionEngine.l2GroupCount(freshTokens, T);
        if (count > 0) {
          candStart = fresh;
          candCount = count;
          candGroup = table.sublist(fresh, fresh + count);
          break;
        }
      }
      if (candStart < 0) {
        if (!overCapacity) break;
        final dropAt = table.indexWhere(omittable);
        if (dropAt < 0) break;
        table.removeAt(dropAt);
        total = projectedTotal(table);
        continue;
      }
      final groupSum = candGroup.fold(0, (m, e) => m + e.tokens);
      rollUpNo++;
      _setCompactionStatus(
          CompactionStatus.level2(segment: rollUpNo, background: background),
          owner: statusOwner);
      final l2 = await summaryProvider.summarizeText(
          text: candGroup.map((e) => e.text).join('\n\n'),
          config: template,
          sessionId: sessionId);
      final l2Wins = CompactionEngine.summarySideWins(groupSum, l2.tokens);
      final l2IsVerbatim = candGroup.any((e) => e.seg.verbatimAtLevel);
      final l2Text = l2Wins ? l2.text : candGroup.map((e) => e.text).join('\n\n');
      final l2Tokens = l2Wins ? l2.tokens : groupSum;
      final mergedMsgs = candGroup.expand((e) => e.seg.messages).toList();
      final l2seg = CompactionSegment(
          messages: mergedMsgs,
          summary: true,
          level: 2,
          verbatimAtLevel: l2IsVerbatim,
          l2SubSpans:
              candGroup.map((e) => CompactionEngine.segmentSpan(e.seg)).toList());
      final l2Entry = (seg: l2seg, text: l2Text, tokens: l2Tokens, isClosed: false);
      if (dbOpen &&
          !l2IsVerbatim &&
          mergedMsgs.isNotEmpty &&
          mergedMsgs.first.seq != null &&
          mergedMsgs.last.seq != null) {
        final lo = mergedMsgs.first.seq!;
        final hi = mergedMsgs.last.seq!;
        try {
          await summaryNodeRepo.materialize(
            sessionId: sessionId,
            level: 2,
            startSeq: lo,
            endSeq: hi,
            nodeType: 'summary',
            summaryJson: jsonEncode({
              'role': 'user',
              'content': [
                {'type': 'text', 'text': l2Text},
              ],
            }),
            tokenCost: l2Tokens,
            summaryPromptVersion: 1,
            model: config.model,
            coveredMinSeq: lo,
            coveredMaxSeq: hi,
          );
        } catch (e) {
          persistFailed = true;
          debugPrint('[AliasAgent] persist level-2 summary failed: $e');
        }
      }
      if (sentAsSummary(l2Entry)) {
        table = [
          ...table.sublist(0, candStart),
          l2Entry,
          ...table.sublist(candStart + candCount),
        ];
      } else {
        for (final e in candGroup) {
          attempted.add(e);
        }
      }
      total = projectedTotal(table);
    }
    if (total > config.maxContextTokens) {
      debugPrint('[AliasAgent] compaction projection still over budget by '
          '${total - config.maxContextTokens} tokens (frozen level-2 summaries + newest '
          'verbatim alone exceed maxContextTokens; sending best-effort projection — '
          'a pathological known limit)');
    }

    final pieces = <({int at, ProjectionPiece piece})>[];
    final finalSummaries = <SummaryResult>[];
    final posOf = Map<Message, int>.identity();
    for (var i = 0; i < history.length; i++) {
      posOf[history[i]] = i;
    }
    int startPos(List<Message> msgs) =>
        msgs.isEmpty ? -1 : (posOf[msgs.first] ?? -1);

    for (final e in table) {
      if (e.seg.messages.isEmpty) continue;
      final at = startPos(e.seg.messages);
      if (!e.seg.verbatimAtLevel && sentAsSummary(e)) {
        final summary = SummaryResult(text: e.text, tokens: e.tokens);
        finalSummaries.add(summary);
        pieces.add((
          at: at,
          piece: ProjectionPiece(segment: e.seg, summary: summary),
        ));
      } else {
        pieces.add((
          at: at,
          piece: ProjectionPiece(
              segment:
                  CompactionSegment(messages: e.seg.messages, summary: false)),
        ));
      }
    }
    for (final seg in plan.segments) {
      if (seg.summary || seg.messages.isEmpty) continue;
      pieces.add((at: startPos(seg.messages), piece: ProjectionPiece(segment: seg)));
    }
    pieces.sort((a, b) => a.at - b.at);

    final orderedTimeline = <ProjectionPiece>[];
    for (final p in pieces) {
      final piece = p.piece;
      if (piece.summary == null &&
          orderedTimeline.isNotEmpty &&
          orderedTimeline.last.summary == null) {
        orderedTimeline[orderedTimeline.length - 1] = ProjectionPiece(
            segment: CompactionSegment(
                messages: [
                  ...orderedTimeline.last.segment.messages,
                  ...piece.segment.messages,
                ],
                summary: false));
        continue;
      }
      orderedTimeline.add(piece);
    }

    if (dbOpen && !persistFailed) {
      try {
        await summaryNodeRepo.clearDirty(sessionId);
      } catch (e) {
        debugPrint('[AliasAgent] clear dirty watermark failed: $e');
      }
    }
    return (timeline: orderedTimeline, summaries: finalSummaries);
  }

  Future<List<SummaryReference>> _loadReferenceCandidates(bool dbOpen) async {
    if (!dbOpen) return const [];
    try {
      final nodes = await summaryNodeRepo.queryBySession(sessionId);
      return [
        for (final n in nodes)
          if (n.summaryJson != null && n.summaryJson!.isNotEmpty)
            SummaryReference(
              level: n.level,
              coveredMinSeq: n.coveredMinSeq,
              coveredMaxSeq: n.coveredMaxSeq,
              text: _summaryTextFromJson(n.summaryJson!),
            ),
      ];
    } catch (e) {
      debugPrint('[AliasAgent] reference candidates unavailable: $e');
      return const [];
    }
  }

  static String _summaryTextFromJson(String summaryJson) {
    try {
      final doc = jsonDecode(summaryJson) as Map<String, dynamic>;
      final content = doc['content'] as List<dynamic>;
      for (final block in content) {
        final m = block as Map<String, dynamic>;
        if (m['type'] == 'text') return (m['text'] as String?) ?? '';
      }
    } catch (_) {}
    return '';
  }

  List<Map<String, dynamic>> _buildCompactionProjection(
      List<ProjectionPiece> timeline) {
    final out = <Map<String, dynamic>>[];
    var pendingBlocks = <Map<String, dynamic>>[];
    for (final piece in timeline) {
      final summary = piece.summary;
      if (summary != null) {
        pendingBlocks.add({
          'type': 'text',
          'text': buildSummaryContent(
              result: summary,
              foldedCount: piece.segment.messages.length,
              level: piece.segment.level),
        });
        continue;
      }
      final raw = _buildApiMessages(piece.segment.messages);
      if (raw.isEmpty) continue;
      if (pendingBlocks.isNotEmpty) {
        if (raw.first['role'] == 'user') {
          (raw.first['content'] as List<Map<String, dynamic>>)
              .insertAll(0, pendingBlocks);
        } else {
          out.add({'role': 'user', 'content': pendingBlocks});
        }
        pendingBlocks = <Map<String, dynamic>>[];
      }
      out.addAll(raw);
    }
    if (pendingBlocks.isNotEmpty) {
      out.add({'role': 'user', 'content': pendingBlocks});
    }
    return out;
  }

  static String? _toolImagePath(Map<String, dynamic> source) {
    final image = source['image'];
    if (image is! Map) return null;
    final path = image['path'];
    return path is String && path.isNotEmpty ? path : null;
  }

  Object _toolResultContent({required String text, String? imagePath}) {
    if (imagePath == null) return text;
    final blocks = <Map<String, dynamic>>[
      {'type': 'text', 'text': text},
    ];
    final parts = buildImageRequestParts(imagePath);
    if (parts.block == null) {
      blocks.add({'type': 'text', 'text': parts.note});
    } else if (!config.acceptsImages) {
      blocks.add({
        'type': 'text',
        'text': '[图片未发送：当前模型 ${config.model} 未声明图片输入'
            '（input_modalities 不含 image）；图片路径：$imagePath]',
      });
    } else {
      blocks.add(parts.block!);
    }
    return blocks;
  }

  List<Map<String, dynamic>> _buildApiMessages(List<Message> messages,
      {bool? allowImages}) {
    final apiMessages = <Map<String, dynamic>>[];
    final emittedToolUseIds = <String>{};
    final imagesAllowed = allowImages ?? config.acceptsImages;
    final modelName = config.model;

    final preparedByMsg = <int, List<ImageRequestParts>>{};
    final planned = <PlannedImage>[];
    for (var mi = 0; mi < messages.length; mi++) {
      final msg = messages[mi];
      if (msg.role != 'user' || msg.attachments.isEmpty) continue;
      final partsList = <ImageRequestParts>[];
      for (var j = 0; j < msg.attachments.length; j++) {
        final parts = buildImageRequestParts(msg.attachments[j], index: j + 1);
        partsList.add(parts);
        planned.add(PlannedImage(path: msg.attachments[j], parts: parts));
      }
      preparedByMsg[mi] = partsList;
    }
    final omissions = planImageOmissions(planned);
    final omittedByMsg = <int, List<String?>>{};
    var planCursor = 0;
    for (final entry in preparedByMsg.entries) {
      final notes = List<String?>.filled(entry.value.length, null);
      for (var j = 0; j < entry.value.length; j++) {
        notes[j] = omissions[planCursor++];
      }
      omittedByMsg[entry.key] = notes;
    }

    for (var mi = 0; mi < messages.length; mi++) {
      final msg = messages[mi];
      final content = <Map<String, dynamic>>[];
      if (msg.content.isNotEmpty) {
        content.add({'type': 'text', 'text': msg.content});
      }

      if (msg.role == 'user' && msg.attachments.isNotEmpty) {
        final partsList = preparedByMsg[mi]!;
        final omitted = omittedByMsg[mi]!;
        for (var i = 0; i < msg.attachments.length; i++) {
          final path = msg.attachments[i];
          final parts = partsList[i];
          final omission = omitted[i];
          if (omission != null) {
            content.add({'type': 'text', 'text': omission});
          } else if (parts.block == null) {
            content.add({'type': 'text', 'text': parts.note});
          } else if (!imagesAllowed) {
            content.add({
              'type': 'text',
              'text': '[图片未发送：当前模型 $modelName 未声明图片输入'
                  '（input_modalities 不含 image）；图片路径：$path]',
            });
          } else {
            content.add({'type': 'text', 'text': parts.note});
            content.add(parts.block!);
          }
        }
      }

      if (msg.role == 'assistant' &&
          msg.thinkingJson != null &&
          msg.thinkingJson!.isNotEmpty) {
        try {
          final thinkingBlocks =
              jsonDecode(msg.thinkingJson!) as List<dynamic>;
          content.insertAll(
              0,
              thinkingBlocks.map((b) => _thinkingBlockWithoutIndex(
                  b as Map<String, dynamic>)));
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse thinkingJson: $e');
        }
      }

      var ownedToolCalls = const <Map<String, dynamic>>[];
      if (msg.role == 'assistant' &&
          msg.toolCallsJson != null &&
          msg.toolCallsJson!.isNotEmpty) {
        try {
          final toolCalls = jsonDecode(msg.toolCallsJson!) as List<dynamic>;
          ownedToolCalls = <Map<String, dynamic>>[];
          for (final tc in toolCalls) {
            final id = ((tc as Map<String, dynamic>)['id'] ?? '').toString();
            if (id.isEmpty || emittedToolUseIds.add(id)) {
              ownedToolCalls.add(tc);
            }
          }
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse toolCallsJson: $e');
          ownedToolCalls = const [];
        }
      }

      for (final tc in ownedToolCalls) {
        content.add({
          'type': 'tool_use',
          'id': tc['id'] ?? '',
          'name': tc['toolName'] ?? tc['name'] ?? '',
          'input': tc['input'] ?? {},
        });
      }

      apiMessages.add({'role': msg.role, 'content': content});

      if (ownedToolCalls.isNotEmpty) {
        try {
          final toolResults = <Map<String, dynamic>>[];
          for (final tc in ownedToolCalls) {
            final rawBody =
                (tc['result'] ?? tc['resultPreview'] ?? '').toString();
            final tcInput =
                (tc['input'] as Map<String, dynamic>?) ?? const {};
            final toolName = (tc['toolName'] ?? tc['name'] ?? '').toString();
            final refetchPath = (tcInput['path'] as String?) ?? '';
            final refetchUrl = (tcInput['url'] as String?) ?? '';
            final refetchArg = refetchPath.isNotEmpty
                ? refetchPath
                : (refetchUrl.isNotEmpty ? refetchUrl : '');
            // spawn_subagent 的最终结论**完整**重放：不套通用省略规则。
            // 其它工具继续沿用既有截断与取回规则（见 tool_result_text.dart）。
            final body = toolName == 'spawn_subagent'
                ? rawBody
                : elideOversizedToolResult(
                    name: toolName, path: refetchArg, body: rawBody);
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': tc['id'] ?? '',
              'content': _toolResultContent(
                text: body,
                imagePath: _toolImagePath(tc),
              ),
            });
          }
          apiMessages.add({'role': 'user', 'content': toolResults});
        } catch (e) {
          debugPrint('[AliasAgent] Failed to build tool_results: $e');
        }
      }
    }
    return apiMessages;
  }

  // ---------------------------------------------------------------------------
  // 工具执行
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _executeTool(
      Map<String, dynamic> toolCall) async {
    final name = toolCall['name'] as String?;
    final input = (toolCall['input'] as Map<String, dynamic>?) ?? {};
    final path = (input['path'] as String?) ?? '';

    String resultJson;
    switch (name) {
      case 'read_file':
        final readReq = <String, dynamic>{'path': path};
        final offset = input['offset'];
        final limit = input['limit'];
        if (offset is int) readReq['offset'] = offset;
        if (limit is int) readReq['limit'] = limit;
        resultJson = sidecar.readFile(sessionId, jsonEncode(readReq));
      case 'write_file':
        resultJson = sidecar.writeFile(sessionId, jsonEncode({
          'path': path,
          'content': input['content'] ?? '',
        }));
      case 'edit_file':
        final edits = input['edits'];
        if (edits is! List || edits.isEmpty) {
          resultJson =
              '{"ok":false,"error":"edits must contain at least one replacement"}';
        } else {
          resultJson = sidecar.editFile(
              sessionId, jsonEncode({'path': path, 'edits': edits}));
        }
      case 'list_dir':
        resultJson = sidecar.listDir(sessionId, path);
      case 'glob_file':
        resultJson = sidecar.globFile(sessionId, jsonEncode({
          'pattern': input['pattern'] ?? '',
          'max_results': input['max_results'] ?? 200,
        }));
      case 'grep_file':
        resultJson = sidecar.grepFile(sessionId, jsonEncode({
          'pattern': input['pattern'] ?? '',
          'glob': input['glob'] ?? '',
          'ignore_case': input['ignore_case'] ?? false,
          'max_results': input['max_results'] ?? 100,
        }));
      case 'web_search':
        final request = jsonEncode({
          'query': input['query'] ?? '',
          'providers': input['providers'] ?? <String>[],
          'depth': input['depth'] ?? 'basic',
          'max_results': input['max_results'] ?? 5,
        });
        resultJson = await sidecar.webSearch(sessionId, request);
      case 'web_fetch':
        final request = jsonEncode({'url': input['url'] ?? ''});
        resultJson = await sidecar.webFetch(sessionId, request);
      case 'browser_navigate':
        resultJson = await sidecar.browserNavigate(
            sessionId, jsonEncode({'url': input['url'] ?? ''}));
      case 'browser_click':
        resultJson = await sidecar.browserClick(
            sessionId, jsonEncode({'selector': input['selector'] ?? ''}));
      case 'browser_type':
        resultJson = await sidecar.browserType(sessionId, jsonEncode({
          'selector': input['selector'] ?? '',
          'text': input['text'] ?? '',
        }));
      case 'browser_snapshot':
        resultJson = await sidecar.browserSnapshot(sessionId, jsonEncode({}));
      case 'run_command':
        final request = <String, dynamic>{
          'command': input['command'] ?? '',
        };
        if (input['workdir'] is String &&
            (input['workdir'] as String).isNotEmpty) {
          request['workdir'] = input['workdir'];
        }
        request['timeout_ms'] =
            (input['timeout_ms'] as int?) ?? config.commandTimeoutMs;
        request['max_timeout_ms'] = config.commandMaxTimeoutMs;
        request['preview_chars'] = config.spillPreviewChars;
        resultJson = await sidecar.runCommand(sessionId, jsonEncode(request));
      case 'read_spill':
        resultJson = sidecar.readSpill(sessionId, jsonEncode({
          'ref': input['ref'] ?? '',
          if (input['offset'] is int) 'offset': input['offset'],
          if (input['limit'] is int) 'limit': input['limit'],
          'preview_chars': config.spillPreviewChars,
        }));
      case 'get_current_time':
        final now = DateTime.now();
        final dt = now.toIso8601String();
        final date =
            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final time =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        final tz = now.timeZoneOffset;
        final tzStr =
            '${tz.isNegative ? '-' : '+'}${tz.inHours.abs().toString().padLeft(2, '0')}:${tz.inMinutes.abs().remainder(60).toString().padLeft(2, '0')}';
        resultJson = jsonEncode({
          'ok': true,
          'datetime': dt,
          'date': date,
          'time': time,
          'timezone': tzStr,
          'content': 'Current time: $date $time $tzStr',
        });
      case 'read_image':
        if (!config.acceptsImages) {
          resultJson = jsonEncode({
            'ok': false,
            'error': 'cannot read "$path" as an image: model "${config.model}" does not '
                'declare image input (input_modalities)',
          });
        } else {
          resultJson = sidecar.readImage(sessionId, jsonEncode({'path': path}));
        }
      case 'spawn_subagent':
        final runner = subagentRunner;
        if (runner == null) {
          resultJson = jsonEncode({
            'ok': false,
            'error': 'spawn_subagent 未接入子运行服务：拒绝假装执行',
          });
        } else {
          final subResult = await runner.run(parent: this, input: input);
          resultJson = jsonEncode(subResult);
        }
      default:
        resultJson = '{"ok":false,"error":"Unknown tool: $name"}';
    }

    try {
      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      if (name == 'web_search' || name == 'web_fetch') {
        parsed['content'] = _formatSearchResultForDisplay(name!, parsed);
      } else if (name == 'browser_navigate' ||
          name == 'browser_click' ||
          name == 'browser_type' ||
          name == 'browser_snapshot') {
        final snap = (parsed['snapshot'] as String?) ?? '';
        final url = (parsed['url'] as String?) ?? '';
        final title = (parsed['title'] as String?) ?? '';
        final note =
            (parsed['divergent'] == true) ? (parsed['note'] as String? ?? '') : '';
        final sb = StringBuffer();
        if (title.isNotEmpty) sb.writeln(title);
        if (url.isNotEmpty) sb.writeln(url);
        if (note.isNotEmpty) sb.writeln(note);
        sb.write(snap);
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no page text captured)'
            : sb.toString().trim();
      } else if (name == 'run_command') {
        parsed['content'] = composeCommandResultText(parsed);
      } else if (name == 'write_file') {
        final bytes = parsed['bytes_written'] as int? ?? 0;
        final created = parsed['created'] as bool? ?? false;
        final p = (parsed['path'] as String?) ?? path;
        parsed['content'] =
            created ? 'Created $p ($bytes bytes)' : 'Wrote $p ($bytes bytes)';
      } else if (name == 'edit_file') {
        final reps = parsed['replacements'] as int? ?? 0;
        final matchedWith = parsed['matched_with'] as String?;
        var content = 'Edited $path ($reps replacement${reps == 1 ? '' : 's'})';
        if (matchedWith != null) content += ' — matched with $matchedWith';
        final hunks = parsed['hunks'];
        if (parsed['ok'] == true && hunks is List) {
          content += editLineSuffix(hunks);
        }
        parsed['content'] = content;
      } else if (name == 'glob_file') {
        final maxResults = (input['max_results'] as int?) ?? 200;
        final paths = parsed['paths'] as List? ?? [];
        final truncated = parsed['truncated'] == true;
        final sb = StringBuffer();
        for (final p in paths.take(maxResults)) {
          sb.writeln(p);
        }
        if (truncated) {
          sb.writeln('... (truncated: only the first $maxResults entries are shown; '
              'to get more, call glob_file again with max_results=${maxResults * 2})');
        }
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no files matched)'
            : sb.toString().trim();
      } else if (name == 'grep_file') {
        final maxResults = (input['max_results'] as int?) ?? 100;
        final matches = parsed['matches'] as List? ?? [];
        final truncated = parsed['truncated'] == true;
        final sb = StringBuffer();
        for (final m in matches.take(maxResults)) {
          final mm = m is Map<String, dynamic> ? m : <String, dynamic>{};
          final p = mm['path'] ?? '?';
          final l = mm['line'];
          final t = (mm['text'] ?? '').toString().trimRight();
          sb.writeln('$p:${l ?? '?'}: $t');
        }
        if (truncated) {
          sb.writeln('... (truncated: only the first $maxResults matches are shown; '
              'to get more, call grep_file again with max_results=${maxResults * 2}, '
              'or narrow the pattern/glob)');
        }
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no matches)'
            : sb.toString().trim();
      } else if (name == 'read_spill') {
        parsed['content'] = (parsed['text'] as String?) ?? '';
      }
      return parsed;
    } catch (e) {
      debugPrint('[AliasAgent] _executeTool parse error: $e');
      return {'ok': false, 'error': 'Failed to parse tool result'};
    }
  }

  String _formatSearchResultForDisplay(
      String toolName, Map<String, dynamic> result) {
    if (result['ok'] != true) {
      final error = (result['error'] as String?) ?? 'Unknown error';
      return error.length > 200 ? '${error.substring(0, 200)}...' : error;
    }
    final buf = StringBuffer();
    if (toolName == 'web_search') {
      return assembleSearchText(result, budget: kToolResultElisionThreshold);
    } else if (toolName == 'web_fetch') {
      final content = (result['content'] as String?) ?? '';
      if (content.isEmpty) {
        return '(fetched empty page)';
      }
      buf.write(
          content.length > 2000 ? '${content.substring(0, 2000)}...' : content);
    }
    return buf.toString().trimRight();
  }

  List<ResultSection> _buildResultSections(
      String toolName, Map<String, dynamic> result) {
    if (result['ok'] != true) return [];
    if (toolName == 'web_search') {
      final results = result['results'] as Map<String, dynamic>?;
      if (results == null || results.isEmpty) return [];
      final sections = <ResultSection>[];
      for (final ns in results.keys) {
        final nsData = results[ns] as Map<String, dynamic>?;
        if (nsData == null) continue;
        if (nsData.containsKey('error')) {
          sections.add(ResultSection(
            label: ns.toString(),
            error: (nsData['error'] as String?) ?? 'Unknown error',
          ));
        } else {
          final items = <ResultItem>[];
          final rawItems = nsData['results'] as List<dynamic>?;
          if (rawItems != null) {
            for (final item in rawItems) {
              final m = item as Map<String, dynamic>?;
              if (m != null) {
                items.add(ResultItem(
                  title: m['title'] as String?,
                  url: m['url'] as String?,
                  content: m['content'] as String?,
                ));
              }
            }
          }
          sections.add(ResultSection(label: ns.toString(), items: items));
        }
      }
      return sections;
    } else if (toolName == 'web_fetch') {
      final content = (result['content'] as String?) ?? '';
      if (content.isEmpty) return [];
      final pageTitle = (result['title'] as String?) ?? '';
      final pageUrl = (result['url'] as String?) ?? '';
      final displayTitle = pageTitle.isNotEmpty
          ? pageTitle
          : (pageUrl.isNotEmpty ? pageUrl : 'Fetched page');
      return [
        ResultSection(
          label: 'Fetched page',
          items: [
            ResultItem(
              title: displayTitle,
              url: pageUrl.isNotEmpty ? pageUrl : null,
              content: content,
            ),
          ],
        ),
      ];
    }
    return [];
  }

  /// 清掉流式展示状态并取消在途请求（与原来的 `_endStreaming` 等价）。
  void _endStreaming() {
    if (_disposed) return;
    sidecar.cancelRequest(sessionId);
    _setStreaming(false);
  }

  Future<void> _storeError(String message) async {
    final errorMsg = await messageRepo.insert(
      sessionId: sessionId,
      role: 'assistant',
      content: 'Error: $message',
    );
    await sessionRepo.touch(sessionId);
    _history.add(errorMsg);
    callbacks.onAssistantMessage?.call(errorMsg, true);
  }
}

/// 后台压缩被抢占时使用的内部异常（与原 `lib/main.dart` 的同名类同义）。
class _BackgroundFoldCancelled implements Exception {
  final String reason;
  const _BackgroundFoldCancelled(this.reason);

  @override
  String toString() => reason;
}
