// 组服务：组/成员生命周期、调度、共享工作区与"本次运行内最近一次真实发出"的快照
// （change `agent-group-chat` §5 / design D5、D7、D10）。
//
// 关键口径：
//   - `group.create` 先建组上下文（`ensureContext(groupId, workspace ?? 默认工作区)`）；
//   - 成员创建经 `sidecar.getWorkspace(groupId)` **继承**组工作区（走生产路径，不靠手工
//     setWorkspace）；
//   - 调度是「用户点名一个 + **组级单运行门**」：组内已有成员在跑时，点名任何成员都
//     返回可归因 busy（不排队、不静默丢弃、不改写到别的成员）；
//   - 两个前置门：不带文本且视图为空 / 不带文本且最后可见项是本人 assistant；
//   - `group.view` 只返回本次运行内最近一次**真实发出**的快照（重启后为空是既定语义）。
import 'context_snapshot.dart';
import '../models/agent_type_config.dart';
import '../models/group_member.dart';
import '../models/instance_overrides.dart';
import '../models/session.dart';
import 'agent.dart';
import 'agent_factory.dart';
import 'agent_registry.dart';
import 'agent_type_registry.dart';
import 'config_service.dart';
import 'group_member_repository.dart';
import 'group_view_loader.dart';
import 'message_repository.dart';
import 'session_repository.dart';
import 'sidecar_bridge.dart';
import 'summary_node_repository.dart';
import 'tool_catalog.dart';

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

/// 一次群发送的结果（结构同 `AgentRunResult` 的状态字段）。
class GroupSendOutcome {
  const GroupSendOutcome({
    required this.status,
    required this.memberId,
    this.finalText,
    this.error,
  });

  final String status;
  final String memberId;
  final String? finalText;
  final String? error;

  bool get isBusy => status == 'busy';

  Map<String, dynamic> toJson() => {
        'status': status,
        'memberId': memberId,
        'finalText': finalText,
        'error': error,
      };
}

/// 取消结果：组级或成员级都给出**真话**（不说"查不到实例"）。
class GroupCancelOutcome {
  const GroupCancelOutcome({
    required this.cancelled,
    required this.reason,
    this.memberId,
  });

  final bool cancelled;
  final String reason;
  final String? memberId;

  Map<String, dynamic> toJson() => {
        'cancelled': cancelled,
        'reason': reason,
        if (memberId != null) 'memberId': memberId,
      };
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

  /// 每个组共享一份成员视图装配器（公开原文行的解析结果跨成员复用）。
  final Map<String, GroupViewLoader> _loaders = {};

  /// 本次运行内每个成员最近一次**真实发出**的上下文快照（重启后为空）。
  final Map<String, ContextSnapshot> _lastSnapshots = {};

  /// 组级单运行门：正在跑的组（set 里有 = 该组已有成员在运行）。
  final Set<String> _runningGroups = <String>{};

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
  Future<Session> createGroup({String? title, String? workspace}) async {
    final session = await sessionRepo.create(
      title: (title == null || title.trim().isEmpty) ? '新组' : title.trim(),
      kind: Session.kindGroup,
    );
    final resolvedWorkspace =
        (workspace == null || workspace.trim().isEmpty)
            ? ConfigService.homeDir
            : workspace.trim();
    await sidecar.ensureContext(session.id,
        defaultWorkspace: resolvedWorkspace);
    return session;
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

  /// 移除成员：先取消在跑的实例、销毁上下文，再软删（行与历史一律保留）。
  Future<void> removeMember(String groupId, String memberId) async {
    final member = await requireMember(groupId, memberId);
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

  /// 删除组：先销毁全部成员实例，再删会话行（成员/消息/摘要随外键级联删除）。
  Future<void> deleteGroup(String groupId) async {
    await requireGroup(groupId);
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
    _runningGroups.remove(groupId);
  }

  /// 取（必要时创建）成员实例。
  Future<Agent> ensureMemberAgent(GroupMember member) async {
    final existing = agents.lookup(member.handle);
    if (existing != null) return existing;
    final group = await requireGroup(member.groupSessionId);
    // 成员工作区 = 组上下文保存的工作区（只读读取，不给成员私有工作区）。
    final workspace = sidecar.getWorkspace(group.id);
    if (!workspace.ok) {
      throw GroupException(
          'workspace_unavailable',
          '读取组 "${group.id}" 的工作区失败（${workspace.code}）：${workspace.error}'
              ' —— 成员不能用别的目录顶替');
    }
    final agent = await factory.createMember(
      group: group,
      member: member,
      workspace: workspace.workspace ?? '',
      viewLoader: loaderFor(group.id),
      displayNamesResolver: () => displayNamesOf(group.id),
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

  /// 点名一个成员发一轮。带文本时该轮写入**一次**用户公开消息；不带文本时不写空用户行。
  Future<GroupSendOutcome> send({
    required String groupId,
    required String? memberId,
    String? text,
  }) async {
    await requireGroup(groupId);
    if (memberId == null || memberId.trim().isEmpty) {
      throw const GroupException(
          'no_speaker', '群发送必须指定恰好一个发言者（speaker = 成员 id）');
    }
    final member = await requireMember(groupId, memberId);
    if (member.isRemoved) {
      throw GroupException(
          'member_removed', '成员 "${member.name}"（${member.id}）已被移除：不能发言');
    }
    if (isGroupBusy(groupId)) {
      // 可归因 busy：组里已有成员在跑（不排队、不改写到别的成员）。
      return GroupSendOutcome(
        status: 'busy',
        memberId: member.id,
        error: '组 "$groupId" 已有成员在运行：本次点名（${member.name}）没有开始，'
            '没有产生任何消息',
      );
    }

    final agent = await ensureMemberAgent(member);
    // 每轮开始前增量装配：拿到别的成员这一段时间的公开回复。
    await agent.assembleMemberView();

    final trimmed = (text ?? '').trim();
    if (trimmed.isEmpty) {
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

    _runningGroups.add(groupId);
    try {
      final result = await agent.send(
        trimmed.isEmpty ? '' : text!,
        writeUserMessage: trimmed.isNotEmpty,
      );
      final snapshot = agent.contextSnapshot;
      if (snapshot != null) _lastSnapshots[member.id] = snapshot;
      if (result.isBusy) {
        return GroupSendOutcome(
          status: 'busy',
          memberId: member.id,
          error: '成员 "${member.name}" 正在运行：本次调用没有开始',
        );
      }
      return GroupSendOutcome(
        status: result.status.name,
        memberId: member.id,
        finalText: result.finalText,
        error: result.error,
      );
    } finally {
      _runningGroups.remove(groupId);
    }
  }

  /// 本次运行内该成员最近一次真实发出的快照；从未发言（或已重启）⇒ null。
  ContextSnapshot? snapshotOf(String memberId) => _lastSnapshots[memberId];

  /// `agent.cancel` 的组路由。
  ///
  /// - 带 `memberId`：只取消该成员；不在运行 ⇒ 可归因点名（不静默成功）；
  /// - 不带：组内有成员在跑就取消它并返回 memberId；没有 ⇒ 说明"该组当前没有成员在
  ///   运行"（**真话**，不是"查不到实例"）。
  Future<GroupCancelOutcome> cancel(String groupId, {String? memberId}) async {
    await requireGroup(groupId);
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
