// 组服务：组/成员生命周期、调度、共享工作区与"本次运行内最近一次真实发出"的快照
// （change `agent-group-chat` §5 / design D5、D7、D10）。
//
// 关键口径：
//   - `group.create` 先建组上下文（`ensureContext(groupId, workspace ?? 默认工作区)`）；
//   - 成员创建经 `sidecar.getWorkspace(groupId)` **继承**组工作区（走生产路径，不靠手工
//     setWorkspace）；
//   - 调度是「用户点名一个 + **每组一个吸收式执行器**」：`group.send` **永不**因执行器
//     在跑而拒绝；新请求写用户消息后入队，由执行器在轮边界吸收（同一时刻至多一条链在
//     写原文，但这是内部调度细节）；
//   - 两个前置门：不带文本且视图为空 / 不带文本且最后可见项是本人 assistant；
//   - `group.view` 只返回本次运行内最近一次**真实发出**的快照（重启后为空是既定语义）。
import 'dart:async';

import 'package:path/path.dart' as p;

import 'context_snapshot.dart';
import '../models/agent_type_config.dart';
import '../models/group_member.dart';
import '../models/instance_overrides.dart';
import '../models/message.dart';
import '../models/session.dart';
import 'agent.dart';
import 'agent_factory.dart';
import 'agent_registry.dart';
import 'agent_type_registry.dart';
import 'config_service.dart';
import 'group_member_repository.dart';
import 'group_reaction.dart';
import 'group_view_loader.dart';
import 'logging.dart';
import 'message_repository.dart';
import 'session_repository.dart';
import 'sidecar_bridge.dart';
import 'summary_node_repository.dart';
import 'tool_catalog.dart';
import 'workspace.dart';

/// 可归因的组服务错误（RPC 层直接转成 JSON-RPC 错误）。
class GroupException implements Exception {
  const GroupException(this.code, this.message);

  /// `group_not_found` / `member_not_found` / `member_removed` / `no_speaker` /
  /// `empty_view` / `prefill` / `busy` / `workspace_unavailable` / `not_running`。
  final String code;
  final String message;

  @override
  String toString() => message;
}

/// 反应链的一个 step（RPC 契约的一部分，change `group-reactive-mode` D9）。
///
/// `source` / `status` 的取值是**封闭枚举**（见 `group_reaction.dart` 的
/// `kReactionStepSources` / `kReactionStepStatuses`）；本类只负责把它们带到
/// `group.send` 的结果里，**不是第二套消息存储**。
class GroupSendStep {
  const GroupSendStep({
    required this.memberId,
    required this.source,
    required this.status,
    this.triggerSeq,
    this.publicSeq,
    this.finalText,
    this.error,
  });

  final String memberId;

  /// `speaker` / `mention` / `reaction`。
  final String source;

  /// `replied` / `passed` / `forced_pass` / `forced_empty` / `empty` / `failed` /
  /// `cancelled`。
  final String status;

  /// 这一步回应的是哪条公开消息的 seq（安静态的定向轮可为 null）。
  final int? triggerSeq;

  /// 这一步产生的公开行 seq（`replied` 时非空）。
  final int? publicSeq;

  final String? finalText;
  final String? error;

  bool get isFailure => status == 'failed';

  Map<String, dynamic> toJson() => {
        'memberId': memberId,
        'source': source,
        'status': status,
        'triggerSeq': triggerSeq,
        'publicSeq': publicSeq,
        'finalText': finalText,
        'error': error,
      };
}

/// 一次群发送的**同步回包**（change `group-reactive-mode` R.2/R.8 / design D3 / D9）。
///
/// 异步契约：`started` = 前置校验与（若有文本的）用户消息写入已完成、请求已入执行器
/// 队列并在后台跑。**`group.send` 永不返回 busy**：执行器在跑时新请求照常入队/被吸收。
/// 回包**不再携带** `steps` / `rounds` / `finalText` / `memberId` —— 链进度只从
/// `group.chain` 与 `group.chain.completed` 读。
class GroupSendOutcome {
  const GroupSendOutcome({
    required this.status,
    this.triggerSeq,
    this.error,
  });

  /// 恒为 `started`（保留字段是为了回包形状稳定；没有 busy 分支）。
  final String status;

  /// 带文本时 = 用户消息 seq；speaker-only 时为 null（由链状态后续更新）。
  final int? triggerSeq;

  final String? error;

  bool get isStarted => status == 'started';

  Map<String, dynamic> toJson() => {
        'status': status,
        'triggerSeq': triggerSeq,
        if (error != null) 'error': error,
      };
}

/// 一条链在某时刻的**只读快照**（`group.chain` 的返回体；change
/// `group-reactive-mode` R.2 / D9）。
///
/// `steps` 只用于观察与测试，**不是第二套消息存储**。
class GroupChainSnapshot {
  const GroupChainSnapshot({
    required this.groupId,
    required this.status,
    required this.rounds,
    required this.steps,
    this.triggerSeq,
    this.stopReason,
    this.error,
  });

  final String groupId;

  /// `idle` / `running` / `completed` / `cancelled` / `failed`
  /// （封闭枚举见 `kGroupChainStatuses`）。
  final String status;

  /// 只计**反应轮**；定向轮与安静态 mention 轮不计。
  final int rounds;

  final List<GroupSendStep> steps;

  /// 当前触发：带文本时为用户消息 seq，speaker-only 时在 speaker 产生公开回复后更新。
  final int? triggerSeq;

  /// 运行中为 null；封闭枚举见 `kGroupChainStopReasons`。
  final String? stopReason;

  /// 失败真因（change `group-chat-layout` R.15 / design D13）。
  ///
  /// `failed` 时非空且含可归因文本（provider 错误 / `unknown_context` / 成员轮异常
  /// 原因）；`completed` / `cancelled` / `running` / `idle` 时为 null。界面与测试据它
  /// 显示失败原因，**MUST NOT** 只回 `failed` 把原因吞掉。
  final String? error;

  bool get isRunning => status == 'running';

  Map<String, dynamic> toJson() => {
        'groupId': groupId,
        'sessionId': groupId,
        'status': status,
        'triggerSeq': triggerSeq,
        'rounds': rounds,
        'stopReason': stopReason,
        'error': error,
        'steps': [for (final step in steps) step.toJson()],
      };
}

/// 取消结果：组级或成员级都给出**真话**（不说"查不到实例"）。
class GroupCancelOutcome {
  const GroupCancelOutcome({
    required this.cancelled,
    required this.reason,
    this.memberId,
    this.reactionChainStopped = false,
  });

  final bool cancelled;
  final String reason;
  final String? memberId;

  /// 本次取消是否停掉了整条反应链（change `group-reactive-mode` D7）。
  ///
  /// 带 `memberId` 取消**排队**成员时 `cancelled=false` 但本字段为 true：
  /// 它确实没在运行（不谎报 cancelled），但链被停了（不冒领没发生的事）。
  final bool reactionChainStopped;

  Map<String, dynamic> toJson() => {
        'cancelled': cancelled,
        'reason': reason,
        if (memberId != null) 'memberId': memberId,
        if (reactionChainStopped) 'reactionChainStopped': true,
      };
}

/// 一条**用户请求**在组执行器里的排队条目（change `group-reactive-mode` R.8 / D3）。
///
/// `group.send` 永不因执行器在跑而拒绝：请求写进队列，由执行器在轮边界吸收。
class _QueuedGroupRequest {
  const _QueuedGroupRequest({
    required this.speakerId,
    required this.mentioned,
    required this.userSeq,
    required this.reactionsEnabled,
  });

  final String? speakerId;
  final List<String> mentioned;
  final int? userSeq;
  final bool reactionsEnabled;
}

