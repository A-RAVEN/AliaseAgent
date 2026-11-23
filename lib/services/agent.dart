import 'dart:async';
import 'dart:convert';

import '../models/agent_type_config.dart';
import '../models/compaction_status.dart';
import '../models/context_breakdown.dart';
import '../models/instance_overrides.dart';
import '../models/message.dart';
import '../models/model_catalog_entry.dart';
import '../models/provider_config.dart' as provider_model;
import '../models/resolved_agent_config.dart';
import '../models/tool_call_activity.dart';
import 'agent_config_resolver.dart';
import 'api_message_builder.dart';
import 'compaction/compaction_plan.dart';
import 'compaction/guard_anchors.dart';
import 'compaction/seam_selector.dart';
import 'compaction/summary_provider.dart';
import 'compaction/summary_reference.dart';
import 'config_service.dart';
import 'context_estimator.dart';
import 'context_snapshot.dart';
import 'database_service.dart';
import 'group_member_context.dart';
import 'group_prompts.dart';
import 'group_reaction.dart';
import 'group_view_loader.dart';
import 'logging.dart';
import 'message_repository.dart';
import 'search_text_assembly.dart';
import 'session_repository.dart';
import 'sidecar_bridge.dart';
import 'skills/skill_catalog_service.dart';
import 'subagent_runner.dart';
import 'summary_node_repository.dart';
import 'tool_catalog.dart';
import 'tool_group_planner.dart';
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
///
/// change `group-reactive-mode` 任务 2.1 / design D5 增两个字段；R.10 起
/// [reactionPassed] 来自**结构化** `group_react.pass`，不再看正文：
///   - [publicMessage]：本轮**写入的公开消息**（`pass=true` / 空 message / 失败 /
///     取消时为 null）。组服务据此推进触发 `seq`，不需要额外查询"最新公开行"；
///   - [reactionPassed]：本轮 `group_react.pass == true`（结构化沉默）。
class AgentRunResult {
  const AgentRunResult._({
    required this.status,
    required this.metering,
    this.finalText,
    this.error,
    this.publicMessage,
    this.reactionPassed = false,
  });

