// 一次性子 Agent 的运行服务（change `add-spawn-subagent-tool`）。
//
// 职责边界：
//   - 校验工具输入与候选模板（与普通创建共用 `AgentFactory.resolveCandidate`）；
//   - 按父句柄**只读**读取父上下文实际保存的工作区，交给子上下文初始化；
//   - 建一条带 `parent_session_id` 的子会话记录，再用同一个工厂创建子 Agent
//     （不传父界面回调、系统提示词附加子角色说明、工具清单排除 `spawn_subagent`）；
//   - 同步等待子 Agent 整轮结束，只把最终结论交回父工具结果。
//
// 第一版不做下一层子 Agent、不做并行调度、不做异步消息；这些由“工具清单排除”和
// “同步等待”直接保证，而不是运行到递归调用时才静默失败。
import 'package:flutter/foundation.dart';

import '../models/session.dart';
import 'agent.dart';
import 'agent_config_resolver.dart';
import 'agent_factory.dart';
import 'sidecar_bridge.dart';
import 'tool_catalog.dart';

/// 附加在子 Agent 配置系统提示词后面的角色说明。
///
/// 子 Agent 看不到父对话，它的上下文在结束时销毁；所以最终回复必须自包含，
/// 不能只留下自己的 `read_spill` 引用。需要持续保留的内容要写进继承的工作区。
const String kSubagentRolePrompt = '你是一次性子 Agent：你看不到父对话的历史，'
    '本次任务就是你的全部输入。结束时只输出一段自包含的最终结论（必要的背景、'
    '结论与文件路径都写清楚）。不要只留下仅供你自己上下文使用的 read_spill 引用 —— '
    '你的上下文会在结束时销毁，那些引用随后就失效；需要持续保留的内容请写进当前'
    '工作区的文件。你不能创建下一层子 Agent。';

/// 子运行准备失败的可区分原因。父模型看到的是 `code: message` 形式的错误文本。
class SubagentFailure {
  const SubagentFailure(this.code, this.message);

  /// `invalid_task` / `invalid_agent_type` / `workspace_unavailable` /
  /// `child_session_failed` / `child_create_failed`。
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 子运行准备结果：成功时 [child] 与 [childSession] 已创建，失败时 [failure] 非空。
class SubagentPreparation {
  const SubagentPreparation.ready({
    required Agent this.child,
    required Session this.childSession,
    required String this.templateName,
    required String this.workspace,
  }) : failure = null;

  const SubagentPreparation.rejected(SubagentFailure this.failure)
      : child = null,
        childSession = null,
        templateName = null,
        workspace = null;

  final Agent? child;
  final Session? childSession;
  final String? templateName;
  final String? workspace;
  final SubagentFailure? failure;

  bool get ok => failure == null;
}

/// 子运行服务：父 Agent 的工具分发只调 [run]，创建路径全部在这里。
///
/// 工厂通过延迟回调注入，避免“工厂创建 Agent、Agent 又需要运行器、运行器再使用
/// 工厂”的构造循环；生产与测试都走同一条创建路径。
class SubagentRunner {
  SubagentRunner({
    required AgentFactory Function() factory,
    required ISidecar sidecar,
  })  : _factoryBuilder = factory,
        _sidecar = sidecar;

  final AgentFactory Function() _factoryBuilder;
  final ISidecar _sidecar;

  /// 父会话 id → 正在运行的子会话 id（活动关系表）。同一时间存在哪些子运行以
  /// 这张表为准，不从界面状态推断。
  final Map<String, Set<String>> _activeByParent = <String, Set<String>>{};

  AgentFactory get _factory => _factoryBuilder();

  /// 活动关系的只读快照（测试与诊断用）。
  Map<String, List<String>> get activeRelations => Map<String, List<String>>.unmodifiable(
      _activeByParent.map((parent, children) =>
          MapEntry(parent, List<String>.unmodifiable(children))));

  /// 单独取消某个子运行（按子会话 id）。返回是否找到并取消了一个活动子实例。
  bool cancelChild(String childSessionId) {
    final child = _factory.registry.lookup(childSessionId);
    if (child == null) return false;
    child.cancel();
    return true;
  }

  /// 取消某个父会话正在运行的全部子 Agent（父 `cancel` / `dispose` 先走这里）。
  void cancelChildrenOf(String parentSessionId) {
    for (final childId in _activeByParent[parentSessionId] ?? const <String>{}) {
      _factory.registry.lookup(childId)?.cancel();
    }
  }