/// 一个组的**吸收式长驻执行器**状态（R.8 / design D3）。
///
/// 每个组一个：同一时刻至多一条链在写原文。`group.send` 只入队并唤醒它，**永不**
/// 返回 busy。执行器在轮边界吸收最新用户请求（更新触发、重置该用户触发的预算），
/// 队列空且无可反应成员时进入终态；`steps` 是本次执行器运行内累积的步骤，
/// `rounds` 是**当前用户触发**已消耗的反应轮数（吸收新用户消息时重置为 0）。
class _GroupExecutorState {
  _GroupExecutorState({
    required this.groupId,
    required this.participants,
  });

  final String groupId;

  /// 本次执行器运行开始时快照的参与成员 id（中途加入的成员不进本次运行）。
  Set<String> participants;

  /// 排队等待吸收的用户请求（有序；定向 / mention 请求按序执行）。
  final List<_QueuedGroupRequest> queue = [];

  /// `running` / `completed` / `cancelled` / `failed`。
  String status = 'running';

  /// 当前触发 seq。
  int? triggerSeq;

  /// **当前用户触发**已消耗的反应轮数；吸收新用户请求时重置 0。
  int rounds = 0;

  String? stopReason;

  /// 本次执行器运行内累积的步骤。
  final List<GroupSendStep> steps = [];

  /// 已被要求停止（cancel / 结构操作）：停当前轮并清空排队。
  bool cancelled = false;

  /// 当前正在跑的成员（成员间隙为 null）。
  String? runningMemberId;

  /// 最近一个跑过的成员（后台异常兜底时用来归因，不会被清空）。
  String? lastMemberId;

  /// 当前成员的实例（停链时要 cancel 它）。
  Agent? currentAgent;

  /// 终态失败原因（`failed` 时非空）。
  String? error;

  /// 队列循环是否已启动（同一时刻只允许一个循环）。
  bool loopStarted = false;

  /// **当前用户触发**的轮数预算（吸收请求时从组设置读取）。
  int maxRounds = kDefaultMaxReactionRounds;

  /// 当前用户请求对应的自发反应开关快照。
  bool reactionsEnabled = true;

  /// 吸收请求后、下一反应轮要强制的 `@mention` 成员（消费一次即清空）。
  List<String> pendingForcedIds = const [];

  /// 本次执行器运行进入终态的完成信号（`waitForChain` / 测试夹具等它）。
  Completer<void> done = Completer<void>();

  GroupChainSnapshot snapshot() => GroupChainSnapshot(
        groupId: groupId,
        status: status,
        rounds: rounds,
        steps: List<GroupSendStep>.unmodifiable(steps),
        triggerSeq: triggerSeq,
        stopReason: stopReason,
        error: error,
      );
}

class GroupService {
  GroupService({
    required this.sidecar,
    required this.sessionRepo,
    required this.memberRepo,
    required this.messageRepo,
    required this.summaryNodeRepo,
    required this.agents,
    required this.factory,
    required this.templates,
    required this.callbacksForMember,
    this.knownTools,
    this.onUserMessage,
    this.onTitleChanged,
    this.onChainCompleted,
    this.onTurnFailed,
  });

  final ISidecar sidecar;
  final SessionRepository sessionRepo;
  final GroupMemberRepository memberRepo;
  final MessageRepository messageRepo;
  final SummaryNodeRepository summaryNodeRepo;
  final AgentRegistry agents;
  final AgentFactory factory;

  /// 模板注册表（成员加入时校验模板存在）。
  final AgentTypeRegistry templates;

  /// 组成员的事件回调（由核心注入：agent.event 带 groupId/memberId）。
  final AgentCallbacks Function(GroupMember member) callbacksForMember;

  /// 工具目录里已知的工具名（覆盖层校验用；默认读唯一目录）。
  final Set<String> Function()? knownTools;

  /// 组服务**自己写入**用户消息时的回调（change `group-reactive-mode` D9）。
  ///
  /// 只带 `groupId` —— 这条消息没有成员作者，**不许伪造 `memberId`**。核心据此发
  /// `agent.event` 的 `user.message`（事件类型复用既有模型，不新造）。
  final void Function(String groupId, Message message)? onUserMessage;

  /// 组服务自己写入用户消息后，标题真的变了时的回调（发 `session.title`）。
  final void Function(String groupId, String title)? onTitleChanged;

  /// 链进入**任意终态**时的回调（发唯一新增的事件类型 `group.chain.completed`；
  /// change `group-reactive-mode` R.2 / D7）。`steps` 不塞进事件，需要时查
  /// `group.chain`。
  final void Function(GroupChainSnapshot chain)? onChainCompleted;

  /// 成员轮**硬失败**（`step.status == 'failed'`）时的回调（发 `turn.failed`，
  /// 带 memberId；`forced_pass` / `forced_empty` 不走这里）。
  final void Function(String groupId, GroupSendStep step)? onTurnFailed;

  /// 每个组共享一份成员视图装配器（公开原文行的解析结果跨成员复用）。
  final Map<String, GroupViewLoader> _loaders = {};

  /// 本次运行内每个成员最近一次**真实发出**的上下文快照（重启后为空）。
  final Map<String, ContextSnapshot> _lastSnapshots = {};

  /// 组级单运行门：正在跑的组（set 里有 = 该组已有成员在运行）。
  final Set<String> _runningGroups = <String>{};

  /// 正在跑的反应链（每个组至多一条；安静态的定向轮不登记链）。
  final Map<String, _GroupExecutorState> _chains = {};

  Set<String> get knownToolNames => knownTools?.call() ?? ToolCatalog.instance.nameSet;

  GroupViewLoader loaderFor(String groupId) => _loaders.putIfAbsent(
        groupId,
        () => GroupViewLoader(groupId: groupId, messageRepo: messageRepo),
      );

  // ---------------------------------------------------------------------------
  // 组与成员
  // ---------------------------------------------------------------------------

  /// 建组：会话行（`kind = group`）+ **组上下文**（工作区来自 RPC 可选参数，缺省
  /// 复用 `Agent.ensureContext` 的既有缺省 `ConfigService.homeDir`，不发明第二个缺省）。
  ///
  /// change `custom-workspace` design D4 / D6：带 `workspace` 时**先校验再建行**
  /// （绝对路径 / 存在 / 是目录），不合法抛 `GroupException('invalid_workspace', …)`
  /// 且不创建任何会话行；合法则把**规范化后的设置值**落库（`sessions.workspace`）。
  /// 只有空白字符 = 省略（写 NULL、用缺省）。
  ///
  /// [reactionsEnabled]：组的自发反应开关（change `group-reactive-mode` D1 / D9）。
  /// 省略 = **新建组默认开启**（`SessionRepository.create` 的缺省）；显式 `false`
  /// 落 0（安静态）。行为用例在任务 3.1，这里只做签名与透传 —— 夹具（任务 0.3）
  /// 依赖它，不能等 3.1 才落地。
  ///
  /// [maxRounds]：组的反应轮数上限（任务 R.1 / D13）。省略 / `null` = 用产品默认
  /// （列写 NULL）。透传 `SessionRepository.create`；范围校验在 RPC 入口。
  Future<Session> createGroup({
    String? title,
    String? workspace,
    bool? reactionsEnabled,
    int? maxRounds,
  }) async {
    // 先校验再建行：非法路径不许留下半个组（没有会话行、没有上下文）。
    final setting = stripWorkspaceInput(workspace ?? '');
    if (setting.isNotEmpty) {
      final problem = workspaceProblem(setting);
      if (problem != null) {
        throw GroupException(
            'invalid_workspace', '建组的工作路径被拒绝：$problem');
      }
    }
    final session = await sessionRepo.create(
      title: (title == null || title.trim().isEmpty) ? '新组' : title.trim(),
      kind: Session.kindGroup,
      reactionsEnabled: reactionsEnabled ?? true,
      maxRounds: maxRounds,
      workspace: setting.isEmpty ? null : setting,
    );
    await ensureGroupContext(session.id, workspace: setting);
    final reread = await sessionRepo.get(session.id);
    return reread ?? session;
  }