  /// 整轮自然结束；[finalText] 只来自没有工具调用的最终模型轮。
  const AgentRunResult.completed({
    required String finalText,
    required AgentMeteringSnapshot metering,
    Message? publicMessage,
    bool reactionPassed = false,
  }) : this._(
          status: AgentRunStatus.completed,
          metering: metering,
          finalText: finalText,
          publicMessage: publicMessage,
          reactionPassed: reactionPassed,
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

  /// 本轮写入的公开消息（反应轮 PASS / 空输出 / 失败 / 取消时为 null）。
  ///
  /// 只描述**这一轮**：普通轮里它也是本轮的最终公开 assistant 行，不含用户消息。
  final Message? publicMessage;

  /// 本轮是否命中**结构化**沉默（`reaction` 轮的 `group_react.pass == true`）。
  ///
  /// 普通轮（含关闭态纯 speaker）恒为 false：它们不注入 `group_react`、不做这套判定，
  /// `[PASS]` 在这些轮里只是普通正文。
  final bool reactionPassed;

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
  /// **DB 作用域**：消息、摘要、会话行都按它归属。组会话里它是组 id。
  final String sessionId;

  /// **实例句柄**：sidecar 上下文键 + `AgentRegistry` 键 + 取消目标（design D3）。
  ///
  /// 单会话实例 `handle == sessionId`（行为与变更前一致）；成员实例是成员专属句柄
  /// `<groupId>::<memberId>`。两者不能兼任：拿组 id 当句柄会让 N 个成员共用一个
  /// sidecar 上下文、互相 cancel / 互相 disposeContext。
  final String handle;

  /// 成员上下文（单会话为 null）。压缩作用域、组角色纪律、事件身份都由它派生。
  final GroupMemberContext? member;

  /// 成员视图的增量装配器（单会话为 null ⇒ 走原来的全量 `restore()`）。
  final GroupViewLoader? viewLoader;

  /// **每轮现读**的群成员名单提供者（成员实例专用；change `group-member-identity`）。
  ///
  /// 返回当前未移除成员的显示名（加入顺序）。每次 `_callModel` 装配系统提示词时调用，
  /// 所以成员增减下一轮就生效，不做实例级缓存。单会话为 null。
  final Future<List<String>> Function()? groupRosterProvider;

  /// 实例级覆盖层（单会话来自 `sessions.overrides_json`，成员来自成员行）。
  ///
  /// 工具子集与提示词追加已在创建时叠进 [config]（创建/恢复时生效）；[overrides]
  /// 保留在这里是为了**思考强度的逐轮热更新**（下一消息生效）。
  final AgentInstanceOverrides? overrides;

  /// 每轮重读覆盖层的解析器（思考强度热更新：改档位不必重建实例）。
  final Future<AgentInstanceOverrides?> Function()? overridesLookup;

  /// 会话引用的模板名（`Session.agentType`），错误消息要带它。
  final String agentTypeName;

  /// 创建时冻结的生效配置；运行中只读它，不回头读模板注册表。
  final ResolvedAgentConfig config;

  /// 创建时冻结的模板副本（摘要提供者接口仍按模板取模型等字段）。
  final AgentTypeConfig template;

  /// 每轮装配重解析思考档用的**模板查找器**（change `model-truth-from-gateway` D7）。
  ///
  /// 按 [agentTypeName] 读注册表的**当前**引用，所以模板保存后下一轮装配就吃到新值；
  /// 由 `AgentFactory.create` 注入。null = 退回创建时的冻结快照（直接构造 [Agent] 的
  /// 既有测试路径，不改变它们的语义）。
  final AgentTypeConfig? Function(String templateName)? templateLookup;

  /// 每轮装配重解析思考档用的**目录查找器**（按 provider 名读当前 Provider 配置，
  /// 其中带 `models`/`discovered_at`）。null = 没有目录可查（⇒ 只按显式档解析）。
  final provider_model.ProviderConfig? Function(String providerName)?
      providerLookup;

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

  /// 顶层配置项 `tool.parallel_max`：单个只读并发段一次最多同时启动的成员数。
  ///
  /// 0 = 不设上限（design D6）。它不是模板字段，所以单独从 `AppConfig` 传进来，
  /// 不进 [ResolvedAgentConfig]。
  final int toolParallelMax;

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
    String? handle,
    this.member,
    this.viewLoader,
    this.groupRosterProvider,
    this.overrides,
    this.overridesLookup,
    required this.agentTypeName,
    required this.config,
    required this.template,
    this.templateLookup,
    this.providerLookup,
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
    this.toolParallelMax = 0,
    this.subagentRunner,
    this.callbacks = const AgentCallbacks(),
  })  : handle = handle ?? sessionId,
        _provider = provider;

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
  ///
  /// `load_skill` 在这里**无条件追加**（change `add-skill-mechanism` design D4/D9）：
  /// 它不进 `ToolCatalog.kBaseToolNames`、不进模板勾选清单、不改任何用户配置，
  /// 但每轮装配都随请求交付 —— 「技能对所有 Agent 模板全量生效、无逐模板开关」
  /// （`TODO.md:162`）就是靠这一处实现。模板清单里手写了 `load_skill` 时
  /// `resolve` 已经返回它，此时不再追加（保证数组里恰出现一次）。
  List<Map<String, dynamic>> get toolDefinitions {
    final resolved = ToolCatalog.instance
        .resolve(config.tools, context: '模板 "$agentTypeName"');
    final alreadyListed =
        resolved.any((definition) => definition['name'] == kLoadSkillToolName);
    if (alreadyListed) return resolved;
    return <Map<String, dynamic>>[...resolved, kLoadSkillToolDefinition];
  }

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
    final created = await sidecar.ensureContext(handle,
        defaultWorkspace: defaultWorkspace ?? ConfigService.homeDir);
    if (created) _workspaceInitialized = true;
    return created;
  }

  /// 恢复/装配该实例的视图序列。
  ///
  /// - 单会话：保持变更前的行为（全量 `queryBySession` 载入常驻）。
  /// - 组成员：**增量装配**（只读高水位之后的行），绝不走全量查询（design D9 /
  ///   任务 4.2 的"全量查询即抛错"红靶就是守这一条）。
  Future<void> restore() async {
    if (_disposed) throw AgentDisposedException(sessionId);
    if (_retiring) throw AgentRetiredException(sessionId, agentTypeName);
    final groupMember = member;
    if (groupMember != null) {
      await assembleMemberView();
      _restored = true;
      return;
    }
    final messages = await messageRepo.queryBySession(sessionId);
    _history
      ..clear()
      ..addAll(messages);
    _restored = true;
  }

  /// 摘要/压缩的成员作用域：单会话为 null（按 `IS NULL` 匹配），成员为成员 id。
  String? get _memberScope => member?.memberId;

  /// 成员显示名的解析器（含已移除成员；每次装配现解析 ⇒ 改名不改归属）。
  ///
  /// 由 `AgentFactory` / 组服务注入（它们能读 `group_members`）；直接构造 Agent 的
  /// 测试不注入时至少知道自己的显示名。
  Future<Map<String, String>> Function()? displayNamesResolver;

  /// 成员视图的摘要覆盖情况（作用域内摘要覆盖到的最大 seq + 覆盖区间）。
  Future<({int through, List<({int min, int max})> spans})>
      _memberCoveredSpans() async {
    final groupMember = member;
    if (groupMember == null || !summaryStoreOpen) {
      return (through: 0, spans: const <({int min, int max})>[]);
    }
    try {
      final nodes = await summaryNodeRepo.queryBySession(sessionId,
          memberId: groupMember.memberId);
      if (nodes.isEmpty) {
        return (through: 0, spans: const <({int min, int max})>[]);
      }
      var through = 0;
      final spans = <({int min, int max})>[];
      for (final node in nodes) {
        if (node.coveredMaxSeq > through) through = node.coveredMaxSeq;
        spans.add((min: node.coveredMinSeq, max: node.coveredMaxSeq));
      }
      return (through: through, spans: spans);
    } catch (e) {
      debugPrint('[AliasAgent] 成员摘要覆盖范围读取失败：$e');
      return (through: 0, spans: const <({int min, int max})>[]);
    }
  }

  /// 增量装配成员视图（只读高水位之后的行；被摘要覆盖的区间非常驻）。
  Future<void> assembleMemberView() async {
    final groupMember = member;
    final loader = viewLoader;
    if (groupMember == null || loader == null) return;
    final names = await (displayNamesResolver?.call() ??
        Future<Map<String, String>>.value(
            <String, String>{groupMember.memberId: groupMember.displayName}));
    final covered = await _memberCoveredSpans();
    await loader.assemble(
      memberId: groupMember.memberId,
      displayNames: names,
      coveredThrough: covered.through,
    );
    _history
      ..clear()
      ..addAll(loader.residentView(groupMember.memberId));
  }

  /// 这次请求用的完整视图（公开入口：组服务的两个前置门要读它）。
  Future<List<Message>> memberViewForRound() => _memberViewForRound();

  /// 这次请求用的完整视图 = 驻留视图 + 按需读回的、被该成员摘要覆盖的区间。
  Future<List<Message>> _memberViewForRound() async {
    final groupMember = member;
    final loader = viewLoader;
    if (groupMember == null || loader == null) {
      return List<Message>.from(_history);
    }
    final names = await (displayNamesResolver?.call() ??
        Future<Map<String, String>>.value(
            <String, String>{groupMember.memberId: groupMember.displayName}));
    final covered = await _memberCoveredSpans();
    return loader.fullViewForCompaction(
      memberId: groupMember.memberId,
      displayNames: names,
      coveredSpans: covered.spans,
    );
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
    sidecar.cancelRequest(handle);
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
      sidecar.cancelRequest(handle);
    } catch (_) {}
    await waitForRounds();
    await sidecar.disposeContext(handle);
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
  /// [writeUserMessage] 为 false 时**不写**用户消息行（群聊里"不带文本的点名"用：
  /// 那不写空用户行，直接基于现有原文发言）。
  ///
  /// [reaction] / [mustRespond]：**反应轮标志**（change `group-reactive-mode` D5）。
  ///   - `reaction: true` 只用于 ① 开启态 speaker 的强制轮；② 两态下 `@mention` 的
  ///     强制轮；③ 开启态的自愿反应轮。**关闭态纯 speaker（无 @）不置该标志**，
  ///     走普通轮（逐字不变：不追加提示词、不做 PASS 判定）；
  ///   - `mustRespond` 蕴含 `reaction`：追加 [kGroupMustRespondPrompt]（必应），
  ///     否则追加 [kGroupReactionPrompt]（授权沉默）；
  ///   - 命中哨兵（`trim` 后恰为 `[PASS]`）或 `trim` 为空时**不写公开行**，
  ///     私有工具行照常落库；[AgentRunResult.publicMessage] / `reactionPassed`
  ///     把这件事带回调用方（组服务据此记 `passed` / `forced_pass` / `empty` /
  ///     `forced_empty`）。
  Future<AgentRunResult> send(String text,
      {List<String> attachments = const [],
      bool writeUserMessage = true,
      bool reaction = false,
      bool mustRespond = false}) async {
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
      sidecar.cancelRequest(handle);
      _foldIdleTimer?.cancel();
      _foldIdleTimer = null;
    }
    if (!_restored) await restore();
    final round = _sendMessageRound(
        text: text,
        attachments: attachments,
        writeUserMessage: writeUserMessage,
        reaction: reaction,
        mustRespond: mustRespond);
    _registerRound(round);
    return await round;
  }

  Future<AgentRunResult> _sendMessageRound({
    required String text,
    required List<String> attachments,
    bool writeUserMessage = true,
    bool reaction = false,
    bool mustRespond = false,
  }) async {
    final epoch = ++_requestEpoch;
    if (writeUserMessage) {
      // 用户消息：author 一律为空（用户没有成员作者）、公开可见。组会话里也**只写一次**
      // —— 由这一轮写入，不重复写（spec「不带用户消息的点名」的另一面）。
      final userMsg = await messageRepo.insert(
        sessionId: sessionId,
        role: 'user',
        content: text,
        attachments: attachments,
        author: null,
        visibility: Message.visibilityPublic,
      );
      await sessionRepo.touch(sessionId);
      // 成员视图以装配器为唯一来源：用户消息落库后立刻增量装配进来（不手工 add，
      // 否则 next assembly 会把它读第二遍）。
      if (member != null) {
        await assembleMemberView();
      } else {
        _history.add(userMsg);
      }
      callbacks.onUserMessage?.call(userMsg);

      final titleUpdated = await sessionRepo.updateTitleIfDefault(sessionId, text);
      if (titleUpdated) {
        final session = await sessionRepo.get(sessionId);
        callbacks.onTitleChanged?.call(session?.title ?? 'New Chat');
      }
    }
    _setStreaming(true);

    // 成员请求的输入是**该成员的视图**（驻留视图 + 按需读回的覆盖区间）；
    // 单会话保持变更前的行为（`_history` 全量常驻）。
    final snapshotMessages = member == null
        ? List<Message>.from(_history)
        : await _memberViewForRound();
    try {
      return await _callModel(
        messages: snapshotMessages,
        epoch: epoch,
        reaction: reaction,
        mustRespond: mustRespond,
      );
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

  /// 当前群成员名单（每轮现读；单会话或没有 provider 时返回 null）。
  Future<String?> _groupRosterSection() async {
    final provider = groupRosterProvider;
    final self = member;
    if (provider == null || self == null) return null;
    final names = await provider();
    if (names.isEmpty) return null;
    return '本群成员：${names.join('、')}。你是「${self.displayName}」。';
  }

  /// 反应轮的结构化收尾（R.10 / design D5）：读 `group_react` 的 `pass` / `message`，
  /// 决定是否写公开行。**绝不回退到 `[PASS]` 文本匹配**，也不为 `group_react` 写 tool 行。
  Future<AgentRunResult> _finishStructuredReaction({
    required List<Map<String, dynamic>> reactCalls,
    required int epoch,
    required int inputTokens,
    required int outputTokens,
    required String? thinkingJsonStr,
    required List<Map<String, dynamic>> allTurnToolCalls,
  }) async {
    final decision = parseGroupReactDecision(reactCalls);
    if (decision.isFailed) {
      if (!_isActive(epoch)) {
        _endStreaming();
        return _cancelledRun();
      }
      // 缺调用 / 参数非法：不写公开行、不写公开 Error 行；步骤由上层记 failed。
      _endStreaming();
      return AgentRunResult.failed(
        error: decision.error ?? kInvalidGroupReactError,
        metering: _meteringSnapshot(),
      );
    }
    // `pass=true` 时 message 被忽略（连「我这回合不发言」这类元话术一起吞掉），
    // 只用它作为 finalText 供调用方观察；时间线看不到。
    final message = decision.message ?? '';
    final blank = decision.isSpeak && message.trim().isEmpty;
    Message? publicMessage;
    if (decision.isSpeak && !blank) {
      final toolCallsJson = allTurnToolCalls.isNotEmpty
          ? jsonEncode(allTurnToolCalls)
          : null;
      final isGroupMember = member != null;
      final assistantMsg = await messageRepo.insert(
        sessionId: sessionId,
        role: 'assistant',
        content: message,
        toolCallsJson: isGroupMember ? null : toolCallsJson,
        thinkingJson: isGroupMember ? null : thinkingJsonStr,
        tokenCount: inputTokens,
        outputTokenCount: outputTokens,
        author: member?.memberId,
        visibility: Message.visibilityPublic,
      );
      await sessionRepo.touch(sessionId);
      if (isGroupMember) {
        await assembleMemberView();
      } else {
        _history.add(assistantMsg);
      }
      callbacks.onAssistantMessage?.call(assistantMsg, true);
      publicMessage = assistantMsg;
    }
    if (!_isActive(epoch)) return _cancelledRun();
    _endStreaming();
    _maybeScheduleBackgroundFold();
    return AgentRunResult.completed(
      finalText: message,
      metering: _meteringSnapshot(),
      publicMessage: publicMessage,
      reactionPassed: decision.isPass,
    );
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

  /// 本轮装配的思考模式与强度（D7 的解析点；推导规则与创建时同一处：D6）。
  ///
  /// 显式档取**当前模板**的 `thinking_effort`（用户刚保存的那个值），目录取**当前**
  /// Provider 配置里该模型条目的 `reasoningEfforts`。模型本身仍用创建时冻结的
  /// [ResolvedAgentConfig.model]（D7 明确模型不热更新）—— 拿"未来模型"的档位去驱动
  /// "当前模型"的请求会造成第二个口径。
  /// 本实例当前生效的覆盖层：每轮现读（思考强度热更新），读不到时退回创建时快照。
  Future<AgentInstanceOverrides?> _currentOverrides() async {
    final lookup = overridesLookup;
    if (lookup != null) {
      try {
        final fresh = await lookup();
        if (fresh != null) return fresh;
      } catch (e) {
        debugPrint('[AliasAgent] 覆盖层重读失败，沿用创建时快照：$e');
      }
    }
    return overrides;
  }

  Future<({String mode, String effort})> _resolveRoundThinking() async {
    final lookupTemplate = templateLookup;
    final lookupProvider = providerLookup;
    if (lookupTemplate == null && lookupProvider == null) {
      // 没有注入查找器（直接构造 Agent 的测试路径）：用创建时解析出的冻结快照。
      return (mode: config.thinkingMode, effort: config.thinkingEffort);
    }
    final current = lookupTemplate?.call(agentTypeName) ?? template;
    ModelCatalogEntry? entry;
    for (final candidate
        in lookupProvider?.call(config.providerName)?.models ??
            const <ModelCatalogEntry>[]) {
      if (candidate.id == config.model) {
        entry = candidate;
        break;
      }
    }
    // 覆盖层的思考强度覆盖模板：字段出现即由它决定（显式空串 / 非白名单 ⇒ disabled，
    // 不回落模板推导）；字段缺席才按模板 + 目录推导。逐轮生效 = 既有热更新口径
    // （下一消息起作用，工具与提示词不动）。
    final override = await _currentOverrides();
    final overrideEffort = override?.hasThinkingEffort == true
        ? (override!.thinkingEffort ?? '')
        : null;
    return AgentConfigResolver.resolveThinking(
      explicitEffort: overrideEffort ?? current.thinkingEffort,
      entry: entry,
    );
  }

  // ---------------------------------------------------------------------------
  // 模型调用与工具循环（原 `lib/main.dart` 的 `_callModel`）
  // ---------------------------------------------------------------------------

  Future<AgentRunResult> _callModel({
    required List<Message> messages,
    required int epoch,
    bool reaction = false,
    bool mustRespond = false,
  }) async {
    final baseUrl = _provider.baseUrl.isNotEmpty
        ? _provider.baseUrl
        : 'https://api.anthropic.com';

    // 每轮请求装配的开头先增量刷新一次技能目录（change
    // `refresh-skill-catalog-each-turn` design D2）：本方法里的 `toolDefinitions`
    // 组装与下面循环里的 `promptSection` 读取都在这一处之后，所以"一轮装配刷新一次"
    // 就落在这里 —— 同一轮的多次模型请求（工具轮）共用这一份快照（一轮内视图一致），
    // 磁盘上的技能改动到**下一轮装配**才反映。
    // **不许**放进工具派发（`_dispatchToolCall`）：那会让同一轮里前后两次请求看到
    // 不同的目录，破坏"一轮内一致"。
    await SkillCatalogService.instance.scan();

    // D7：思考模式与强度在**每轮装配**这里按最新模板 + 最新目录重解析一次，并写进
    // 本轮局部变量。本轮内所有模型请求（含工具轮）共用这一份 —— 所以保存发生在
    // 某轮工具循环进行中时，该轮已发出的请求与后续请求都还是旧档，改动从**下一轮
    // 装配**（下一条消息）起生效。窗口/工具/模型/系统提示词仍读冻结的 [config]。
    final roundThinking = await _resolveRoundThinking();

    // 实际发送的工具定义 = 本实例生效配置 ∩ 工具目录；未知名字在这里显式失败（
    // 创建路径已经校验过一次，这里保持同一判据，避免绕过目录）。
    //
    // 反应轮额外注入**终态控制工具** `group_react`（change `group-reactive-mode`
    // R.10 / design D5）：它不进工具目录、不写 tool 行，模型循环拦截它并结束本轮。
    // 普通轮（单会话 / 关闭态纯 speaker / 非反应轮）的工具清单逐字不变。
    final effectiveToolDefinitions = reaction
        ? <Map<String, dynamic>>[
            ...toolDefinitions,
            kGroupReactToolDefinition,
          ]
        : toolDefinitions;
    final toolsJson = jsonEncode(effectiveToolDefinitions);

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

    /// R.11：结构化调用不合规时，把模型这一轮的内容与纠正要求追加进请求上下文，
    /// **类似工具执行失败后的错误反馈**，然后重新请求（不写库、不产生公开行）。
    var reactRetries = 0;
    void appendGroupReactCorrection({
      required String error,
      required String turnText,
      required List<Map<String, dynamic>> calls,
    }) {
      final blocks = <Map<String, dynamic>>[];
      if (turnText.trim().isNotEmpty) {
        blocks.add({'type': 'text', 'text': turnText});
      }
      for (final call in calls) {
        blocks.add({
          'type': call['type'] ?? 'tool_use',
          'id': call['id'] ?? 'group_react_retry_$reactRetries',
          'name': kGroupReactToolName,
          'input': call['input'] ?? <String, dynamic>{},
        });
      }
      if (blocks.isEmpty) {
        blocks.add({'type': 'text', 'text': '（本轮没有调用任何工具）'});
      }
      apiMessages
        ..add({'role': 'assistant', 'content': blocks})
        ..add({
          'role': 'user',
          'content': groupReactCorrectionPrompt(error),
        });
    }

    var turn = 0;
    while (true) {
      if (!_isActive(epoch)) return _cancelledRun();
      final messagesJson = jsonEncode(apiMessages);

      var turnText = '';
      final turnToolCalls = <Map<String, dynamic>>[];
      // R.10：本轮的 `group_react` 终态调用（被拦截，不进工具执行器、不写 tool 行）。
      final reactCalls = <Map<String, dynamic>>[];
      final turnThinkingBlocks = <Map<String, dynamic>>[];
      var doneCode = 0;
      String? doneError;
      var lastInputTokens = 0;
      var lastOutputTokens = 0;

      final thinkingMode = roundThinking.mode;
      final thinkingEffort = roundThinking.effort;
      // 系统提示词：模板提示 + 每轮动态段（`guard.inject()`）+ 技能段 + 日期。
      // 技能段紧随 `guard.inject()` 之后（change `add-skill-mechanism` design D4），
      // **不受模板工具清单影响**：每个模板都收到它。段内分两种形态（返工 5.1，
      // design D6）：有生效技能 = "Available skills" 标题 + 清单 + 创建简则；没有生效
      // 技能 = **只有创建简则**（不再整段消失，也不留空悬的标题/清单行）。技能段的
      // token 由下面这整段估算覆盖，因此自动计入 `fixedOverheadTokens`。
      final skillSection = SkillCatalogService.instance.promptSection;
      // 群成员名单**每轮现读**（change `group-member-identity`）：不缓存，成员增减
      // 下一轮系统提示词就更新；已移除成员不进名单（历史归属仍保留）。
      final rosterSection = await _groupRosterSection();
      final systemPromptBuffer = StringBuffer()
        ..write(config.systemPrompt);
      if (rosterSection != null) {
        systemPromptBuffer
          ..write('\n\n')
          ..write(rosterSection);
      }
      systemPromptBuffer
        ..write('\n')
        ..write(guard.inject());
      if (skillSection.isNotEmpty) {
        // 现在的 `promptSection` 恒非空（空集合也返回简则），这里保留判断是防御性写法：
        // 段真为空时仍不留空行。
        systemPromptBuffer
          ..write('\n')
          ..write(skillSection);
      }
      systemPromptBuffer
        ..write('\nCurrent date: ')
        ..write(DateTime.now().toIso8601String().substring(0, 10))
        ..write('. For precise time-sensitive queries, use the get_current_time tool.');
      // 反应轮的纪律**追加在系统提示词末尾**（change `group-reactive-mode` D6）：
      // - 必应轮（开启态 speaker / 两态 @mention）⇒ `kGroupMustRespondPrompt`；
      // - 自愿反应轮（开启态）⇒ `kGroupReactionPrompt`（强烈授权沉默）。
      // 两段都**不是**替换 `kGroupMemberRolePrompt`（那一段在实例创建时已叠进
      // `config.systemPrompt`），所以反应轮同时看得到角色说明与当轮纪律。
      // 普通轮（单会话 / 关闭态纯 speaker）不追加任何一段，行为逐字不变。
      if (reaction) {
        systemPromptBuffer
          ..write('\n\n')
          ..write(mustRespond ? kGroupMustRespondPrompt : kGroupReactionPrompt);
      }
      final systemPrompt = systemPromptBuffer.toString();

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
        handle: handle,
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
            // `group_react` 是**终态控制工具**（R.10）：拦截它、不交给工具执行器、
            // 不写 tool 行、不产生工具活动卡片。本轮结束时按结构化 pass 收尾。
            if (reaction && tc['name'] == kGroupReactToolName) {
              reactCalls.add(tc);
              return;
            }
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

      // **结构化终态**（change `group-reactive-mode` R.10 / design D5）：反应轮里
      // 模型调用 `group_react` 就是这一轮的终点——不论正文写了什么、也不论同轮是否
      // 还有普通工具调用，一律按 `pass` / `message` 收尾，并且：
      //   - 不执行 group_react、不为它写 tool 行、不发工具活动卡片；
      //   - `pass=true` ⇒ 不写公开行（message 里的元话术一起吞掉）；
      //   - `pass=false` ⇒ 公开行只写 message；
      //   - 参数非法 / 多次调用 ⇒ 先**纠正重试**（R.11），超限才 failed 且不写公开行
      //     （不回退文本匹配）。
      if (reactCalls.isNotEmpty) {
        final decision = parseGroupReactDecision(reactCalls);
        if (decision.isFailed && reactRetries < kMaxGroupReactRetries) {
          reactRetries++;
          debugPrint('[AliasAgent] group_react 不合规（${decision.error}）：'
              '第 $reactRetries/$kMaxGroupReactRetries 次纠正重试');
          appendGroupReactCorrection(
            error: decision.error ?? kInvalidGroupReactError,
            turnText: turnText,
            calls: reactCalls,
          );
          continue;
        }
        return _finishStructuredReaction(
          reactCalls: reactCalls,
          epoch: epoch,
          inputTokens: lastInputTokens,
          outputTokens: lastOutputTokens,
          thinkingJsonStr: thinkingJsonStr,
          allTurnToolCalls: allTurnToolCalls,
        );
      }

      // 没有工具调用 ⇒ 最终回复，落库并结束这一轮。只有这一条分支能产生成功
      // 结果的文本；中间工具轮的文本绝不作为最终结论。
      if (turnToolCalls.isEmpty) {
        // 反应轮却没有调用 `group_react`：R.11 先像工具失败那样回一条纠正消息并重试；
        // 超过上限才记可归因失败（不写公开行、不回退到 `[PASS]` 文本匹配）。
        // 这一步不是"空输出"——那是 pass=false + 空 message。
        if (reaction) {
          if (reactRetries < kMaxGroupReactRetries) {
            reactRetries++;
            debugPrint('[AliasAgent] 反应轮缺 group_react：'
                '第 $reactRetries/$kMaxGroupReactRetries 次纠正重试');
            appendGroupReactCorrection(
              error: kMissingGroupReactError,
              turnText: turnText,
              calls: const [],
            );
            continue;
          }
          if (!_isActive(epoch)) {
            _endStreaming();
            return _cancelledRun();
          }
          _endStreaming();
          return AgentRunResult.failed(
            error: kMissingGroupReactError,
            metering: _meteringSnapshot(),
          );
        }
        // 普通轮（单会话 / 关闭态纯 speaker / 非反应轮）保持既有 `isNotEmpty` 判定
        // **逐字不变**：`[PASS]` 是普通正文，纯空白照旧按旧行为处理。
        final writePublic = turnText.isNotEmpty;
        Message? publicMessage;
        if (writePublic) {
          final toolCallsJson = allTurnToolCalls.isNotEmpty
              ? jsonEncode(allTurnToolCalls)
              : null;
          // 组成员的**最终公开行只存正文**（design D1）：tool_calls 与 thinking_json
          // 都是 NULL、无附件 —— 私有证据只落 private 行，隐私不靠"映射时记得过滤"。
          // 单会话保持变更前的行为（该会话不存在跨成员投影）。
          final isGroupMember = member != null;
          final assistantMsg = await messageRepo.insert(
            sessionId: sessionId,
            role: 'assistant',
            content: turnText,
            toolCallsJson: isGroupMember ? null : toolCallsJson,
            thinkingJson: isGroupMember ? null : thinkingJsonStr,
            tokenCount: lastInputTokens,
            outputTokenCount: lastOutputTokens,
            author: member?.memberId,
            visibility: Message.visibilityPublic,
          );
          await sessionRepo.touch(sessionId);
          if (isGroupMember) {
            await assembleMemberView();
          } else {
            _history.add(assistantMsg);
          }
          callbacks.onAssistantMessage?.call(assistantMsg, true);
          publicMessage = assistantMsg;
        }
        if (!_isActive(epoch)) return _cancelledRun();
        _endStreaming();
        _maybeScheduleBackgroundFold();
        return AgentRunResult.completed(
          finalText: turnText,
          metering: _meteringSnapshot(),
          publicMessage: publicMessage,
        );
      }

      // 有工具调用 ⇒ 先把中间 assistant 消息落库（工具调用记录在工具执行后补写）。
      if (!_isActive(epoch)) return _cancelledRun();
      allTurnToolCalls.addAll(turnToolCalls);
      final turnJson = jsonEncode(turnToolCalls);
      // 工具轮的中间行对组成员是**私有证据**（author = 成员 id、
      // visibility = private-to-author）：thinking 与工具调用只存在这里。
      final intermediateMsg = await messageRepo.insert(
        sessionId: sessionId,
        role: 'assistant',
        content: turnText,
        toolCallsJson: turnJson,
        thinkingJson: thinkingJsonStr,
        tokenCount: lastInputTokens,
        outputTokenCount: lastOutputTokens,
        author: member?.memberId,
        visibility: member == null
            ? Message.visibilityPublic
            : Message.visibilityPrivateToAuthor,
      );
      await sessionRepo.touch(sessionId);
      if (member != null) {
        await assembleMemberView();
      } else {
        _history.add(intermediateMsg);
      }
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
      // 执行分组（design D1/D6）：连续的只读调用合并成一个并发段，写类 / 有状态 /
      // 未知名字各自单独成段；配置项 `tool.parallel_max` 决定单个并发段一次最多
      // 同时启动几个成员（0 = 不设上限）。
      final groups = planToolGroups(
        [for (final tc in turnToolCalls) (tc['name'] as String?) ?? ''],
        maxParallel: toolParallelMax,
      );
      var toolsCancelled = false;
      for (final group in groups) {
        if (!_isActive(epoch)) {
          toolsCancelled = true;
          break;
        }
        if (!group.concurrent) {
          // 逐个段（段长恒为 1）：完全走原来的执行路径，时序与并行化之前一致。
          final tc = turnToolCalls[group.start];
          final result = await _executeTool(tc);
          if (!_isActive(epoch)) {
            toolsCancelled = true;
            break;
          }
          _deliverToolResult(tc, result, toolResults, turnToolCalls);
        } else {
          final members = turnToolCalls.sublist(group.start, group.end);
          // 并发启动、按段内原始顺序收集：`Future.wait` 的结果顺序就是启动顺序，
          // 与谁先执行完无关（design D3）。
          final results = await Future.wait([
            for (final tc in members) _executeToolConcurrently(tc),
          ]);
          if (!_isActive(epoch)) {
            // 已启动的成员都已自然结束（Future.wait 收齐）：结果全部丢弃。
            toolsCancelled = true;
            break;
          }
          for (var i = 0; i < members.length; i++) {
            _deliverToolResult(members[i], results[i], toolResults, turnToolCalls);
          }
        }
      }
      if (toolsCancelled) {
        // 取消：本轮不追加 tool_result（不会进入模型请求）。**所有**还没有结果的
        // 调用（跑完被丢弃的、以及后面还没轮到就取消的）都要在卡片与 toolCallsJson
        // 里留下同一条取消说明 —— 否则历史重放会把它读成"工具返回了空"（D4）。
        for (final tc in turnToolCalls) {
          if (tc['result'] == null) _markToolCancelled(tc);
        }
      }

      // 工具轮写库：整轮写库归属本实例，不读界面当前会话 id。
      // 取消路径同样要写：卡片与 toolCallsJson 的取消说明必须落库（D4）。
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

      // 取消的那一轮到此为止：不把 tool_result 交给模型，也不发下一轮请求。
      if (toolsCancelled) return _cancelledRun();

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
      author: old.author,
      visibility: old.visibility,
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
      final messages = member == null
          ? await messageRepo.queryBySession(sessionId)
          : await _memberViewForRound();
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
      final nodes = await summaryNodeRepo.queryBySession(sessionId,
          memberId: _memberScope);
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
          sessionId: handle);
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
            level: 1, memberId: _memberScope);
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
        folded: msgs, config: template, sessionId: handle);
    if (dbOpen && minSeq != null && maxSeq != null) {
      try {
        await summaryNodeRepo.materialize(
          sessionId: sessionId,
          memberId: _memberScope,
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
        folded: msgs,
        config: template,
        reference: reference,
        sessionId: handle,
        // 组成员的摘要必须保留「Y 说」归属（摘要私有，但只要归属纪律，
        // 不带「自包含 + 文件指针」那条公开回复纪律）。
        systemPromptSuffix: member == null ? null : kGroupSummaryPromptSuffix);
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
            level: seg.reuse!.level, memberId: _memberScope);
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
              level: seg.level, memberId: _memberScope);
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
            sessionId: handle);
        if (dbOpen && minSeq != null && maxSeq != null) {
          debugPrint('[AliasAgent] folding ${seg.messages.length} messages '
              '(seq $minSeq..$maxSeq) into a level-${seg.level} summary');
          try {
            await summaryNodeRepo.materialize(
              sessionId: sessionId,
              memberId: _memberScope,
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
              memberId: _memberScope,
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
          sessionId: handle);
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
            memberId: _memberScope,
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
      // 参考上下文是**第二条泄漏通道**（design D19）：候选只取本人作用域的摘要。
      final nodes = await summaryNodeRepo.queryBySession(sessionId,
          memberId: _memberScope);
      // 双层作用域：查询已按成员过滤，这里再用纯函数过一遍（数据库作用域写错时
      // 仍拦得住 —— 参考块是成员模型的输入，与视图同一隐私边界）。
      return memberScopedReferences(
        [
          for (final n in nodes)
            if (n.summaryJson != null && n.summaryJson!.isNotEmpty)
              (
                memberId: n.memberId,
                reference: SummaryReference(
                  level: n.level,
                  coveredMinSeq: n.coveredMinSeq,
                  coveredMaxSeq: n.coveredMaxSeq,
                  text: _summaryTextFromJson(n.summaryJson!),
                ),
              ),
        ],
        memberId: _memberScope,
      );
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

  // 工具图片路径 / 工具结果内容 / thinking 块清洗 / 请求体装配都搬到了
  // `api_message_builder.dart`：成员视图与单会话必须共用**同一份** replay 实现
  // （agent-group-chat design D2/D9）。这里保留同名入口只做委托，行为逐字不变。
  static String? _toolImagePath(Map<String, dynamic> source) =>
      toolImagePath(source);

  Object _toolResultContent({required String text, String? imagePath}) =>
      toolResultContent(
        text: text,
        imagePath: imagePath,
        acceptsImages: config.acceptsImages,
        model: config.model,
      );

  List<Map<String, dynamic>> _buildApiMessages(List<Message> messages) =>
      buildApiMessages(
        messages,
        acceptsImages: config.acceptsImages,
        model: config.model,
      );

  // ---------------------------------------------------------------------------
  // 工具执行
  // ---------------------------------------------------------------------------

  /// 按段内原始顺序交付一条工具结果（design D3）：
  /// ① 界面回调（按 id 原位更新卡片）；② 请求体 `tool_result`；③ `toolCallsJson` 富化。
  void _deliverToolResult(
    Map<String, dynamic> tc,
    Map<String, dynamic> result,
    List<Map<String, dynamic>> toolResults,
    List<Map<String, dynamic>> turnToolCalls,
  ) {
    final resultContent = result['ok'] == true
        ? (result['content'] as String? ?? '')
        : (result['error'] as String? ?? 'Tool failed');

    final toolId = (tc['id'] as String?) ?? '';
    final toolName2 = (tc['name'] as String?) ?? '';
    final isSearchTool = toolName2 == 'web_search' || toolName2 == 'web_fetch';
    final activity = ToolCallActivity(
      id: toolId,
      toolName: toolName2,
      input: (tc['input'] as Map<String, dynamic>?) ?? {},
      status: result['ok'] == true ? ToolCallStatus.done : ToolCallStatus.error,
      result: resultContent,
      resultPreview: resultContent.length > 300
          ? '${resultContent.substring(0, 300)}...'
          : resultContent,
      resultSections: isSearchTool ? _buildResultSections(toolName2, result) : null,
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
    callbacks.onToolResult?.call(activity);

    toolResults.add({
      'type': 'tool_result',
      'tool_use_id': tc['id'] ?? '',
      'content': _toolResultContent(
        text: resultContent,
        imagePath: _toolImagePath(result),
      ),
    });

    // 工具结果只写进这一轮的 toolCallsJson（DB）与请求体。
    for (var i = 0; i < turnToolCalls.length; i++) {
      if (turnToolCalls[i]['id'] == toolId) {
        turnToolCalls[i].addAll(activity.toJson());
        break;
      }
    }
  }

  /// 本轮被取消、结果不取回：把卡片置为终态并写入同一句取消说明（design D4）。
  ///
  /// 这里**不**检查 `_isActive`：取消收尾的目的正是把还停在"执行中"的卡片清掉，
  /// 让界面与历史都看得出"这个工具没有结果、原因是取消"，而不是一片空文本。
  void _markToolCancelled(Map<String, dynamic> tc) {
    // 两个说法都来自 delta spec：Requirement 要求写「本轮被取消，该工具结果未取回」，
    // 场景要求带「因取消未取回结果」的说明 —— 一句话里两段都在。
    const note = '因取消未取回结果（本轮被取消，该工具结果未取回）。';
    final activity = ToolCallActivity(
      id: (tc['id'] as String?) ?? '',
      toolName: (tc['name'] as String?) ?? '',
      input: (tc['input'] as Map<String, dynamic>?) ?? {},
      status: ToolCallStatus.error,
      result: note,
      resultPreview: note,
    );
    callbacks.onToolResult?.call(activity);
    tc.addAll(activity.toJson());
  }

  /// 逐个段 / 段长 1 的执行入口：与并行化之前完全同一条路径。
  Future<Map<String, dynamic>> _executeTool(
      Map<String, dynamic> toolCall) async {
    final resultJson = await _dispatchToolCall(toolCall, onWorker: false);
    return _postProcessToolResult(toolCall, resultJson);
  }

  /// 并发段里单个成员的执行：任何异常都转成带工具名与原因的 ok:false（design D5），
  /// 不影响同段其它成员。
  Future<Map<String, dynamic>> _executeToolConcurrently(
      Map<String, dynamic> toolCall) async {
    final name = (toolCall['name'] as String?) ?? '';
    try {
      final resultJson = await _dispatchToolCall(toolCall, onWorker: true);
      return _postProcessToolResult(toolCall, resultJson);
    } catch (e) {
      // 不许用不含原因的通用文案顶替：工具名 + 异常原文都要在。
      return <String, dynamic>{'ok': false, 'error': '$name: $e'};
    }
  }

  /// 把一次工具调用派给 sidecar。`onWorker` 为真时，六个同步只读工具改走 worker
  /// isolate（只有并发段会这么调，段长 ≥2 才真正重叠）；其余工具本来就有独立的
  /// 异步入口，`get_current_time` 是纯 Dart，都在主 isolate 完成。
  Future<String> _dispatchToolCall(
      Map<String, dynamic> toolCall, {required bool onWorker}) async {
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
        final requestJson = jsonEncode(readReq);
        resultJson = onWorker
            ? await sidecar.callToolOnWorker('read_file', handle, requestJson)
            : sidecar.readFile(handle, requestJson);
      case 'write_file':
        resultJson = sidecar.writeFile(handle, jsonEncode({
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
              handle, jsonEncode({'path': path, 'edits': edits}));
        }
      case 'list_dir':
        resultJson = onWorker
            ? await sidecar.callToolOnWorker('list_dir', handle, path)
            : sidecar.listDir(handle, path);
      case 'glob_file':
        final requestJson = jsonEncode({
          'pattern': input['pattern'] ?? '',
          'max_results': input['max_results'] ?? 200,
        });
        resultJson = onWorker
            ? await sidecar.callToolOnWorker('glob_file', handle, requestJson)
            : sidecar.globFile(handle, requestJson);
      case 'grep_file':
        final requestJson = jsonEncode({
          'pattern': input['pattern'] ?? '',
          'glob': input['glob'] ?? '',
          'ignore_case': input['ignore_case'] ?? false,
          'max_results': input['max_results'] ?? 100,
        });
        resultJson = onWorker
            ? await sidecar.callToolOnWorker('grep_file', handle, requestJson)
            : sidecar.grepFile(handle, requestJson);
      case 'web_search':
        final request = jsonEncode({
          'query': input['query'] ?? '',
          'providers': input['providers'] ?? <String>[],
          'depth': input['depth'] ?? 'basic',
          'max_results': input['max_results'] ?? 5,
        });
        resultJson = await sidecar.webSearch(handle, request);
      case 'web_fetch':
        // `preview_chars` 与 `run_command` 同形态随请求传下去（C++ 侧按它决定
        // 头尾各留多少字符；缺省回落是 `spill::kDefaultPreviewChars`）。值来自顶层
        // 配置 `spill.preview_chars`，执行侧不读配置文件。
        final request = jsonEncode({
          'url': input['url'] ?? '',
          'preview_chars': config.spillPreviewChars,
        });
        resultJson = await sidecar.webFetch(handle, request);
      case 'browser_navigate':
        resultJson = await sidecar.browserNavigate(
            handle, jsonEncode({'url': input['url'] ?? ''}));
      case 'browser_click':
        resultJson = await sidecar.browserClick(
            handle, jsonEncode({'selector': input['selector'] ?? ''}));
      case 'browser_type':
        resultJson = await sidecar.browserType(handle, jsonEncode({
          'selector': input['selector'] ?? '',
          'text': input['text'] ?? '',
        }));
      case 'browser_snapshot':
        resultJson = await sidecar.browserSnapshot(handle, jsonEncode({}));
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
        resultJson = await sidecar.runCommand(handle, jsonEncode(request));
      case 'read_spill':
        final requestJson = jsonEncode({
          'ref': input['ref'] ?? '',
          if (input['offset'] is int) 'offset': input['offset'],
          if (input['limit'] is int) 'limit': input['limit'],
          'preview_chars': config.spillPreviewChars,
        });
        resultJson = onWorker
            ? await sidecar.callToolOnWorker('read_spill', handle, requestJson)
            : sidecar.readSpill(handle, requestJson);
      case 'load_skill':
        // 第一道闸（change `add-skill-mechanism` design D6）：技能名必须在本进程的
        // **生效技能集合**里。目录存在但校验失败的技能也在这里被挡下 —— 它的正文
        // 不许交给模型。不在集合时不触 FFI，直接给带原因的 `ok:false`。
        final skillName = (input['skill'] as String?) ?? '';
        final skillService = SkillCatalogService.instance;
        if (!skillService.isActive(skillName)) {
          final failureReason = skillService.failureReasonFor(skillName);
          final reason = failureReason != null
              ? '校验失败：$failureReason'
              : '不在技能目录的生效集合里（当前生效技能：'
                  '${skillService.activeSkillNames.isEmpty ? '无' : skillService.activeSkillNames.join('、')}）';
          resultJson = jsonEncode(<String, dynamic>{
            'ok': false,
            'error': '技能 "$skillName" 未生效：$reason',
          });
        } else {
          final request = <String, dynamic>{'skill': skillName};
          final file = input['file'];
          if (file is String && file.isNotEmpty) request['file'] = file;
          // `preview_chars` 与 `web_fetch` 同形透传（C++ 侧缺省回落
          // `spill::kDefaultPreviewChars`；执行侧不读配置文件）。
          request['preview_chars'] = config.spillPreviewChars;
          resultJson = await sidecar.loadSkill(handle, jsonEncode(request));
        }
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
          final requestJson = jsonEncode({'path': path});
          resultJson = onWorker
              ? await sidecar.callToolOnWorker('read_image', handle, requestJson)
              : sidecar.readImage(handle, requestJson);
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
    return resultJson;
  }

  /// 结果后处理：解析 sidecar 返回的 JSON，并按工具补上给模型看的展示文本。
  ///
  /// 解析失败时错误文本必须带工具名与实际异常（design D5：不得用不含原因的通用
  /// 文案顶替 —— 并行化之前这里只写一句 'Failed to parse tool result'）。
  Map<String, dynamic> _postProcessToolResult(
      Map<String, dynamic> toolCall, String resultJson) {
    final name = toolCall['name'] as String?;
    final input = (toolCall['input'] as Map<String, dynamic>?) ?? {};
    final path = (input['path'] as String?) ?? '';
    try {
      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      if (name == 'web_search') {
        parsed['content'] = _formatSearchResultForDisplay(name!, parsed);
      } else if (name == 'web_fetch') {
        // 正文由 C++ 侧 spill 形状决定，这里只负责外壳拼装（标题 / 网址 / 引用行）。
        parsed['content'] = _composeWebFetchResultText(parsed);
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
      } else if (name == 'load_skill' && parsed['ok'] == true) {
        // 成功结果的模型可见正文：首行说明加载了哪个技能（或哪个附属文件），正文是
        // C++ 侧 spill 形状后的文本，落了盘时**最后一行**是 spill 引用（截断可见、
        // `read_spill` 可恢复）。失败结果不带正文，交给 `error` 字段。
        parsed['content'] = _composeSkillResultText(parsed, input);
      }
      return parsed;
    } catch (e) {
      debugPrint('[AliasAgent] _executeTool parse error: $e');
      return {
        'ok': false,
        'error': '${name ?? 'unknown'}: 工具结果解析失败：$e',
      };
    }
  }

  String _formatSearchResultForDisplay(
      String toolName, Map<String, dynamic> result) {
    if (result['ok'] != true) {
      final error = (result['error'] as String?) ?? 'Unknown error';
      return error.length > 200 ? '${error.substring(0, 200)}...' : error;
    }
    if (toolName == 'web_search') {
      return assembleSearchText(result, budget: kToolResultElisionThreshold);
    }
    // `web_fetch` 不再走这里：正文是 C++ 侧 spill 形状后的文本，外壳（标题 / 网址 /
    // 引用行）由 `_composeWebFetchResultText` 拼，旧的 2000 字符硬切随之删除。
    return '';
  }

  /// `web_fetch` 的**模型可见正文**（delta spec「web_fetch 结果交付给模型的形态」）：
  /// 第一行标题（`title` 为空时用网址）、第二行网址、正文（C++ 侧 spill 形状后的
  /// 内联文本），落了盘时**最后一行**是 spill 引用行。
  ///
  /// 引用行必须放最后：重放阶段通用省略只保头尾，放中间等于被自己掐掉；它同时是
  /// [bodyHasSpillRefs] 判断"中段还能不能按 read_spill 读回"的依据。
  ///
  /// 旧行为"正文超过 2000 字符就切成前 2000 个加三个点"已删除 —— 那个数字没有出处，
  /// 且切完既不说略去多少、也不给取回办法（违反"砍内容必须可见、可见之后必须可
  /// 恢复"）。空正文的 `(fetched empty page)` 提示保留，且此时不产生 spill 引用。
  String _composeWebFetchResultText(Map<String, dynamic> result) {
    final body = (result['content'] as String?) ?? '';
    final title = (result['title'] as String?) ?? '';
    final url = (result['url'] as String?) ?? '';

    final sb = StringBuffer();
    final firstLine = title.isNotEmpty ? title : url;
    if (firstLine.isNotEmpty) sb.writeln(firstLine);
    if (url.isNotEmpty) sb.writeln(url);
    if (body.isEmpty) {
      sb.write('(fetched empty page)');
      return sb.toString().trimRight();
    }
    sb.write(body);

    final spill = result['spill'];
    if (spill is Map) {
      final env = spill['content'];
      if (env is Map) {
        final ref = (env['ref'] as String?) ?? '';
        if (ref.isNotEmpty) {
          final total = env['total_bytes'] ?? 0;
          final omitted = env['omitted_bytes'] ?? 0;
          sb.writeln();
          sb.write('$kSpillRefsMarker content=$ref ($total bytes, $omitted omitted) — '
              'read any byte range back with read_spill(ref, offset, limit)]');
        }
      }
    }
    return sb.toString().trimRight();
  }

  /// `load_skill` 的**模型可见正文**（change `add-skill-mechanism` 任务 5.2）：
  /// 首行 `skill "<name>"`（带 `file` 时是 `skill "<name>" (file: <相对路径>)`），
  /// 正文是 C++ 侧 spill 形状后的文本，落了盘时**最后一行**是 spill 引用说明。
  ///
  /// 引用行放最后的理由与 `web_fetch` 相同：重放阶段的通用省略只保头尾，放中间会被
  /// 自己掐掉；它也是 [bodyHasSpillRefs] 判断"中段还能不能按 read_spill 读回"的依据。
  String _composeSkillResultText(
      Map<String, dynamic> result, Map<String, dynamic> input) {
    final skill = (input['skill'] as String?) ?? '';
    final file = (input['file'] as String?) ?? '';
    final sb = StringBuffer();
    sb.write(file.isEmpty
        ? 'skill "$skill"'
        : 'skill "$skill" (file: $file)');
    final body = (result['content'] as String?) ?? '';
    if (body.isNotEmpty) {
      sb.write('\n');
      sb.write(body);
    }

    final spill = result['spill'];
    if (spill is Map) {
      final env = spill['skill'];
      if (env is Map) {
        final ref = (env['ref'] as String?) ?? '';
        if (ref.isNotEmpty) {
          final total = env['total_bytes'] ?? 0;
          final omitted = env['omitted_bytes'] ?? 0;
          sb.write('\n');
          sb.write('$kSpillRefsMarker skill=$ref ($total bytes, $omitted omitted) — '
              'read any byte range back with read_spill(ref, offset, limit)]');
        }
      }
    }
    return sb.toString().trimRight();
  }

  List<ResultSection> _buildResultSections(
      String toolName, Map<String, dynamic> result) {    if (result['ok'] != true) return [];
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
      // 卡片拿到的就是发给模型的那一份字符串（`_postProcessToolResult` 已拼好：
      // 标题 / 网址 / C++ 形状后的正文 / 引用行），不另取未形状化的全文、也不另切。
      // 结果行的 200 字符折叠摘要是 `tool_call_card.dart` 的 `_buildItem` 按这份
      // 字符串的开头做的，不构成第二份正文。
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
    sidecar.cancelRequest(handle);
    _setStreaming(false);
  }

  Future<void> _storeError(String message) async {
    final errorMsg = await messageRepo.insert(
      sessionId: sessionId,
      role: 'assistant',
      content: 'Error: $message',
      author: member?.memberId,
      visibility: Message.visibilityPublic,
    );
    await sessionRepo.touch(sessionId);
    if (member != null) {
      await assembleMemberView();
    } else {
      _history.add(errorMsg);
    }
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