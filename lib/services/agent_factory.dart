import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/provider_config.dart';
import '../models/resolved_agent_config.dart';
import '../models/session.dart';
import 'agent.dart';
import 'agent_config_resolver.dart';
import 'agent_registry.dart';
import 'agent_type_registry.dart';
import 'compaction/guard_anchors.dart';
import 'compaction/model_summary_provider.dart';
import 'compaction/seam_selector.dart';
import 'compaction/summary_provider.dart';
import 'message_repository.dart';
import 'provider_resolver.dart';
import 'session_repository.dart';
import 'sidecar_bridge.dart';
import 'summary_node_repository.dart';
import 'tool_catalog.dart';

/// `AgentFactory.ensure` 发现已注册实例的模板名与 Session 保存的 `agent_type`
/// 不一致。
///
/// 这不是"顺手换成新模板"就能解决的：只有显式切换路径（先退役旧对象、再持久化、
/// 再创建新实例）才允许替换运行实例。工厂这里**显式失败**，绝不返回旧实例。
class AgentTemplateMismatchException implements Exception {
  final String sessionId;
  final String actualTemplate;
  final String expectedTemplate;

  const AgentTemplateMismatchException(
    this.sessionId, {
    required this.actualTemplate,
    required this.expectedTemplate,
  });

  @override
  String toString() =>
      '会话 "$sessionId" 的运行实例模板是 "$actualTemplate"，而 Session 现在保存的 '
      'agent_type 是 "$expectedTemplate"：拒绝复用旧实例，也不会静默替换。'
      '切换模板必须走 AgentSessionController.switchTemplate。';
}

/// `AgentFactory.ensure` 发现实例正在退役（已被同一 Session 的新实例替换中）。
class AgentRetiringException implements Exception {
  final String sessionId;
  final String actualTemplate;
  final String expectedTemplate;

  const AgentRetiringException(
    this.sessionId, {
    required this.actualTemplate,
    required this.expectedTemplate,
  });

  @override
  String toString() =>
      '会话 "$sessionId" 的实例（模板 "$actualTemplate"）正在退役'
      '（目标模板 "$expectedTemplate"）：拒绝复用旧实例。';
}

/// 一个候选模板解析出来的、创建实例所需的全部依赖。
///
/// 预检（[AgentFactory.validateCandidate]）与真正创建（[AgentFactory.create]）都
/// 从这一个入口取值，所以两边的规则不会各写一套。
class AgentCandidate {
  final AgentTypeConfig template;
  final ResolvedAgentConfig resolved;
  final ProviderConfig provider;

  /// 创建实例时可复用的 provider 引用表（摘要提供者与分段选择器要用它）。
  final ProviderResolver providers;

  const AgentCandidate({
    required this.template,
    required this.resolved,
    required this.provider,
    required this.providers,
  });
}

/// 统一创建 / 恢复 Agent 实例的工厂。
///
/// 职责：按 `Session.agentType` 找到模板 → 解析不可变生效配置 → 校验工具名与窗口 →
/// 确保上下文 → 恢复消息历史 → 按句柄登记到 [AgentRegistry]。它**不**持有运行实例
/// 的配置真相：实例一旦创建，就只使用自己那份 `ResolvedAgentConfig`。
class AgentFactory {
  /// 模板注册表（只装 `AgentTypeConfig`）。
  final AgentTypeRegistry templates;

  /// provider 引用表（provider 只在创建时解析一次，密钥交给实例当私有依赖）。
  final ProviderResolver? Function() providerResolver;

  /// 当前配置（`spill.preview_chars` 等顶层值）。
  final AppConfig config;

  final ISidecar sidecar;
  final SessionRepository sessionRepo;
  final MessageRepository messageRepo;
  final SummaryNodeRepository summaryNodeRepo;
  final AgentRegistry registry;

  /// 注入的摘要提供者（测试用）。为 null 时生产路径用真实模型提供者。
  final SummaryProvider? summaryProvider;

  /// 注入的分段选择器（测试用）。
  final SeamSelector? seamSelector;

  /// 注入的 guard；为 null 时每个实例按自己模板的不可压缩要求新建一份。
  final GuardAnchors? guard;

  final bool backgroundFoldEnabled;

  /// `summary_nodes` 存储是否可用：注入仓库的用例恒为真；生产仓库要数据库已打开，
  /// 所以在创建实例时才求值（这里传一个函数，而不是 initState 那一刻的布尔值）。
  final bool Function() summaryStoreOpen;