  /// 确保组上下文已注册（按需重注册）的**统一入口**（change `group-chat-layout`
  /// R.14 / design D13）。
  ///
  /// 群上下文只在 `group.create` 时经 `sidecar.ensureContext` 登记进 sidecar **内存**；
  /// 核心重启后 sidecar 是全新进程，存量群的上下文全丢。任何"取组工作区"的路径都必须
  /// 先经过这里，否则 `getWorkspace` 会返回 `unknown_context`，成员轮在调模型前就失败。
  ///
  /// 返回 sidecar 的 `created` 语义：`true` = 本次新建上下文（工作区由 [workspace]
  /// 落定）；`false` = 上下文已存在（**不覆盖**已有工作区，同进程幂等）。
  ///
  /// [workspace] 省略 / 空串 = 产品既有缺省 `ConfigService.homeDir`（不发明第二个
  /// 缺省）。change `custom-workspace` design D4：非空时**先校验**，不合法抛
  /// `GroupException('workspace_unavailable', …)`（不建上下文、不静默用别的目录）。
  ///
  /// `sidecar.ensureContext` 的 `StateError` 在这里包成可归因 [GroupException]：
  /// 否则 member.add / send 的 `on GroupException` 接不住，会变成 -32603。
  Future<bool> ensureGroupContext(String groupId, {String? workspace}) async {
    final resolvedWorkspace = (workspace == null || workspace.trim().isEmpty)
        ? ConfigService.homeDir
        : stripWorkspaceInput(workspace);
    final problem = workspaceProblem(resolvedWorkspace);
    if (problem != null) {
      throw GroupException(
        'workspace_unavailable',
        '组 "$groupId" 的工作路径「$resolvedWorkspace」不可用：$problem'
            ' —— 不注册上下文、也不用别的目录顶替',
      );
    }
    try {
      return await sidecar.ensureContext(groupId,
          defaultWorkspace: resolvedWorkspace);
    } on StateError catch (error) {
      throw GroupException(
          'workspace_unavailable',
          '注册组 "$groupId" 的工作区上下文失败（ensureContext）：$error');
    }
  }

  /// 全部组（含成员清单，成员含已移除行）。
  Future<List<({Session session, List<GroupMember> members})>> listGroups() async {
    final sessions = await sessionRepo.list();
    final groups = <({Session session, List<GroupMember> members})>[];
    for (final session in sessions) {
      if (!session.isGroup) continue;
      groups.add((
        session: session,
        members: await memberRepo.listByGroup(session.id),
      ));
    }
    return groups;
  }

  Future<Session> requireGroup(String groupId) async {
    final session = await sessionRepo.get(groupId);
    if (session == null) {
      throw GroupException('group_not_found', '组会话 "$groupId" 不存在');
    }
    if (!session.isGroup) {
      throw GroupException(
          'group_not_found', '会话 "$groupId" 不是组会话（kind=${session.kind}）');
    }
    return session;
  }

  Future<GroupMember> requireMember(String groupId, String memberId) async {
    final member = await memberRepo.get(memberId);
    if (member == null || member.groupSessionId != groupId) {
      throw GroupException(
          'member_not_found', '组 "$groupId" 里没有成员 "$memberId"');
    }
    return member;
  }

  /// 加入成员：校验名字/模板/覆盖层 → 写成员行 → 建成员实例（持久实例）。
  ///
  /// 实例创建失败时把刚写的成员行软删（不留"界面有成员、实际建不出实例"的半状态），
  /// 并把可归因错误抛回调用方。
  Future<GroupMember> addMember({
    required String groupId,
    required String name,
    required String templateName,
    AgentInstanceOverrides? overrides,
  }) async {
    await requireGroup(groupId);
    final AgentTypeConfig? template = templates.lookup(templateName);
    if (template == null) {
      throw GroupException('template_not_found',
          'Agent 模板 "$templateName" 不存在：拒绝加入成员（不会退回 general）');
    }
    if (overrides != null && !overrides.isEmpty) {
      try {
        overrides.validateForSave(
            template: template, knownTools: knownToolNames);
      } on AgentOverridesException catch (e) {
        throw GroupException('invalid_overrides', '$e');
      }
    }
    final member = await memberRepo.add(
      groupId: groupId,
      name: name,
      templateName: templateName,
      overridesJson: overrides?.toJsonString(),
    );
    try {
      await ensureMemberAgent(member);
    } catch (e) {
      // 建不出实例的成员不留在组里（否则界面显示"已加入"但永远发不出言）。
      await memberRepo.softRemove(member.id);
      rethrow;
    }
    return member;
  }

  /// 移除成员：先停反应链、再取消在跑的实例、销毁上下文，最后软删（行与历史一律保留）。
  Future<void> removeMember(String groupId, String memberId) async {
    final member = await requireMember(groupId, memberId);
    // 结构操作先停链（change `group-reactive-mode` D7）：链不会在成员被销毁后
    // 继续调用它的实例。
    _stopChain(groupId);
    final agent = agents.lookup(member.handle);
    if (agent != null) {
      agent.cancel();
      await agents.disposeAndRemove(member.handle);
    }
    await memberRepo.softRemove(member.id);
  }

  /// 原地改成员（id 不变）并**重建实例**：新的工具子集与提示词追加下一次发言生效。
  Future<GroupMember> updateMember({
    required String groupId,
    required String memberId,
    String? name,
    String? templateName,
    AgentInstanceOverrides? overrides,
    bool clearOverrides = false,
  }) async {
    final existing = await requireMember(groupId, memberId);
    // 编辑成员会重建实例：先停链，避免链在半途调到一个已销毁的实例。
    _stopChain(groupId);
    final resolvedTemplateName = templateName ?? existing.templateName;
    final AgentTypeConfig? template = templates.lookup(resolvedTemplateName);
    if (template == null) {
      throw GroupException('template_not_found',
          'Agent 模板 "$resolvedTemplateName" 不存在：拒绝修改成员');
    }
    final effectiveOverrides = clearOverrides
        ? null
        : (overrides ?? existing.overrides);
    if (effectiveOverrides != null && !effectiveOverrides.isEmpty) {
      try {
        effectiveOverrides.validateForSave(
            template: template, knownTools: knownToolNames);
      } on AgentOverridesException catch (e) {
        throw GroupException('invalid_overrides', '$e');
      }
    }
    final updated = await memberRepo.update(
      memberId,
      name: name,
      templateName: templateName,
      overridesJson: clearOverrides
          ? null
          : (overrides == null ? existing.overridesJson : overrides.toJsonString()),
      clearOverrides: clearOverrides,
    );
    // 编辑即重建：销毁旧实例（先取消在跑的请求），下一次发言按新配置创建。
    final old = agents.lookup(existing.handle);
    if (old != null) {
      old.cancel();
      await agents.disposeAndRemove(existing.handle);
    }
    // 名称/模板/覆盖层都在下一个实例上生效；这里顺带重建一次，让"改了但没生效"
    // 不可能发生（界面显示与请求对得上）。
    await ensureMemberAgent(updated);
    return updated;
  }

  /// 删除组：先停链、再销毁全部成员实例，最后删会话行（成员/消息/摘要随外键级联删除）。
  Future<void> deleteGroup(String groupId) async {
    await requireGroup(groupId);
    _stopChain(groupId);
    for (final member in await memberRepo.listByGroup(groupId)) {
      final agent = agents.lookup(member.handle);
      if (agent != null) {
        agent.cancel();
        await agents.disposeAndRemove(member.handle);
      }
      _lastSnapshots.remove(member.id);
    }
    await sessionRepo.delete(groupId);
    _loaders.remove(groupId);
    _chains.remove(groupId);
    _runningGroups.remove(groupId);
  }

