import 'dart:async';

import '../models/session.dart';
import 'agent.dart';
import 'agent_config_resolver.dart';
import 'agent_factory.dart';
import 'session_repository.dart';
import 'tool_catalog.dart';

/// 一次 Session 模板切换失败的阶段。
///
/// 界面必须显示**具体阶段**与候选模板名：只说"切换失败"用户无法判断是模板写错、
/// 数据库没更新，还是新实例没建起来。
enum AgentSwitchStage {
  preflight('候选预检'),
  retire('退役旧实例'),
  persist('持久化 agent_type'),
  create('创建新实例'),
  busy('重复切换'),
  deleting('会话正在删除');

  const AgentSwitchStage(this.label);

  /// 给用户看的阶段名。
  final String label;
}

/// 切换模板失败：带阶段与候选模板名，不伪装成功、不静默退回 `general`。
class AgentSwitchException implements Exception {
  final AgentSwitchStage stage;
  final String candidateName;
  final String message;

  const AgentSwitchException({
    required this.stage,
    required this.candidateName,
    required this.message,
  });

  @override
  String toString() =>
      'Agent 模板切换失败（候选 "$candidateName"，阶段：${stage.label}）：$message';
}

/// 协调"当前 Session 换一个 Agent 模板"的完整流程。
///
/// 顺序钉死为：① 候选名与当前相同则无需操作；② 预检候选模板 / provider / 正整数
/// 窗口 / 工具目录（与 [AgentFactory.create] 共用同一套规则），失败时旧实例、数据库
/// 与界面选择都不变；③ 登记该 Session 的切换 Future，让重复切换与删除期间的切换被
/// 拒绝；④ 退役旧 Agent 对象（只阻止新调用，不 `cancelRequest` / `disposeContext`，
/// 在途整轮与后台压缩写库自然结束）；⑤ 持久化新的 `agent_type` 并**重新读取**该行；
/// ⑥ 用重读后的 Session 与调用方给的界面回调创建并注册新实例。
///
/// 同一 Session 的上下文句柄、工作区、浏览器上下文、工具输出溢出目录与序号都保留
/// 给新实例 —— 退役不销毁上下文，只有删除 Session / 关闭应用才销毁。
class AgentSessionController {
  AgentSessionController({
    required this.factory,
    required this.sessionRepo,
    Future<void> Function(Agent agent)? retireAgent,
  }) : _retireAgent = retireAgent ?? _defaultRetire;

  final AgentFactory factory;
  final SessionRepository sessionRepo;

  /// 退役动作。生产路径就是 [Agent.retire]；测试用它注入退役失败。
  final Future<void> Function(Agent agent) _retireAgent;

  static Future<void> _defaultRetire(Agent agent) => agent.retire();

  /// 正在切换的 Session → 切换 Future。
  final Map<String, Future<Agent>> _switching = {};

  /// 正在删除的 Session（此期间拒绝切换）。
  final Set<String> _deleting = {};

  bool isSwitching(String sessionId) => _switching.containsKey(sessionId);

  bool isDeleting(String sessionId) => _deleting.contains(sessionId);

  Agent? agentFor(String sessionId) => factory.registry.lookup(sessionId);

  /// 该 Session 是否有一个切换正在进行（界面据此禁用发送）。
  bool isSwitchInProgress(String sessionId) => _switching.containsKey(sessionId);

  /// 把 [session] 的 Agent 模板切到 [candidateName]，返回新注册的实例。
  ///
  /// [callbacks] 必须是**该 Session 的界面回调**（`ChatScreen._callbacksFor(id)`），
  /// 新实例靠它把消息送到聊天区；传默认空回调会让切换后的回复看不见。
  ///
  /// 失败抛 [AgentSwitchException]：`stage` 指出卡在哪一步，`candidateName` 是候选名。
  Future<Agent> switchTemplate(
    Session session,
    String candidateName, {
    required AgentCallbacks callbacks,
  }) {
    final sessionId = session.id;
    if (_deleting.contains(sessionId)) {
      return Future<Agent>.error(AgentSwitchException(
        stage: AgentSwitchStage.deleting,
        candidateName: candidateName,
        message: '会话 "$sessionId" 正在删除：拒绝切换模板。',
      ));
    }
    if (_switching.containsKey(sessionId)) {
      return Future<Agent>.error(AgentSwitchException(
        stage: AgentSwitchStage.busy,
        candidateName: candidateName,
        message: '会话 "$sessionId" 已经有一个切换正在进行：拒绝重复切换。',
      ));
    }
    final completer = Completer<Agent>();
    final tracked = completer.future;
    // 先同步登记，再开始异步工作：这样同一帧里的第二个切换会看到"已在切换"。
    _switching[sessionId] = tracked;
    final result = tracked.whenComplete(() {
      if (identical(_switching[sessionId], tracked)) _switching.remove(sessionId);
    });
    unawaited(_runSwitch(session, candidateName, callbacks, completer));
    return result;
  }