  void _registerChild(String parentSessionId, String childSessionId) {
    _activeByParent
        .putIfAbsent(parentSessionId, () => <String>{})
        .add(childSessionId);
  }

  void _unregisterChild(String parentSessionId, String childSessionId) {
    final children = _activeByParent[parentSessionId];
    if (children == null) return;
    children.remove(childSessionId);
    if (children.isEmpty) _activeByParent.remove(parentSessionId);
  }

  /// 出口清理：等子整轮结束、销毁子上下文、从运行实例注册表移除。
  ///
  /// 失败时返回可区分错误（调用方不得当成成功）；无论成败都从注册表移除并解除
  /// 活动关系，子会话数据库记录**不**删除。
  Future<SubagentFailure?> _cleanupChild(Agent child) async {
    try {
      await child.dispose();
      _factory.registry.remove(child.sessionId);
      return null;
    } catch (e) {
      _factory.registry.remove(child.sessionId);
      return SubagentFailure(
          'cleanup_failed', '子上下文销毁失败（资源可能未释放）：$e');
    }
  }

  /// 校验输入并创建子运行（不发送模型请求）。
  ///
  /// 任何一步失败都**不**留下子会话、子上下文或运行实例。父模板名、父实例配置和
  /// 共享工具目录都不会被改写。
  Future<SubagentPreparation> prepare({
    required Agent parent,
    required Map<String, dynamic> input,
  }) async {
    // ① 任务必须是非空字符串：在碰任何外部状态之前判掉。
    final rawTask = input['task'];
    if (rawTask is! String || rawTask.trim().isEmpty) {
      return const SubagentPreparation.rejected(
          SubagentFailure('invalid_task', 'task 必须是非空字符串'));
    }

    // ② agent_type 省略时继承父模板；显式给出时必须是（去空白后）非空字符串。
    final rawType = input['agent_type'];
    if (rawType != null && (rawType is! String || rawType.trim().isEmpty)) {
      return const SubagentPreparation.rejected(SubagentFailure(
          'invalid_agent_type', 'agent_type 必须省略，或给出非空字符串'));
    }
    final templateName =
        rawType == null ? parent.agentTypeName : (rawType as String).trim();

    final factory = _factory;

    // ③ 与普通创建同一套候选解析：模板 / provider / 正整数窗口 / 工具目录。
    //    失败时没有任何副作用（不 ensureContext、不写库、不登记实例）。
    try {
      factory.validateCandidate(templateName);
    } on AgentConfigException catch (e) {
      return SubagentPreparation.rejected(
          SubagentFailure('invalid_agent_type', '候选模板 "$templateName"：$e'));
    } on UnknownToolsException catch (e) {
      return SubagentPreparation.rejected(
          SubagentFailure('invalid_agent_type', '候选模板 "$templateName"：$e'));
    }

    // ④ 父工作区按父句柄只读读取：不假定等于应用主目录，也不读界面当前会话。
    final WorkspaceQueryResult workspaceResult;
    try {
      workspaceResult = _sidecar.getWorkspace(parent.sessionId);
    } on StateError catch (e) {
      return SubagentPreparation.rejected(SubagentFailure(
          'workspace_unavailable', '读取父上下文工作区失败：$e'));
    }
    if (!workspaceResult.ok) {
      return SubagentPreparation.rejected(SubagentFailure(
          'workspace_unavailable',
          '读取父上下文工作区失败：${workspaceResult.code}: '
              '${workspaceResult.error}'));
    }
    final workspace = workspaceResult.workspace ?? '';
    debugPrint('[AliasAgent] spawn_subagent: 父句柄=${parent.sessionId} '
        '模板=$templateName 继承工作区="$workspace"');

    // ⑤ 建子会话记录（带 parent_session_id）。普通列表与启动恢复都不会看到它。
    final sessionRepo = factory.sessionRepo;
    final Session childSession;
    try {
      childSession = await sessionRepo.create(
        title: '子 Agent 运行',
        agentType: templateName,
        parentSessionId: parent.sessionId,
      );
    } catch (e) {
      return SubagentPreparation.rejected(SubagentFailure(
          'child_session_failed', '创建子运行记录失败：$e'));
    }

    // ⑥ 用同一个工厂创建子实例：无父界面回调、子角色说明、工具清单排除
    //    spawn_subagent、上下文初始化到父工作区。
    final Agent child;
    try {
      child = await factory.create(
        childSession,
        child: ChildRunOptions(
          workspace: workspace,
          systemPromptSuffix: kSubagentRolePrompt,
        ),
      );
    } catch (e) {
      // 子实例没建起来：删掉刚建的子会话记录，不留下半个运行。
      try {
        await sessionRepo.delete(childSession.id);
      } catch (_) {}
      return SubagentPreparation.rejected(
          SubagentFailure('child_create_failed', '创建子 Agent 失败：$e'));
    }

    return SubagentPreparation.ready(
      child: child,
      childSession: childSession,
      templateName: templateName,
      workspace: workspace,
    );
  }