  /// 取（必要时创建）成员实例。
  Future<Agent> ensureMemberAgent(GroupMember member) async {
    final existing = agents.lookup(member.handle);
    if (existing != null) return existing;
    final group = await requireGroup(member.groupSessionId);
    // R.14：核心重启后 sidecar 内存上下文丢失，存量群必须先按需重注册，否则下面的
    // getWorkspace 会 unknown_context（成员轮在调模型前就失败、steps 一条都没有）。
    // change `custom-workspace` design D3：统一入口传**组行持久化的工作区** —— 上下文
    // 已存在（created:false）时不会覆盖；重启后必然新建（created:true）⇒ 按持久化值
    // 重建（旧组 workspace 为 NULL ⇒ 仍用缺省 homeDir）。
    await ensureGroupContext(group.id, workspace: group.workspace);
    // 成员工作区 = 组上下文保存的工作区（只读读取，不给成员私有工作区）。
    final workspace = sidecar.getWorkspace(group.id);
    if (!workspace.ok) {
      throw GroupException(
          'workspace_unavailable',
          '读取组 "${group.id}" 的工作区失败（${workspace.code}）：${workspace.error}'
              ' —— 成员不能用别的目录顶替');
    }
    final resolvedWorkspace = workspace.workspace ?? '';
    if (resolvedWorkspace.trim().isEmpty) {
      throw GroupException(
          'workspace_unavailable',
          '组 "${group.id}" 的工作区为空（get_workspace 返回 ok 但 workspace 为空串）：'
              '拒绝用空工作区创建成员，不能用别的目录顶替');
    }
    final agent = await factory.createMember(
      group: group,
      member: member,
      workspace: resolvedWorkspace,
      viewLoader: loaderFor(group.id),
      displayNamesResolver: () => displayNamesOf(group.id),
      // 群成员名单**每轮现读**（change `group-member-identity`）：成员增减下一轮
      // 系统提示词即更新；已移除成员不进名单（历史归属仍由 displayNamesOf 保留）。
      groupRosterProvider: () async {
        final members = await memberRepo.listByGroup(group.id);
        return [
          for (final item in members)
            if (!item.isRemoved) item.name,
        ];
      },
      // 每轮现读成员行的覆盖层：思考强度改档位不必重建实例即生效。
      overridesLookup: () async => (await memberRepo.get(member.id))?.overrides,
      callbacks: callbacksForMember(member),
    );
    return agent;
  }

  /// 成员 id → 显示名（**含已移除成员**：历史行一直要有归属）。
  Future<Map<String, String>> displayNamesOf(String groupId) async {
    final members = await memberRepo.listByGroup(groupId);
    return {for (final member in members) member.id: member.name};
  }