  AgentFactory({
    required this.templates,
    required this.providerResolver,
    required this.config,
    required this.sidecar,
    required this.sessionRepo,
    required this.messageRepo,
    required this.summaryNodeRepo,
    required this.registry,
    this.summaryProvider,
    this.seamSelector,
    this.guard,
    this.backgroundFoldEnabled = true,
    this.summaryStoreOpen = _neverOpen,
  });

  static bool _neverOpen() => false;

  /// 解析候选模板：模板存在、provider 已定义、窗口为正整数、工具名都在目录里。
  ///
  /// 任何一项失败都抛出**可区分**错误（带模板名 / provider 名 / 未知工具名），并且
  /// **不产生任何副作用**：不 ensureContext、不写库、不登记实例。
  AgentCandidate resolveCandidate(String templateName) {
    final template = templates.lookup(templateName);
    if (template == null) {
      throw MissingAgentTemplateException(templateName);
    }
    final providers = providerResolver();
    if (providers == null) {
      // 没有任何 provider 引用表：模板引用的 provider 一律视为未定义。
      throw MissingAgentProviderException(template.name, template.provider);
    }
    final resolver = AgentConfigResolver(providers);
    final resolved = resolver.resolve(
      template: template,
      spillPreviewChars: config.spillPreviewChars,
    );
    final provider = resolver.resolveProvider(resolved);
    // 未知工具名在创建时显式失败并列出名字（不静默少给）。
    ToolCatalog.instance.resolve(resolved.tools,
        context: '模板 "${template.name}"');
    return AgentCandidate(
      template: template,
      resolved: resolved,
      provider: provider,
      providers: providers,
    );
  }

  /// 候选预检：与 [create] 共用 [resolveCandidate] 的同一套规则，只解析不创建。
  ///
  /// 切换模板时先调它；失败时旧实例、数据库与界面选择都不动。
  void validateCandidate(String templateName) => resolveCandidate(templateName);

  /// 按会话的 `agentType` 创建实例；模板缺失 / provider 缺失 / 窗口非法 / 工具未知
  /// 都抛出**可区分**错误，绝不静默改用 `general` 或按 0 继续发送。
  Future<Agent> create(Session session,
      {AgentCallbacks callbacks = const AgentCallbacks()}) async {
    final candidate = resolveCandidate(session.agentType);
    final template = candidate.template;
    final resolved = candidate.resolved;

    final guardForAgent = guard ?? _guardFrom(template);
    final injectedSummary = summaryProvider != null;
    final summary = summaryProvider ??
        ModelSummaryProvider(sidecar: sidecar, resolver: candidate.providers);
    final seams = seamSelector ??
        (!injectedSummary
            ? ModelSeamSelector(sidecar: sidecar, resolver: candidate.providers)
            : null);

    final agent = Agent(
      sessionId: session.id,
      agentTypeName: template.name,
      config: resolved,
      template: template,
      provider: candidate.provider,
      sessionRepo: sessionRepo,
      messageRepo: messageRepo,
      summaryNodeRepo: summaryNodeRepo,
      sidecar: sidecar,
      summaryProvider: summary,
      seamSelector: seams,
      guard: guardForAgent,
      backgroundFoldEnabled: backgroundFoldEnabled,
      summaryStoreOpen: summaryStoreOpen(),
      callbacks: callbacks,
    );
    await agent.ensureContext();
    await agent.restore();
    registry.register(agent);
    return agent;
  }

  /// 取该会话的运行实例；已有则复用，没有才创建。
  ///
  /// 复用前必须核对两件事，否则显式失败（不静默返回旧实例）：
  /// ① 实例的模板名与 Session 保存的 `agent_type` 一致；② 实例没有在退役。
  /// 正常切换走 `AgentSessionController.switchTemplate`，它先退役旧对象再创建新实例。
  Future<Agent> ensure(Session session,
      {AgentCallbacks callbacks = const AgentCallbacks()}) async {
    final existing = registry.lookup(session.id);
    if (existing != null) {
      if (existing.isRetiring) {
        throw AgentRetiringException(
          session.id,
          actualTemplate: existing.agentTypeName,
          expectedTemplate: session.agentType,
        );
      }
      if (existing.agentTypeName != session.agentType) {
        throw AgentTemplateMismatchException(
          session.id,
          actualTemplate: existing.agentTypeName,
          expectedTemplate: session.agentType,
        );
      }
      await existing.ensureContext();
      return existing;
    }
    return create(session, callbacks: callbacks);
  }

  GuardAnchors _guardFrom(AgentTypeConfig template) {
    final g = GuardAnchors();
    if (template.standingRequirements.isNotEmpty) {
      g.setStandingRequirements(template.standingRequirements);
    }
    return g;
  }
}