  /// 同步运行一个子 Agent：准备 → 发送任务 → 等待整轮结束，只把最终结论交回。
  ///
  /// 第一版的结果形状最小化；完整的 `child_session_id` / 模板 / 模型 / 计量与
  /// 可区分错误码在后续任务里补齐。失败一律 `ok:false`，不伪装成功。
  Future<Map<String, dynamic>> run({
    required Agent parent,
    required Map<String, dynamic> input,
  }) async {
    final prepared = await prepare(parent: parent, input: input);
    final failure = prepared.failure;
    if (failure != null) {
      return {
        'ok': false,
        'code': failure.code,
        'error': failure.toString(),
      };
    }
    final child = prepared.child!;
    final childId = child.sessionId;
    final task = (input['task'] as String).trim();
    _registerChild(parent.sessionId, childId);

    Map<String, dynamic>? mapped;
    SubagentFailure? cleanupFailure;
    try {
      try {
        final result = await child.send(task);
        mapped = mapRunResult(child, result);
      } catch (e) {
        mapped = {
          'ok': false,
          'code': 'subagent_exception',
          'error': '子 Agent 运行异常：$e',
          'child_session_id': childId,
        };
      }
    } finally {
      // 所有出口（成功 / 失败 / 取消 / 异常）都走同一条清理路径。
      cleanupFailure = await _cleanupChild(child);
      _unregisterChild(parent.sessionId, childId);
    }

    if (cleanupFailure != null) {
      // 清理失败不得返回成功：资源是否真的释放没被证明。
      return {
        'ok': false,
        'code': 'cleanup_failed',
        'error': cleanupFailure.toString(),
        'child_session_id': childId,
      };
    }
    return mapped;
  }

  /// 把子 Agent 的结构化结果映射成 `spawn_subagent` 的工具结果。
  ///
  /// 成功时 `content` 只放最终结论；`child_session_id` / 实际模板 / 实际模型 /
  /// 子 Agent 计量作为额外键返回（只用于父工具活动与 `toolCallsJson`，不进入父模型
  /// 可见的 `tool_result.content`）。失败一律 `ok:false` + 可区分 `code`；空最终
  /// 文本映射为 `empty_final_response`，不得当成成功空串。
  static Map<String, dynamic> mapRunResult(Agent child, AgentRunResult result) {
    final base = <String, dynamic>{'child_session_id': child.sessionId};
    switch (result.status) {
      case AgentRunStatus.completed:
        final text = result.finalText ?? '';
        if (text.trim().isEmpty) {
          return {
            ...base,
            'ok': false,
            'code': 'empty_final_response',
            'error': '子 Agent 完成但没有最终文本（不允许当成成功结论）',
          };
        }
        return {
          ...base,
          'ok': true,
          'content': text,
          'agent_type': child.agentTypeName,
          'model': child.config.model,
          'metering': result.metering.toJson(),
        };
      case AgentRunStatus.failed:
        return {
          ...base,
          'ok': false,
          'code': 'subagent_failed',
          'error': result.error ?? '子 Agent 失败（没有错误文本）',
        };
      case AgentRunStatus.cancelled:
        return {
          ...base,
          'ok': false,
          'code': 'subagent_cancelled',
          'error': '子 Agent 被取消，本轮没有结论',
        };
      case AgentRunStatus.busy:
        return {
          ...base,
          'ok': false,
          'code': 'subagent_busy',
          'error': '子 Agent 实例正忙：本次调用没有开始',
        };
    }
  }
}