  /// 成员清单的对外形状（`group.list` 的 `members` 字段）。
  Future<List<Map<String, dynamic>>> describeMembers(String groupId) async {
    final members = await memberRepo.listByGroup(groupId);
    final out = <Map<String, dynamic>>[];
    for (final member in members) {
      final AgentTypeConfig? template = templates.lookup(member.templateName);
      Map<String, dynamic>? effective;
      if (template != null) {
        try {
          final candidate =
              factory.resolveCandidate(member.templateName, overrides: member.overrides);
          final thinking = member.overrides?.effectiveThinking();
          effective = {
            'tools': candidate.resolved.tools,
            'systemPrompt': candidate.resolved.systemPrompt,
            'thinkingMode': thinking?.mode ?? candidate.resolved.thinkingMode,
            'thinkingEffort':
                thinking?.effort ?? candidate.resolved.thinkingEffort,
            'model': candidate.resolved.model,
            'maxContextTokens': candidate.resolved.maxContextTokens,
          };
        } catch (e) {
          effective = {'error': '$e'};
        }
      }
      out.add({
        'id': member.id,
        'name': member.name,
        'template': member.templateName,
        'removedAt': member.removedAt,
        'overrides': member.overrides?.toJson(),
        'effective': effective,
      });
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 调度
  // ---------------------------------------------------------------------------

  /// 组级单运行门：组内**任一**成员在跑就算忙（不只查目标成员）。
  bool isGroupBusy(String groupId) {
    if (_runningGroups.contains(groupId)) return true;
    for (final agent in agents.instances) {
      if (agent.handle.startsWith('$groupId::') && agent.isStreaming) {
        return true;
      }
    }
    return false;
  }

  /// 当前占着组级单运行门的组 id（只读；测试夹具据此在销毁侧车 / 删临时目录前
  /// 等链终态 —— change `group-reactive-mode` R.7）。
  Set<String> get runningGroupIds => Set<String>.unmodifiable(_runningGroups);

  /// 该组当前正在运行的成员 id（供 `group.list` 的 `runningMemberId`）。
  ///
  /// 链在成员间隙时为 null（spec「组项带忙碌状态」允许）；断线重连的客户端据
  /// `busy` + 本字段恢复"链在跑/谁在跑"，因此取消按钮不依赖本地 `sending`。
  String? runningMemberIdOf(String groupId) {
    final chain = _chains[groupId];
    if (chain != null && chain.runningMemberId != null) {
      return chain.runningMemberId;
    }
    for (final agent in agents.instances) {
      if (!agent.handle.startsWith('$groupId::')) continue;
      if (agent.isStreaming) return agent.member?.memberId;
    }
    return null;
  }

  /// 改组设置（`group.update` 的唯一行为；change `group-reactive-mode` D1 / D7 / D9 /
  /// R.2 / R.3）。
  ///
  /// 链运行中**返回 busy、不排队、不改值**：改设置会让"这条链按哪套语义跑"变得
  /// 不可解释。[setMaxRounds] 区分「字段缺席」与「显式 null」——缺席 = 不改；
  /// 显式 null = 恢复默认（列写 NULL）。返回更新后的会话（重新读取，保证读的是真值）。
  Future<Session> updateGroupSettings(
    String groupId, {
    bool? reactionsEnabled,
    int? maxRounds,
    bool setMaxRounds = false,
  }) async {
    await requireGroup(groupId);
    if (reactionsEnabled == null && !setMaxRounds) {
      throw const GroupException('invalid_params',
          'group.update 至少要给一个字段（reactionsEnabled / maxRounds）');
    }
    if (setMaxRounds && !isValidMaxReactionRounds(maxRounds)) {
      throw GroupException(
          'invalid_max_rounds',
          '反应轮数上限必须是 $kMinMaxReactionRounds..$kMaxMaxReactionRounds 的整数'
              '或显式 null（收到 $maxRounds）：已拒绝，组设置未改动');
    }
    if (isGroupBusy(groupId)) {
      throw GroupException(
          'busy',
          '组 "$groupId" 已有成员在运行（含反应链）：改组的运行设置会中途改变链的语义，'
              '本次没有排队、设置未改动');
    }
    if (reactionsEnabled != null) {
      await sessionRepo.updateReactionsEnabled(groupId, reactionsEnabled);
    }
    if (setMaxRounds) {
      await sessionRepo.updateMaxRounds(groupId, maxRounds);
    }
    return requireGroup(groupId);
  }

  /// 只改自发反应开关（既有调用方的便捷入口；语义同 [updateGroupSettings]）。
  Future<Session> updateReactionsEnabled(String groupId, bool enabled) =>
      updateGroupSettings(groupId, reactionsEnabled: enabled);

  /// 只改反应轮数上限（整数 1..50 或显式 null = 恢复默认）。
  Future<Session> updateMaxRounds(String groupId, int? maxRounds) =>
      updateGroupSettings(groupId, maxRounds: maxRounds, setMaxRounds: true);

  /// 切换组的**共享工作路径**（change `custom-workspace` design D6 / D7）。
  ///
  /// 顺序钉死：requireGroup → busy 拒绝（**不排队、不改值**）→ 规范化 + 校验（非法
  /// 路径时任何状态都不改）→ `ensureGroupContext` + `sidecar.setWorkspace(groupId)`
  /// （读回确认为非空）→ 落库（核对恰好一行）→ **传播到所有在册成员实例**的上下文 →
  /// 返回重读的组会话。
  ///
  /// 传播失败不静默：此时组与库**已经**切到新目录，错误消息点名失败成员；每个成员轮
  /// 开始还有一道对齐保险（[_alignMemberWorkspace]），下一轮会收敛。
  Future<Session> setWorkspace(String groupId, String path) async {
    final group = await requireGroup(groupId);
    if (isGroupBusy(groupId)) {
      throw GroupException(
        'busy',
        '组 "$groupId" 已有成员在运行（含反应链）：中途换根会让该轮的工具边界跳变，'
            '本次没有排队、工作路径未改动',
      );
    }
    final setting = stripWorkspaceInput(path);
    final problem = workspaceProblem(setting);
    if (problem != null) {
      throw GroupException(
          'invalid_workspace', '组 "$groupId" 的工作路径被拒绝：$problem');
    }

    // ① 让上下文先生效：ensure（校验过才建）+ 显式 set（已存在时 ensure 不覆盖）。
    await ensureGroupContext(groupId, workspace: setting);
    final error = sidecar.setWorkspace(groupId, setting);
    if (error != null && error.isNotEmpty) {
      throw GroupException(
        'workspace_unavailable',
        '组 "$groupId" 的上下文拒绝该工作路径（set_workspace）：$error',
      );
    }
    final readBack = sidecar.getWorkspace(groupId);
    final readPath = (readBack.workspace ?? '').trim();
    if (!readBack.ok || readPath.isEmpty) {
      throw GroupException(
        'workspace_unavailable',
        '组 "$groupId" 切换后读回的工作区${readBack.ok ? '为空串' : '失败（${readBack.code}）'}：'
            '拒绝把未生效的值写进库',
      );
    }

    // ② 落库（设置值 = 规范化后的用户输入），必须核对**恰好一行**。
    final updated = await sessionRepo.updateWorkspace(groupId, setting);
    if (updated != 1) {
      throw GroupException(
        'workspace_persist_failed',
        '上下文已切换到「$setting」，但没有更新到唯一既有行（实际更新 $updated 行，期望 1 行）：'
            '数据库里的工作路径未持久化（不假装成功）',
      );
    }

    // ③ 传播到所有在册成员实例的上下文（成员没有私有工作区）。
    final failures = <String>[];
    for (final member in await memberRepo.listByGroup(groupId)) {
      if (member.isRemoved) continue;
      final agent = agents.lookup(member.handle);
      if (agent == null) continue; // 还没建过实例：下一轮创建时直接用组值
      try {
        // 上下文丢失时直接建对；已存在时 ensure 不覆盖，随后 set 显式改。
        await agent.ensureContext(defaultWorkspace: setting);
        final memberError = sidecar.setWorkspace(member.handle, setting);
        if (memberError != null && memberError.isNotEmpty) {
          throw GroupException(
              'workspace_unavailable', '成员上下文拒绝该路径（set_workspace）：$memberError');
        }
      } catch (e) {
        failures.add('${member.name}（${member.id}）：$e');
      }
    }
    if (failures.isNotEmpty) {
      throw GroupException(
        'workspace_propagation_failed',
        '组 "$groupId" 与数据库已切到「$setting」，但以下成员实例即时更新失败：'
            '${failures.join('；')} —— 它们会在下一轮开始前对齐到组工作区（不静默）',
      );
    }

    final reread = await sessionRepo.get(groupId);
    return reread ?? group.copyWith(workspace: setting);
  }

  /// 当前 / 最近一条链的只读快照；本进程内还没有链时返回 `status = idle`。
  ///
  /// 核心重启后自然回到 `idle`（本进程内语义，与 `group.view` 先例一致）。
  GroupChainSnapshot chainOf(String groupId) {
    final chain = _chains[groupId];
    if (chain == null) {
      return GroupChainSnapshot(
        groupId: groupId,
        status: 'idle',
        rounds: 0,
        steps: const [],
      );
    }
    return chain.snapshot();
  }

  /// 等该组当前链进入终态（测试夹具 / 内部收尾用；没有在跑的链立即完成）。
  ///
  /// 上界由调用方控制（测试侧按 design 推导公式给 `timeout`），这里不写产品上限。
  Future<void> waitForChain(String groupId) {
    final chain = _chains[groupId];
    if (chain == null || chain.status != 'running') {
      return Future<void>.value();
    }
    return chain.done.future;
  }

  /// 写一条用户公开消息（组服务路径：`author` 空、`public`），并做标题与事件。
  ///
  /// **只写一次**：开启态的每次发送由这里写（caller 之后用 `writeUserMessage:false`
  /// 跑成员轮），关闭态只有"仅 @mention"那条路径由这里写。
  Future<Message> _writeUserMessage(Session group, String text) async {
    final message = await messageRepo.insert(
      sessionId: group.id,
      role: 'user',
      content: text,
      author: null,
      visibility: Message.visibilityPublic,
    );
    await sessionRepo.touch(group.id);
    // 事件不带 memberId（这条消息没有成员作者，不伪造身份）。
    onUserMessage?.call(group.id, message);
    final titleUpdated = await sessionRepo.updateTitleIfDefault(group.id, text);
    if (titleUpdated) {
      final fresh = await sessionRepo.get(group.id);
      onTitleChanged?.call(group.id, fresh?.title ?? '新组');
    }
    return message;
  }

  /// 群发送（**永不拒绝用户**；change `group-reactive-mode` R.8 / design D3 / D4 / D9）。
  ///
  /// 同步阶段只做：组/成员/参数校验、两个前置门、写一次用户消息（若有文本）与标题、
  /// 把请求放入该组**吸收式执行器**的队列并唤醒它，然后**立刻返回** `started`。
  /// 执行器在跑时新请求照常入队/被吸收（下一轮反应使用更新的触发），不返回 busy。
  Future<GroupSendOutcome> send({
    required String groupId,
    required String? memberId,
    String? text,
  }) async {
    final group = await requireGroup(groupId);
    final rawText = text ?? '';
    final trimmed = rawText.trim();
    final members = await memberRepo.listByGroup(groupId);
    // `@显示名` 只解析**用户消息**（agent 公开回复里的 @ 只是正文，design D4）。
    final mentioned = trimmed.isEmpty
        ? const <String>[]
        : parseMentionedMemberIds(rawText, members);
    final speakerId =
        (memberId == null || memberId.trim().isEmpty) ? null : memberId;
    // 成员存在性 / 已移除先判（可归因错误，且不写行）。
    final speaker = speakerId == null
        ? null
        : _findActiveMember(members, speakerId, groupId: groupId);

    int? userSeq;
    // 模式判定（不写任何行；可归因错误）。
    if (group.reactionsEnabled) {
      if (speaker == null && trimmed.isEmpty) {
        throw const GroupException('no_trigger',
            '群发送既没有用户文本、也没有发言者（该组已开启自发反应）：'
                '没有可触发的公开消息，未写入任何消息');
      }
    } else {
      if (speaker == null && mentioned.isEmpty) {
        throw const GroupException('no_speaker',
            '群发送没有指定发言者，且消息里没有 @任何成员（该组已关闭自发反应）：'
                '没有可运行的成员，未写入任何消息');
      }
    }
    // 两个前置门只对「带 speaker 且不带文本」的定向轮成立（两态都适用）：
    // 空视图不发空 messages、本人 assistant 结尾不退化成 prefill。
    if (speaker != null && trimmed.isEmpty) {
      final agent = await ensureMemberAgent(speaker);
      await agent.assembleMemberView();
      await _assertDirectedGates(agent, speaker);
    }
    // 用户消息：**所有发送**都由组服务在返回前写一次（design D2）。
    if (trimmed.isNotEmpty) {
      final userMessage = await _writeUserMessage(group, rawText);
      userSeq = userMessage.seq;
    }

    // 入队 + 唤醒执行器（**不因执行器在跑而拒绝**）。请求按到达顺序入队；
    // 执行器在轮边界吸收它（更新触发、重置该用户触发的预算）。
    final executor = _executorFor(groupId, members);
    executor.queue.add(_QueuedGroupRequest(
      speakerId: speaker?.id,
      mentioned: mentioned,
      userSeq: userSeq,
      reactionsEnabled: group.reactionsEnabled,
    ));
    _ensureExecutorRunning(executor, group);
    return GroupSendOutcome(status: 'started', triggerSeq: userSeq);
  }

  /// 取（或在上一轮运行已终态后重置）该组的执行器状态。
  _GroupExecutorState _executorFor(
      String groupId, List<GroupMember> members) {
    final participants = {
      for (final member in members)
        if (!member.isRemoved) member.id,
    };
    final existing = _chains[groupId];
    if (existing == null) {
      final created =
          _GroupExecutorState(groupId: groupId, participants: participants);
      _chains[groupId] = created;
      return created;
    }
    if (existing.status == 'running') return existing;
    // 上一次运行已终态：新请求开始**新一次运行**（steps 只属于一次执行器运行；
    // `group.chain` 的 `rounds` 是新用户触发的预算）。
    existing
      ..participants = participants
      ..status = 'running'
      ..triggerSeq = null
      ..rounds = 0
      ..stopReason = null
      ..steps.clear()
      ..cancelled = false
      ..runningMemberId = null
      ..lastMemberId = null
      ..currentAgent = null
      ..error = null
      ..loopStarted = false
      ..maxRounds = kDefaultMaxReactionRounds
      ..reactionsEnabled = true
      ..pendingForcedIds = const []
      ..done = Completer<void>();
    return existing;
  }

  /// 启动执行器循环（若还没在跑）：异常必须写进链状态（`failed`），不能变成未处理
  /// 异常；无论怎么结束都要进入终态、释放忙碌状态并发 `group.chain.completed`。
  void _ensureExecutorRunning(_GroupExecutorState state, Session group) {
    if (state.loopStarted) return;
    state.loopStarted = true;
    _runningGroups.add(state.groupId);
    // `Future(...)` 把循环推到下一个事件循环再开始：`send` 一定先返回 `started`。
    Future<void>(() async {
      try {
        await _executorLoop(state, group);
      } catch (error) {
        _failChainFromException(state, error);
      } finally {
        _finishExecutor(state);
      }
    });
  }

  /// 吸收式执行器主循环（R.8 / design D3）。
  ///
  /// 顺序钉死：**先看队列有没有新用户请求 → 再规划可反应成员 → 最后查上限**。
  /// 队列里有请求时先吸收它（更新触发、`rounds = 0`），所以「本轮本该自然停」不会被
  /// 误报成 `round_cap`，用户连发消息也能立刻获得新预算。
  Future<void> _executorLoop(
      _GroupExecutorState state, Session group) async {
    final allMembers = await memberRepo.listByGroup(state.groupId);
    final chainMembers = [
      for (final member in allMembers)
        if (state.participants.contains(member.id) && !member.isRemoved) member,
    ];
    final lastReactedSeq = <String, int>{};
    var triggerSeq = state.triggerSeq;
    String? triggerAuthor;
    var lastRoundHadReplies = false;

    while (true) {
      if (state.cancelled) {
        _cancelChain(state);
        return;
      }

      // ① 吸收排队中的用户请求（按到达顺序，定向 / mention 请求逐条执行）。
      if (state.queue.isNotEmpty) {
        final request = state.queue.removeAt(0);
        final fresh = await sessionRepo.get(state.groupId) ?? group;
        state.maxRounds = fresh.maxRounds ?? kDefaultMaxReactionRounds;
        state.reactionsEnabled = request.reactionsEnabled;
        state.rounds = 0;
        lastRoundHadReplies = false;
        state.pendingForcedIds = List<String>.from(request.mentioned);
        triggerAuthor = null;
        triggerSeq = request.userSeq;
        state.triggerSeq = triggerSeq;

        // 安静态：speaker 普通轮 + mention 强制轮；没有反应轮。
        if (!request.reactionsEnabled) {
          final ok = await _runQuietRequest(
            state: state,
            group: group,
            members: allMembers,
            request: request,
          );
          if (!ok) return;
          continue;
        }

        // 开启态：speaker 定向轮先跑（强制轮），随后其公开回复成为首触发；
        // 若 speaker 没产生公开回复，触发保持该用户消息 seq（@mention 仍有机会）。
        final speakerId = request.speakerId;
        if (speakerId != null) {
          final speaker =
              _findActiveMember(allMembers, speakerId, groupId: state.groupId);
          final result = await _runMemberRound(
            group: group,
            member: speaker,
            chain: state,
            reaction: true,
            mustRespond: true,
            writeUserMessage: false,
          );
          _addStep(
            state,
            _stepFor(speaker, 'speaker',
                forced: true, result: result, triggerSeq: request.userSeq),
          );
          if (result.isFailed) {
            _failChain(state, result);
            return;
          }
          if (result.isCancelled || state.cancelled) {
            _cancelChain(state);
            return;
          }
          // 它已经对这条用户消息做过响应（即使 pass=true / 空 message）。
          if (request.userSeq != null) {
            lastReactedSeq[speaker.id] = request.userSeq!;
          }
          final publicSeq = result.publicMessage?.seq;
          if (publicSeq != null) {
            triggerSeq = publicSeq;
            triggerAuthor = speaker.id;
            state.triggerSeq = publicSeq;
          }
        }
        continue;
      }

      // ② 队列空：安静态没有反应轮可跑，直接终态。
      if (!state.reactionsEnabled) {
        state.status = 'completed';
        state.stopReason = 'no_members';
        return;
      }
      if (triggerSeq == null) {
        state.status = 'completed';
        state.stopReason =
            _stopReasonWithoutResponders(state.rounds, lastRoundHadReplies);
        return;
      }

      // ③ 规划可反应成员（先规划）。
      final responders = planReactionRound(
        members: chainMembers,
        triggerSeq: triggerSeq,
        triggerAuthor: triggerAuthor,
        lastReactedSeq: lastReactedSeq,
        forcedMemberIds: state.pendingForcedIds,
      );
      state.pendingForcedIds = const [];
      if (responders.isEmpty) {
        state.status = 'completed';
        state.stopReason =
            _stopReasonWithoutResponders(state.rounds, lastRoundHadReplies);
        return;
      }

      // ④ 再查上限：队列已在上面处理过，所以这里该报 round_cap 就是真的到顶。
      if (state.rounds >= state.maxRounds) {
        state.status = 'completed';
        state.stopReason = 'round_cap';
        return;
      }

      state.rounds += 1;
      lastRoundHadReplies = false;
      int? roundLastSeq;
      String? roundLastAuthor;
      for (final target in responders) {
        if (state.cancelled) {
          _cancelChain(state);
          return;
        }
        lastReactedSeq[target.member.id] = triggerSeq;
        final result = await _runMemberRound(
          group: group,
          member: target.member,
          chain: state,
          reaction: true,
          mustRespond: target.forced,
          writeUserMessage: false,
        );
        _addStep(
          state,
          _stepFor(
            target.member,
            target.forced ? 'mention' : 'reaction',
            forced: target.forced,
            result: result,
            triggerSeq: triggerSeq,
          ),
        );
        if (result.isFailed) {
          _failChain(state, result);
          return;
        }
        if (result.isCancelled || state.cancelled) {
          _cancelChain(state);
          return;
        }
        final publicSeq = result.publicMessage?.seq;
        if (publicSeq != null) {
          lastRoundHadReplies = true;
          roundLastSeq = publicSeq;
          roundLastAuthor = target.member.id;
        }
      }
      // 轮末最后一条公开消息决定下一触发（没有新公开消息 ⇒ 下一轮规划为空 ⇒ 停）。
      if (roundLastSeq != null) {
        triggerSeq = roundLastSeq;
        triggerAuthor = roundLastAuthor;
        state.triggerSeq = roundLastSeq;
      }
    }
  }

  /// 安静态的一条用户请求：speaker 普通轮 + 按点名顺序的 mention 强制轮。
  ///
  /// 返回 false 表示已经进入 failed / cancelled（调用方直接返回）。
  Future<bool> _runQuietRequest({
    required _GroupExecutorState state,
    required Session group,
    required List<GroupMember> members,
    required _QueuedGroupRequest request,
  }) async {
    final speakerId = request.speakerId;
    if (speakerId != null) {
      final speaker =
          _findActiveMember(members, speakerId, groupId: state.groupId);
      final result = await _runMemberRound(
        group: group,
        member: speaker,
        chain: state,
        reaction: false,
        mustRespond: false,
        writeUserMessage: false,
      );
      _addStep(
        state,
        _stepFor(speaker, 'speaker',
            forced: false, result: result, triggerSeq: request.userSeq),
      );
      if (result.isFailed) {
        _failChain(state, result);
        return false;
      }
      if (result.isCancelled || state.cancelled) {
        _cancelChain(state);
        return false;
      }
    }
    for (final id in request.mentioned) {
      if (state.cancelled) {
        _cancelChain(state);
        return false;
      }
      final member = _findActiveMember(members, id, groupId: state.groupId);
      final result = await _runMemberRound(
        group: group,
        member: member,
        chain: state,
        reaction: true,
        mustRespond: true,
        writeUserMessage: false,
      );
      _addStep(
        state,
        _stepFor(member, 'mention',
            forced: true, result: result, triggerSeq: request.userSeq),
      );
      if (result.isFailed) {
        _failChain(state, result);
        return false;
      }
      if (result.isCancelled || state.cancelled) {
        _cancelChain(state);
        return false;
      }
    }
    return true;
  }

  GroupMember _findActiveMember(List<GroupMember> members, String id,
      {required String groupId}) {
    for (final member in members) {
      if (member.id != id) continue;
      if (member.isRemoved) {
        throw GroupException(
            'member_removed', '成员 "${member.name}"（${member.id}）已被移除：不能发言');
      }
      return member;
    }
    throw GroupException('member_not_found', '组 "$groupId" 里没有成员 "$id"');
  }

  /// 没有可反应成员时的 `stopReason` 映射（design D3）：
  /// 首轮就无人 ⇒ `no_members`；末轮有回复但无人可接 ⇒ `no_members`；否则全 PASS。
  String _stopReasonWithoutResponders(int rounds, bool lastRoundHadReplies) {
    if (rounds == 0) return 'no_members';
    return lastRoundHadReplies ? 'no_members' : 'all_passed';
  }

  void _addStep(_GroupExecutorState chain, GroupSendStep step) {
    chain.steps.add(step);
    // `turn.failed` 只按**真实失败**步骤发（forced_pass / forced_empty 不是整轮失败）。
    if (step.isFailure) onTurnFailed?.call(chain.groupId, step);
  }

  void _failChain(_GroupExecutorState chain, AgentRunResult result) {
    chain.status = 'failed';
    chain.stopReason = 'failed';
    chain.error = result.error;
  }

  /// 后台异常兜底：链状态 `failed` + 可归因（不变成未处理异常）。
  ///
  /// change `custom-workspace`：`GroupException` 的可归因**错误码**要一起进链错误文本
  /// （例如 `workspace_unavailable`），否则界面 / 测试只看到一句人话、拿不到码。
  void _failChainFromException(_GroupExecutorState chain, Object error) {
    chain.status = 'failed';
    chain.stopReason = 'failed';
    chain.error = error is GroupException
        ? '${error.code}: ${error.message}'
        : '$error';
    final memberId = chain.runningMemberId ?? chain.lastMemberId;
    if (memberId != null &&
        !chain.steps.any((step) => step.memberId == memberId && step.isFailure)) {
      _addStep(
        chain,
        GroupSendStep(
          memberId: memberId,
          source: chain.reactionsEnabled ? 'reaction' : 'speaker',
          status: 'failed',
          triggerSeq: chain.triggerSeq,
          error: '$error',
        ),
      );
    }
  }

  void _cancelChain(_GroupExecutorState chain) {
    chain.status = 'cancelled';
    chain.stopReason = 'cancelled';
  }

  /// 执行器收尾：终态（若循环忘了写就按实现缺陷记 failed，不静默）+ 释放忙碌状态 +
  /// 发 `group.chain.completed`（`steps` 不塞事件，需要时查 `group.chain`）。
  void _finishExecutor(_GroupExecutorState chain) {
    if (chain.status == 'running') {
      chain.status = 'failed';
      chain.stopReason = 'failed';
      chain.error ??= '执行器在后台跑完却没有写终态（实现缺陷）';
    }
    chain.loopStarted = false;
    _runningGroups.remove(chain.groupId);
    if (!chain.done.isCompleted) chain.done.complete();
    onChainCompleted?.call(chain.snapshot());
  }

  /// 定向轮的两个前置门（不带文本时）：空视图 / 本人 assistant 结尾。
  ///
  /// 两个都抛**可归因**错误、都在发请求**之前**：绝不发空 messages、绝不退化成
  /// prefill 续写（spec「空视图不许发」「本人 assistant 结尾不许 prefill」）。
  Future<void> _assertDirectedGates(Agent agent, GroupMember member) async {
    final view = await agent.memberViewForRound();
    if (view.isEmpty) {
      throw GroupException('empty_view',
          '成员 "${member.name}"（${member.id}）的视图为空：不带文本点名会发出空 messages，'
              '已被拒绝；请带一条用户消息或先让别的成员发言');
    }
    final last = view.last;
    if (last.role == 'assistant' && last.author == member.id) {
      throw GroupException('prefill',
          '成员 "${member.name}"（${member.id}）的视图最后一条可见项是**本人**的 assistant 轮：'
              '不带文本继续会退化成 prefill 续写，已被拒绝；请带用户文本');
    }
  }

  /// 成员轮开始前的**工作区对齐**（change `custom-workspace` design D7 第 2 条）。
  ///
  /// 先经统一入口按需重注册组上下文（重启后 created:true 用持久化值），再读组**当前**
  /// 工作区；与成员上下文不一致就 `set_workspace` 到组值并留一行日志。读不到 / 为空
  /// 一律按可归因 `workspace_unavailable` 拒绝 —— 不让成员在空工作区或别的目录里干活。
  ///
  /// 这是"成员继承组工作区"成为**每轮成立**的不变量，而不只依赖切换那一刻的传播。
  Future<void> _alignMemberWorkspace({
    required Session group,
    required GroupMember member,
    required Agent instance,
  }) async {
    await ensureGroupContext(group.id, workspace: group.workspace);
    final groupWorkspace = sidecar.getWorkspace(group.id);
    if (!groupWorkspace.ok) {
      throw GroupException(
        'workspace_unavailable',
        '成员轮开始前读取组 "${group.id}" 的工作区失败'
            '（${groupWorkspace.code}）：${groupWorkspace.error}',
      );
    }
    final groupPath = (groupWorkspace.workspace ?? '').trim();
    if (groupPath.isEmpty) {
      throw GroupException(
        'workspace_unavailable',
        '组 "${group.id}" 的工作区为空（get_workspace 返回 ok 但为空串）：'
            '拒绝让成员 "${member.name}" 在空工作区里发言（不能用别的目录顶替）',
      );
    }
    final memberWorkspace = sidecar.getWorkspace(instance.handle);
    final memberPath =
        memberWorkspace.ok ? (memberWorkspace.workspace ?? '').trim() : '';
    if (memberWorkspace.ok && p.equals(memberPath, groupPath)) return;
    final error = sidecar.setWorkspace(instance.handle, groupPath);
    if (error != null && error.isNotEmpty) {
      throw GroupException(
        'workspace_unavailable',
        '成员 "${member.name}"（${member.id}）对齐组工作区「$groupPath」失败'
            '（set_workspace）：$error',
      );
    }
    debugPrint('[AliasAgent] 成员轮对齐工作区：${member.name}（${member.id}）'
        '「${memberWorkspace.ok ? memberPath : '读取失败（${memberWorkspace.code}）'}」'
        ' → 「$groupPath」');
  }

  /// 跑一个成员的一轮（登记链的当前成员 + 更新"本次运行内最近一次真实发出"快照）。
  ///
  /// change `custom-workspace` design D7：装配前先**对齐工作区**（成员继承组当前工作
  /// 区，成员轮开始再核对一次）；对齐失败按可归因 `workspace_unavailable` 拒绝。
  ///
  /// 注意：异步契约下用户的文本已由 `send` 在返回前写入库，这里一律
  /// `writeUserMessage: false`（成员视图装配会读到那条用户消息）。
  Future<AgentRunResult> _runMemberRound({
    required Session group,
    required GroupMember member,
    required _GroupExecutorState? chain,
    required bool reaction,
    required bool mustRespond,
    required bool writeUserMessage,
    String text = '',
    Agent? agent,
  }) async {
    final instance = agent ?? await ensureMemberAgent(member);
    // 双保险的第二道：即时传播失败 / 上下文被别处改过时，成员轮开始前回正。
    await _alignMemberWorkspace(group: group, member: member, instance: instance);
    // 每轮开始前增量装配：后跑者能看到先跑者刚落库的公开回复（串行可见）。
    await instance.assembleMemberView();
    chain?.runningMemberId = member.id;
    chain?.lastMemberId = member.id;
    chain?.currentAgent = instance;
    try {
      final result = await instance.send(
        text,
        writeUserMessage: writeUserMessage,
        reaction: reaction,
        mustRespond: mustRespond,
      );
      // 反应轮**也算真实发出**：`group.view` 必须返回它实际发出的那份上下文。
      final snapshot = instance.contextSnapshot;
      if (snapshot != null) _lastSnapshots[member.id] = snapshot;
      return result;
    } finally {
      if (chain != null && chain.runningMemberId == member.id) {
        chain.runningMemberId = null;
        chain.currentAgent = null;
      }
    }
  }

  GroupSendStep _stepFor(
    GroupMember member,
    String source, {
    required bool forced,
    required AgentRunResult result,
    required int? triggerSeq,
  }) {
    final String status;
    if (result.isCancelled) {
      status = 'cancelled';
    } else if (result.isFailed) {
      status = 'failed';
    } else if (result.reactionPassed) {
      status = forced ? 'forced_pass' : 'passed';
    } else if (result.publicMessage != null) {
      status = 'replied';
    } else {
      status = forced ? 'forced_empty' : 'empty';
    }
    return GroupSendStep(
      memberId: member.id,
      source: source,
      status: status,
      triggerSeq: triggerSeq,
      publicSeq: result.publicMessage?.seq,
      finalText: result.finalText,
      error: result.error,
    );
  }

  /// 停链：标取消 + 取消当前成员 + **清空排队**（结构操作前调用；链会自己收尾）。
  ///
  /// 只对**还在跑**的执行器生效：最近一条已终态的链不该被结构操作改成 cancelled。
  /// 已写入的用户消息保留（用户可以重发）。
  void _stopChain(String groupId) {
    final chain = _chains[groupId];
    if (chain == null || chain.status != 'running') return;
    chain.cancelled = true;
    chain.queue.clear();
    chain.currentAgent?.cancel();
  }

  /// 本次运行内该成员最近一次真实发出的快照；从未发言（或已重启）⇒ null。
  ContextSnapshot? snapshotOf(String memberId) => _lastSnapshots[memberId];

  /// `agent.cancel` 的组路由。
  ///
  /// 反应链的取消语义（change `group-reactive-mode` D3 / D7）：
  ///   - 不带 `memberId`：停链 + 取消当前成员，`cancelled` = 是否真有成员在跑；
  ///   - 带 `memberId` 且该成员**正在跑** ⇒ 取消它 + 停链，`cancelled:true`；
  ///   - 带 `memberId` 且该成员在链的**参与快照里但尚未轮到** ⇒ 停整条链，
  ///     `cancelled:false` + `reactionChainStopped:true`（它确实没在运行，不谎报）；
  ///   - 带 `memberId` 但既不在链里也没在运行 ⇒ 既有"该成员当前没有在运行"结果，
  ///     不冒领停链（链继续）。
  Future<GroupCancelOutcome> cancel(String groupId, {String? memberId}) async {
    await requireGroup(groupId);
    final chain = _chains[groupId];
    // 只有**在跑**的执行器才能被取消；最近一条已终态的链不影响取消语义。
    if (chain != null && chain.status == 'running') {
      final runningId = chain.runningMemberId;
      if (memberId != null && memberId.trim().isNotEmpty) {
        final member = await requireMember(groupId, memberId);
        if (runningId == member.id) {
          _stopChain(groupId);
          return GroupCancelOutcome(
            cancelled: true,
            memberId: member.id,
            reactionChainStopped: true,
            reason: '已取消正在运行的成员 "${member.name}"（${member.id}），整条反应链已停止',
          );
        }
        if (chain.participants.contains(member.id)) {
          _stopChain(groupId);
          return GroupCancelOutcome(
            cancelled: false,
            memberId: member.id,
            reactionChainStopped: true,
            reason: '成员 "${member.name}"（${member.id}）在反应链里排队、尚未轮到：'
                '已停整条链，但它确实没有在运行（不谎报 cancelled）',
          );
        }
        return GroupCancelOutcome(
          cancelled: false,
          memberId: member.id,
          reason: '成员 "${member.name}"（${member.id}）当前没有在运行：'
              '它不在反应链里，链继续运行',
        );
      }
      _stopChain(groupId);
      return GroupCancelOutcome(
        cancelled: runningId != null,
        memberId: runningId,
        reactionChainStopped: true,
        reason: runningId == null
            ? '已停止反应链（成员间隙，没有成员正在运行）'
            : '已取消正在运行的成员（$runningId），整条反应链已停止',
      );
    }
    if (memberId != null && memberId.trim().isNotEmpty) {
      final member = await requireMember(groupId, memberId);
      final agent = agents.lookup(member.handle);
      if (agent == null || !agent.isStreaming) {
        return GroupCancelOutcome(
          cancelled: false,
          memberId: member.id,
          reason: '成员 "${member.name}"（${member.id}）当前没有在运行',
        );
      }
      agent.cancel();
      return GroupCancelOutcome(
        cancelled: true,
        memberId: member.id,
        reason: '已取消成员 "${member.name}"（${member.id}）',
      );
    }
    for (final agent in agents.instances) {
      if (!agent.handle.startsWith('$groupId::')) continue;
      if (!agent.isStreaming) continue;
      final runningMemberId = agent.member?.memberId;
      agent.cancel();
      return GroupCancelOutcome(
        cancelled: true,
        memberId: runningMemberId,
        reason: '已取消正在运行的成员（$runningMemberId）',
      );
    }
    return const GroupCancelOutcome(
      cancelled: false,
      reason: '该组当前没有成员在运行（不是查不到实例）',
    );
  }
}