  Future<void> _runSwitch(
    Session session,
    String candidateName,
    AgentCallbacks callbacks,
    Completer<Agent> completer,
  ) async {
    try {
      // ① 候选名与当前相同：无需操作（实例已在则直接返回；没有才补建一个）。
      if (session.agentType == candidateName) {
        final existing = factory.registry.lookup(session.id);
        if (existing != null && !existing.isRetiring) {
          completer.complete(existing);
          return;
        }
      }

      // ② 预检：与创建路径同一套规则，失败时没有任何副作用。
      try {
        factory.validateCandidate(candidateName);
      } on AgentConfigException catch (e) {
        throw AgentSwitchException(
          stage: AgentSwitchStage.preflight,
          candidateName: candidateName,
          message: e.toString(),
        );
      } on UnknownToolsException catch (e) {
        throw AgentSwitchException(
          stage: AgentSwitchStage.preflight,
          candidateName: candidateName,
          message: e.toString(),
        );
      }

      // ③ 退役旧 Agent 对象：只阻止新调用，**不** cancelRequest / disposeContext，
      //    在途整轮与后台压缩写库自然结束；同 Session 的上下文与溢出文件保留。
      final old = factory.registry.lookup(session.id);
      if (old != null) {
        try {
          await _retireAgent(old);
        } catch (e) {
          throw AgentSwitchException(
            stage: AgentSwitchStage.retire,
            candidateName: candidateName,
            message: '$e',
          );
        }
        factory.registry.remove(session.id);
      }

      // ④ 持久化并**重新读取**该行；没更新到唯一既有行、或读不到该行时显式失败，
      //    不创建新实例。重读由控制器自己做一遍，不依赖仓库返回值。
      Session? reread;
      try {
        await sessionRepo.updateAgentType(session.id, candidateName);
        reread = await sessionRepo.get(session.id);
      } catch (e) {
        throw AgentSwitchException(
          stage: AgentSwitchStage.persist,
          candidateName: candidateName,
          message: '$e',
        );
      }
      if (reread == null) {
        throw AgentSwitchException(
          stage: AgentSwitchStage.persist,
          candidateName: candidateName,
          message: '会话 "${session.id}" 在切换过程中被删除：不创建新实例。',
        );
      }
      if (reread.agentType != candidateName) {
        throw AgentSwitchException(
          stage: AgentSwitchStage.persist,
          candidateName: candidateName,
          message: '重新读取的 Session 仍保存 "${reread.agentType}"：不创建新实例。',
        );
      }

      // ⑤ 用重读后的 Session 与**该 Session 的界面回调**创建新实例。
      Agent agent;
      try {
        agent = await factory.create(reread, callbacks: callbacks);
      } catch (e) {
        throw AgentSwitchException(
          stage: AgentSwitchStage.create,
          candidateName: candidateName,
          message: '$e',
        );
      }
      completer.complete(agent);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  /// 等待该 Session 正在进行的切换结束（没有则立即返回；失败也被吞掉 —— 删除流程
  /// 关心的是"切换已经停下"，不是它成功与否）。
  Future<void> waitForSwitch(String sessionId) async {
    final inFlight = _switching[sessionId];
    if (inFlight == null) return;
    try {
      await inFlight;
    } catch (_) {
      // 切换自己失败也算"结束"。
    }
  }

  /// 删除会话的第一步：登记删除（此后该会话的切换一律被拒）、等待已在进行的切换
  /// 结束，然后**重新读取**数据库里的 Session。
  ///
  /// 返回 null 表示该行已经不存在（例如切换过程中被别处删掉）。调用方拿到返回的
  /// 最新行再决定删除动作；只有 `endDelete` 之后才允许再次切换。
  Future<Session?> beginDelete(String sessionId) async {
    _deleting.add(sessionId);
    await waitForSwitch(sessionId);
    return sessionRepo.get(sessionId);
  }

  /// 删除结束（成功、失败或放弃）后调用，解除对该会话切换的封锁。
  void endDelete(String sessionId) => _deleting.remove(sessionId);
}
