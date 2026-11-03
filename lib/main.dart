import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/agent_type_config.dart';
import 'models/app_config.dart';
import 'models/chat_item.dart';
import 'models/compaction_status.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'models/tool_call_activity.dart';
import 'services/agent.dart';
import 'services/agent_config_resolver.dart';
import 'services/agent_factory.dart';
import 'services/agent_registry.dart';
import 'services/agent_session_controller.dart';
import 'services/agent_template_controller.dart';
import 'services/agent_type_registry.dart';
import 'services/spill_paths.dart';
import 'services/compaction/guard_anchors.dart';
import 'services/compaction/seam_selector.dart';
import 'services/compaction/summary_provider.dart';
import 'services/config_service.dart';
import 'services/context_snapshot.dart';
import 'services/database_service.dart';
import 'services/message_repository.dart';
import 'services/provider_resolver.dart';
import 'services/session_repository.dart';
import 'services/sidecar_bridge.dart';
import 'services/subagent_runner.dart';
import 'services/summary_node_repository.dart';
import 'services/tool_catalog.dart';
import 'services/tool_result_text.dart' as tool_text;
import 'ui/agent_template_editor.dart';
import 'ui/agent_template_menu.dart';
import 'ui/chat_area.dart';
import 'ui/context_ring.dart';
import 'ui/input_bar.dart';
import 'ui/context_view.dart';
import 'ui/session_agent_switcher.dart';
import 'ui/session_sidebar.dart';
import 'ui/setup_dialog.dart';

final registry = AgentTypeRegistry();
ProviderResolver? resolver;

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  // 无主的 spill 目录（`no-session` 与测试留下的 `_it_*`）对应不到任何会话，
  // "删会话"永远删不到它们 —— 启动时清一次，别让它只增不减。
  try {
    final removed = cleanOrphanSpillDirs();
    if (removed.isNotEmpty) {
      debugPrint('[AliasAgent] 启动清理无主 spill 目录：$removed');
    }
  } catch (e) {
    debugPrint('[AliasAgent] 清理无主 spill 目录失败：$e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AliasAgent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  final ConfigResult Function()? configLoader;
  const AppShell({super.key, this.configLoader});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppConfig? _config;
  String? _error;

  /// 旧默认工具清单迁移的可见提示（任务 1.3）：非空时由 ChatScreen 显示在界面上，
  /// 不能只写一行日志。
  String? _toolMigrationNotice;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _loadConfig() {
    final result = widget.configLoader != null ? widget.configLoader!() : ConfigService.load();
    switch (result.status) {
      case ConfigStatus.ok:
        // 旧版首启写出的两项默认清单在这里升级，并把提示带到界面上；自定义清单不动。
        final migration = ToolListMigration.migrate(result.config!);
        if (migration.changed) {
          try {
            ConfigService.save(migration.config);
          } catch (e) {
            debugPrint('[AliasAgent] 旧工具清单迁移写回失败：$e');
          }
          debugPrint('[AliasAgent] 旧工具清单迁移：${migration.migratedTemplates}');
        }
        setState(() {
          _config = migration.config;
          _toolMigrationNotice =
              migration.notices.isEmpty ? null : migration.notices.join('\n');
          _populateRegistry(migration.config);
        });
        // R1-7: maxContextTokens is a REQUIRED per-agent config (like apiKey).
        // If the loaded config's active agent lacks a valid maxContextTokens,
        // surface the setup prompt again rather than silently disabling compaction
        // (which the user would otherwise not know about). One-time config.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final mct = registry.lookup('general')?.maxContextTokens;
          if (mct == null || mct <= 0) {
            _showSetup();
          }
        });
      case ConfigStatus.notFound:
        WidgetsBinding.instance.addPostFrameCallback((_) => _showSetup());
      case ConfigStatus.malformed:
        setState(() => _error = result.error);
    }
  }

  void _populateRegistry(AppConfig config) {
    for (final type in config.agentTypes.values) {
      registry.register(type);
    }
    resolver = ProviderResolver(config);
  }

  void _showSetup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => SetupDialog(
        // 补问必须合并到现有配置，不整份覆盖（首启时 _config 为 null）。
        existingConfig: _config,
        onComplete: () {
          Navigator.of(context).pop();
          _loadConfig();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          title: const Text('Configuration Error'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, style: Theme.of(context).textTheme.bodyLarge),
          ),
        ),
      );
    }

    if (_config == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: ChatScreen(
        config: _config!,
        toolMigrationNotice: _toolMigrationNotice,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ChatScreen — the main chat UI with sidebar + chat area
// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  final AppConfig config;
  final SessionRepository? sessionRepo;
  final MessageRepository? msgRepo;
  final ISidecar? sidecar;
  final SummaryProvider? summaryProvider;
  final SeamSelector? seamSelector;
  final GuardAnchors? guard;

  /// The compaction tree store (summary_nodes). Injectable so a hermetic widget
  /// test can preset "nodes already persisted by an earlier round" and read back
  /// what the pipeline stored — a real sqflite database cannot be driven from a
  /// `testWidgets` body, because that body runs in a FakeAsync zone where real
  /// async I/O completions are never delivered (measured: the test hangs).
  final SummaryNodeRepository? summaryNodeRepo;

  /// Idle-gated background folding (2.6). Defaults to production behavior
  /// (enabled when no summary provider is injected). Hermetic widget tests inject
  /// a fake summary provider, so it defaults OFF there; a test may override this
  /// to true to exercise the fold with a fake provider against a real in-memory DB.
  final bool? backgroundFoldEnabled;

  /// 旧默认工具清单迁移的可见提示（任务 1.3）。非空时界面顶部显示一行说明。
  final String? toolMigrationNotice;

  /// 注入的模板保存协调器（集成测试用来指向临时配置，避免碰用户真实配置）。
  final AgentTemplateController? agentTemplateController;

  /// 注入的 Session 切换协调器（集成测试用来注入退役 / 写库 / 创建失败）。
  final AgentSessionController? agentSessionController;

  /// 注入的运行实例注册表。集成测试要在**界面之外**造一个与界面共用同一注册表的
  /// `AgentFactory`（这样才能注入切换失败并让界面看到同一个实例），所以注册表必须
  /// 可以注入；不注入时界面自己新建一个。
  final AgentRegistry? agentRegistry;

  const ChatScreen({
    super.key,
    required this.config,
    this.sessionRepo,
    this.msgRepo,
    this.sidecar,
    this.summaryProvider,
    this.seamSelector,
    this.guard,
    this.summaryNodeRepo,
    this.backgroundFoldEnabled,
    this.toolMigrationNotice,
    this.agentTemplateController,
    this.agentSessionController,
    this.agentRegistry,
  });

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  late final SessionRepository _sessionRepo;
  late final MessageRepository _msgRepo;
  late final ISidecar _sidecar;
  late final SummaryNodeRepository _summaryNodeRepo;

  /// 统一创建 / 恢复 Agent 实例的工厂（change `add-agent-object-and-templates`
  /// 任务 2.2）。模型执行、工具调用、摘要与这些调用产生的写库都由 Agent 负责；
  /// ChatScreen 只保留会话列表、输入与展示。
  late final AgentFactory _agentFactory;

  /// 按上下文句柄管理运行实例（与模板注册表 `registry` 是两个对象）。
  late final AgentRegistry _agents;

  /// 一次性子运行服务（add-spawn-subagent-tool）：工厂用延迟回调注入，避免
  /// “工厂创建 Agent、Agent 又需要运行器、运行器再使用工厂”的构造循环。
  late final SubagentRunner _subagentRunner;

  /// 模板保存协调器：校验 → 写回完整配置 → 更新模板注册表。
  late final AgentTemplateController _templateController;

  /// Session 换模板的协调器：候选预检 → 退役旧 Agent 对象 → 持久化并重读
  /// Session → 用同一 Session 句柄与界面回调创建新实例；同时负责切换与删除互斥。
  late final AgentSessionController _sessionController;

  /// 2.6 background folding: enabled iff no summary provider is injected
  /// (production), unless the test overrides [ChatScreen.backgroundFoldEnabled].
  late final bool _backgroundFoldEnabled;

  List<Session> _sessions = [];
  String? _currentId;
  List<ChatItem> _chatItems = [];

  /// 最近一次真正发出去的上下文快照。跨会话切换时保留（带 sessionId 标签），
  /// 只有第一次发送之前才是 null。
  ContextSnapshot? _contextSnapshot;

  /// Read-only view of the captured snapshot for the UI and tests.
  ContextSnapshot? get contextSnapshot => _contextSnapshot;

  /// 当前会话的 Agent（没有会话时为 null）。
  Agent? get _currentAgent =>
      _currentId == null ? null : _agents.lookup(_currentId!);

  /// 当前会话（列表里那一行；没有当前会话时为 null）。
  Session? get _currentSession {
    final id = _currentId;
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 当前会话的运行实例（只读出口：实机与集成测试据此确认切换真的替换了对象）。
  Agent? get currentAgent => _currentAgent;

  /// 当前会话是否正在切换 Agent 模板（只读出口，给测试与界面判断）。
  bool get isSwitchingTemplate => _switchingTemplate;

  /// 压缩进行中的状态：**由产生它的 Agent 实例持有**，界面只读当前实例那一份。
  /// 切走之后旧会话的压缩提示不会再挂到新会话上。
  CompactionStatus get compactionStatus =>
      _currentAgent?.compactionStatus ?? CompactionStatus.idle;

  /// 正在发送与否也读当前实例的状态（界面只用它来画流式指示）。
  bool get _isStreaming => _currentAgent?.isStreaming ?? false;

  /// Which view the conversation area shows: the original conversation view or
  /// the real context view (task 3.1). Defaults to the conversation view.
  ContextViewMode _viewMode = ContextViewMode.conversation;

  /// The MOST RECENT final assistant reply of the current turn, read from state
  /// (not the widget tree) by the live test. Returns null when no final reply
  /// has been stored yet — i.e. the turn is still in an intermediate tool round
  /// (isFinalReply==false), or the model produced an empty final text / an
  /// internal exception ended the turn. Scans from the END so that across a
  /// multi-turn session an earlier turn's final reply is not misreported as the
  /// current one.
  String? get finalAssistantReply {
    for (final item in _chatItems.reversed) {
      if (item is ChatMessageItem &&
          item.isFinalReply &&
          item.message.content.trim().isNotEmpty) {
        return item.message.content;
      }
    }
    return null;
  }

  bool _loading = true;

  /// 创建 / 恢复 Agent 失败的可见错误（模板缺失、provider 未定义、窗口非法、未知工具）。
  String? _agentError;

  /// 当前会话是否正在切换 Agent 模板（切换中禁发送、禁重复切换）。
  bool _switchingTemplate = false;

  /// 切换中尝试发送时的可见提示（不静默拒绝：用户按了回车/点了发送总要有回应）。
  String? _switchBlockedNotice;

  /// 工具定义**唯一只读目录**的入口（change `add-agent-object-and-templates`
  /// 任务 1.3）。定义仍然由 [_initSearchAndTools] 决定"什么时候注册哪些"，
  /// 但读的一律走 `ToolCatalog`，不再各自持有一份私有 map。
  Map<String, Map<String, dynamic>> get _toolDefs =>
      ToolCatalog.instance.definitions;

  /// 工具清单是否已经装好（含动态那批）。`_initSearchAndTools()` 完成时置真；
  /// 在此之前 `ChatArea` 会挡住发送 —— 否则那一轮请求里的工具清单是残缺的（缺
  /// `web_search` / `web_fetch` / 浏览器四件套），模型会白白空转一轮（真机实测过）。
  bool _toolsReady = false;

  /// 工具目录就绪信号：Agent 创建时要按目录校验模板工具名，所以必须等条件注册
  /// （搜索 / 浏览器）完成后再创建实例，否则"模板允许 web_search"会在启动瞬间被
  /// 误判成未知工具。
  final Completer<void> _toolsReadyCompleter = Completer<void>();

  /// 输入框的文本控制器。**2026-10-18 从 `ChatArea` 搬到这里** —— 输入行现在由这个
  /// 文件构造、两屏共用（见 `lib/ui/input_bar.dart` 的 `InputBar`）。
  final _inputCtrl = TextEditingController();

  /// 已经贴进来、还没发出去的图片路径（只存路径，见 `lib/models/message.dart`
  /// 的 `attachments`）。发送时整批交给这条用户消息，然后清空。
  final List<String> _pendingImagePaths = [];

  /// 贴图失败时要在界面上显示的一句话（null = 不显示）。清空时机是下一次贴图
  /// 成功或用户下一次发送 —— 不让它一直挂在那里。
  String? _pasteImageNotice;

  /// 把剪贴板里的图贴进输入区（「粘贴图片」按钮与 `Ctrl+V` 都走这里）。
  ///
  /// 落盘由 sidecar 的 `read_clipboard_image` 做（PNG 优先、DIB 转 PNG），这里只
  /// 收它的返回：成功就把**路径**加进待发列表，失败就给出可见提示（不静默）。
  Future<bool> _pasteImageFromClipboard() async {
    // 18.3（2026-10-25）：工具还没就绪时**不许静默返回 false** —— 用户点一下
    // 什么反应都没有，只会以为按钮坏了。给一句看得见的话，原因写清楚。
    if (!_toolsReady) {
      if (mounted) {
        setState(() => _pasteImageNotice = '工具还在准备，稍等一下再贴图');
      }
      return false;
    }
    String? failure;
    try {
      if (_currentId == null) await _newChat();
      final raw = _sidecar.readClipboardImage(
          _currentId ?? '', jsonEncode({'dest_dir': ConfigService.attachmentsDir}));
      final parsed = jsonDecode(raw);
      if (parsed is Map && parsed['ok'] == true) {
        final path = parsed['path'];
        if (path is String && path.isNotEmpty) {
          setState(() {
            _pendingImagePaths.add(path);
            _pasteImageNotice = null;
          });
          return true;
        }
        failure = '返回里没有路径';
      } else {
        failure = parsed is Map
            ? (parsed['error']?.toString() ?? '未知原因')
            : '返回不是对象';
      }
    } catch (e) {
      failure = '$e';
    }
    debugPrint('[AliasAgent] 贴图失败：$failure');
    if (mounted) setState(() => _pasteImageNotice = '剪贴板里没有图片（$failure）');
    return false;
  }

  /// 提交输入框里的内容（按 Enter 或点发送都会走这里）。
  ///
  /// 工具清单没装好就不发：那一轮请求会带着残缺的工具清单出去，模型白白空转一轮。
  ///
  /// 判据是「没有文字**且**没有待发图片」才拦（add-image-input）：贴一张图、一个字
  /// 没写也是一条合法消息 —— 用户就是想问"这图是什么"。
  void _submitInput() {
    if (!_toolsReady) return;
    if (_rejectWhileSwitching()) return;
    final text = _inputCtrl.text;
    final hasText = text.trim().isNotEmpty;
    final hasImages = _pendingImagePaths.isNotEmpty;
    if (!hasText && !hasImages) return;
    final images = List<String>.from(_pendingImagePaths);
    _pendingImagePaths.clear();
    _sendMessage(text, attachments: images);
    _inputCtrl.clear();
  }

  /// 切换（或删除）中拒绝发送，并给一句可见提示。返回 true 表示这次发送已被拒绝。
  ///
  /// 按钮禁用只挡住一条路径：回车走 [_submitInput]，测试与其它入口还可能直接调
  /// [_sendMessage]，所以数据层必须再判一次。
  bool _rejectWhileSwitching() {
    final id = _currentId;
    final busy = _switchingTemplate ||
        (id != null &&
            (_sessionController.isSwitching(id) ||
                _sessionController.isDeleting(id)));
    if (!busy) return false;
    if (mounted && _switchBlockedNotice == null) {
      setState(() => _switchBlockedNotice =
          _switchingTemplate || (id != null && _sessionController.isSwitching(id))
              ? '正在切换 Agent 模板：完成后才能发送'
              : '这个会话正在删除：不再接受新的发送');
    }
    return true;
  }

  /// 当前工具清单里的工具名（**只读出口，给测试用**）。
  ///
  /// 为什么要有它：`tasks.md` 6.4 要断言"启动就绪那一刻清单里只有本地那 8 个、还没有
  /// `web_search`"，而 `_toolDefs` 是私有的、窗口用例从外面读不到。加这一个只读方法就
  /// 让那句话变成**能失败的断言**，而不是靠源码顺序去推。它不改变任何行为。
  List<String> currentToolNames() => _toolDefs.keys.toList(growable: false);

  /// 工具清单是否已就绪（只读出口，给测试断言用）。
  bool get toolsReady => _toolsReady;

  /// 当前会话 id（只读出口，给实机测试定位"这一轮的上下文"用）。
  String? get currentSessionId => _currentId;

  /// 把**当前会话上下文**的工作区改到 `path`（只读出口之外唯一给测试用的写入口）。
  ///
  /// 为什么需要它：工作区现在属于上下文，不再有进程级 `set_workspace`；实机测试
  /// 在 pump 之后要把模型的工作区重定向到夹具目录，必须点名当前会话的句柄，
  /// 不能像以前那样改一个全局值。
  Future<String?> setCurrentWorkspace(String path) async {
    final id = _currentId;
    if (id == null) return 'no current session';
    final agent = _agents.lookup(id);
    if (agent != null) {
      await agent.ensureContext();
    } else {
      await _sidecar.ensureContext(id, defaultWorkspace: ConfigService.homeDir);
    }
    return _sidecar.setWorkspace(id, path);
  }

  /// 数据层发送入口（测试用直接调用，绕过按钮与回车）。
  ///
  /// 任务 3.6 要求"切换中按回车、点发送和直接调用发送入口都必须被拒绝"：前两条走
  /// 界面，这一条直接进 `_sendMessage`，用来证明数据层守卫真的存在（只禁用按钮是
  /// 不够的）。
  @visibleForTesting
  Future<void> sendMessageDirectly(String text,
          {List<String> attachments = const []}) =>
      _sendMessage(text, attachments: attachments);

  @override
  void initState() {
    super.initState();
    _sessionRepo = widget.sessionRepo ?? SessionRepository();
    _msgRepo = widget.msgRepo ?? MessageRepository();
    _sidecar = widget.sidecar ?? SidecarBridge.instance;
    _summaryNodeRepo = widget.summaryNodeRepo ?? SummaryNodeRepository();
    // 注入时与测试的 AgentFactory 共用同一注册表；不注入时自己新建一个。
    _agents = widget.agentRegistry ?? AgentRegistry();
    // 2.6: production enables background folding (real summary provider); a
    // hermetic test injects a fake provider and must opt in explicitly.
    _backgroundFoldEnabled =
        widget.backgroundFoldEnabled ?? (widget.summaryProvider == null);
    // 工作区不再在这里设置（change add-context-handles）：它属于**上下文**，
    // 由 AgentFactory 创建实例时调用 `ensureContext(...)`；`created:false` 时
    // 不覆盖已有工作区。模型执行、摘要与写库都归 Agent，界面只订阅事件。
    _subagentRunner = SubagentRunner(
      factory: () => _agentFactory,
      sidecar: _sidecar,
    );
    _agentFactory = AgentFactory(
      templates: registry,
      providerResolver: () => resolver,
      config: widget.config,
      sidecar: _sidecar,
      sessionRepo: _sessionRepo,
      messageRepo: _msgRepo,
      summaryNodeRepo: _summaryNodeRepo,
      registry: _agents,
      summaryProvider: widget.summaryProvider,
      seamSelector: widget.seamSelector,
      guard: widget.guard,
      backgroundFoldEnabled: _backgroundFoldEnabled,
      summaryStoreOpen: () =>
          widget.summaryNodeRepo != null || DatabaseService.isOpen,
      subagentRunner: _subagentRunner,
    );
    _templateController = widget.agentTemplateController ??
        AgentTemplateController(
          registry: registry,
          config: widget.config,
          knownTools: () => ToolCatalog.instance.nameSet,
        );
    _sessionController = widget.agentSessionController ??
        AgentSessionController(factory: _agentFactory, sessionRepo: _sessionRepo);
    _initSearchAndTools();
    _loadSessions();
  }

  @override
  void dispose() {
    // Agent 的销毁会等整轮 Future 与后台压缩写库；界面销毁时不能同步等，
    // 但必须发起（否则上下文与在途请求会留在桥里）。
    unawaited(_agents.disposeAll());
    _inputCtrl.dispose();
    super.dispose();
  }

  /// 当前会话的 Agent 回调：只有"这个事件属于当前会话"时才动展示状态。
  ///
  /// Agent 不读界面当前选中了谁；这份过滤属于界面，所以放在这里。
  AgentCallbacks _callbacksFor(String sessionId) {
    bool isCurrent() => mounted && _currentId == sessionId;
    return AgentCallbacks(
      onUserMessage: (message) {
        if (!isCurrent()) return;
        setState(() => _chatItems.add(ChatMessageItem(message)));
      },
      onAssistantMessage: (message, isFinal) {
        if (!isCurrent() || message.content.isEmpty) return;
        setState(() => _chatItems.add(ChatMessageItem(message, isFinalReply: isFinal)));
      },
      onChunk: (text) {
        if (!isCurrent()) return;
        setState(() {
          final lastIdx = _chatItems.length - 1;
          if (lastIdx >= 0 && _chatItems[lastIdx] is ChatStreamingItem) {
            final current = _chatItems[lastIdx] as ChatStreamingItem;
            _chatItems[lastIdx] = ChatStreamingItem(current.text + text);
          } else {
            _chatItems.add(ChatStreamingItem(text));
          }
        });
      },
      onToolCall: (activity) {
        if (!isCurrent()) return;
        setState(() {
          final streamIdx =
              _chatItems.lastIndexWhere((i) => i is ChatStreamingItem);
          if (streamIdx >= 0) {
            _chatItems.insert(streamIdx, ChatToolCallItem(activity));
          } else {
            _chatItems.add(ChatToolCallItem(activity));
          }
        });
      },
      onThinkingDelta: (index, delta) {
        if (!isCurrent()) return;
        setState(() {
          var target = -1;
          for (var i = _chatItems.length - 1; i >= 0; i--) {
            final item = _chatItems[i];
            if (item is ChatThinkingItem &&
                item.isStreaming &&
                item.index == index) {
              target = i;
              break;
            }
          }
          if (target >= 0) {
            final old = _chatItems[target] as ChatThinkingItem;
            _chatItems[target] = ChatThinkingItem(
              thinking: old.thinking + delta,
              signature: old.signature,
              isStreaming: true,
              index: index,
            );
          } else {
            _chatItems.add(ChatThinkingItem(
              thinking: delta,
              isStreaming: true,
              index: index,
            ));
          }
        });
      },
      onThinkingBlock: (index, thinking, signature) {
        if (!isCurrent()) return;
        setState(() {
          var target = -1;
          for (var i = _chatItems.length - 1; i >= 0; i--) {
            final item = _chatItems[i];
            if (item is ChatThinkingItem &&
                item.isStreaming &&
                item.index == index) {
              target = i;
              break;
            }
          }
          final block = ChatThinkingItem(
            thinking: thinking,
            signature: signature,
            isStreaming: true,
            index: index,
          );
          if (target >= 0) {
            _chatItems[target] = block;
          } else {
            _chatItems.add(block);
          }
        });
      },
      onToolResult: (activity) {
        if (!isCurrent()) return;
        setState(() {
          for (var i = 0; i < _chatItems.length; i++) {
            final item = _chatItems[i];
            if (item is ChatToolCallItem && item.activity.id == activity.id) {
              _chatItems[i] = ChatToolCallItem(activity);
              break;
            }
          }
        });
      },
      onStreamingChanged: (streaming) {
        if (!mounted) return;
        if (!streaming) {
          _finishStreamingUi();
        } else if (isCurrent()) {
          setState(() {});
        }
      },
      onTurnCompleted: () {
        if (!isCurrent()) return;
        // 一次模型请求结束（工具轮后面还会再发）：把这一轮的流式文本与思考卡片
        // 收尾，但整轮仍是"正在发送"。
        setState(_clearStreamingCards);
      },
      onSnapshot: (snapshot) {
        if (!mounted) return;
        setState(() => _contextSnapshot = snapshot);
      },
      onCompactionStatusChanged: () {
        if (!isCurrent()) return;
        setState(() {});
      },
      onTitleChanged: (_) {
        if (!mounted) return;
        setState(() {
          _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        });
      },
    );
  }

  /// 结束流式展示（只动界面；请求取消由 Agent 负责）。
  void _finishStreamingUi() {
    if (!mounted) return;
    setState(_clearStreamingCards);
  }

  /// 清掉流式文本并把思考卡片标成结束；不改 Agent 的"整轮是否在跑"。
  void _clearStreamingCards() {
    _chatItems.removeWhere((i) => i is ChatStreamingItem);
    for (var i = 0; i < _chatItems.length; i++) {
      if (_chatItems[i] is ChatThinkingItem) {
        final old = _chatItems[i] as ChatThinkingItem;
        if (old.isStreaming) {
          _chatItems[i] = ChatThinkingItem(
            thinking: old.thinking,
            signature: old.signature,
            isStreaming: false,
            index: old.index,
          );
        }
      }
    }
  }

  /// 确保某个会话的 Agent 实例存在（创建或恢复）。
  ///
  /// 模板缺失、provider 未定义、窗口非法、工具未知都会给出**可区分**错误：
  /// 记日志并在界面顶部显示，绝不静默改用 `general` 或隐藏错误。
  Future<Agent?> _ensureAgentFor(Session session) async {
    // 条件注册（搜索 / 浏览器工具）完成前不校验工具名：否则一个合法的
    // "模板允许 web_search" 会在启动瞬间被误判成未知工具。
    if (!_toolsReadyCompleter.isCompleted) {
      await _toolsReadyCompleter.future;
    }
    if (!mounted) return null;
    try {
      return await _agentFactory.ensure(session,
          callbacks: _callbacksFor(session.id));
    } on AgentConfigException catch (e) {
      _reportAgentError(e.toString());
      return null;
    } on UnknownToolsException catch (e) {
      _reportAgentError(e.toString());
      return null;
    }
  }

  void _reportAgentError(String message) {
    debugPrint('[AliasAgent] $message');
    if (!mounted) return;
    setState(() => _agentError = message);
  }

  /// 把当前会话切到 [candidateName]。
  ///
  /// 顺序由 `AgentSessionController` 保证：候选预检 → 退役旧 Agent 对象 → 持久化并
  /// 重读 Session → 用 `_callbacksFor(session.id)` 创建新实例。界面这里只做三件事：
  /// ① 切换期间置 [_switchingTemplate]（按钮、回车、数据层三处守卫据此拒绝发送）；
  /// ② 成功后清掉旧实例的占用快照（它属于旧实例，新实例还没发过请求）；
  /// ③ 失败后重新读取数据库，让选择框显示**实际保存**的 `agent_type`，并把失败阶段
  /// 与候选名显示在红条里 —— 不静默退回 `general`、不假装切换成功。
  Future<void> _switchAgentTemplate(String candidateName) async {
    final sessionId = _currentId;
    if (sessionId == null) return;
    if (_switchingTemplate || _sessionController.isSwitching(sessionId)) return;
    final session = _currentSession;
    if (session == null) return;
    if (session.agentType == candidateName) return;
    setState(() {
      _switchingTemplate = true;
      _agentError = null;
      _switchBlockedNotice = null;
    });
    try {
      await _sessionController.switchTemplate(
        session,
        candidateName,
        callbacks: _callbacksFor(sessionId),
      );
      if (!mounted) return;
      setState(() {
        _switchingTemplate = false;
        _switchBlockedNotice = null;
        // 旧实例的 ContextSnapshot 不能当成新实例的状态：清掉，等下一次真实请求。
        _contextSnapshot = null;
      });
      await _rereadSession(sessionId);
    } on AgentSwitchException catch (e) {
      _reportAgentError(e.toString());
      if (mounted) setState(() => _switchingTemplate = false);
      // 失败后回读数据库：选择框必须显示实际保存值（预检失败则是旧值，
      // 创建失败则已经是新值 —— 两种都不能靠界面文字假装）。
      await _rereadSession(sessionId);
    }
  }

  /// 重新读取某个会话在数据库里的最新行，并同步到界面列表。
  Future<void> _rereadSession(String id) async {
    final fresh = await _sessionRepo.get(id);
    if (!mounted) return;
    setState(() {
      final index = _sessions.indexWhere((s) => s.id == id);
      if (fresh == null) {
        if (index >= 0) _sessions.removeAt(index);
      } else if (index >= 0) {
        _sessions[index] = fresh;
      } else {
        _sessions.add(fresh);
      }
    });
  }

  /// 打开 Agent 模板列表（侧栏 Agents 入口）。
  Future<void> _showAgentTemplates() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AgentTemplateMenu(
        templates: registry.list(),
        onAdd: () {
          Navigator.of(dialogContext).pop();
          _openTemplateEditor(null);
        },
        onEdit: (template) {
          Navigator.of(dialogContext).pop();
          _openTemplateEditor(template);
        },
      ),
    );
  }

  /// 打开添加 / 修改编辑器；保存通过 [AgentTemplateController] 写回完整配置并更新
  /// 模板注册表。保存成功后提示**生效时机**：只有之后创建或恢复的实例才用新配置。
  Future<void> _openTemplateEditor(AgentTypeConfig? original) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AgentTemplateEditor(
        original: original,
        providers: _templateController.config.providers.keys.toList(),
        availableTools: ToolCatalog.instance.names,
        onCancel: () => Navigator.of(dialogContext).pop(),
        onSave: (draft) async {
          final result = _templateController.save(draft);
          if (!mounted) return;
          Navigator.of(dialogContext).pop();
          // 注册表已经由 controller 更新；这里只重画并说明生效时机。
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result.created
                ? '已添加模板 "${result.template.name}"：'
                    '之后创建或恢复的实例才使用它；运行中的实例继续使用创建时的配置。'
                : '已保存模板 "${result.template.name}"：'
                    '之后创建或恢复的实例使用新配置；运行中的实例保持不变。'),
          ));
        },
      ),
    );
  }

  /// Initialize search infrastructure and build tool definitions (tasks 8.2, 8.3, 8.6)
  Future<void> _initSearchAndTools() async {
    // Build base tool defs
    final base = <String, Map<String, dynamic>>{
      'read_file': const {
        'name': 'read_file',
        'description': 'Read the contents of a file within the workspace. '
            'Returns the file content with 1-indexed line numbers (cat -n format). '
            'Files over 2000 lines are truncated; use offset/limit to read more.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the file relative to the workspace root.',
            },
            'offset': {
              'type': 'integer',
              'description': 'Start line number (1-indexed). Default: 1.',
            },
            'limit': {
              'type': 'integer',
              'description': 'Number of lines to read. Default: 2000, max: 2000.',
            },
          },
          'required': ['path'],
        },
      },
      'write_file': const {
        'name': 'write_file',
        'description': 'Create or overwrite a file in the workspace. '
            'Use this for creating new files or complete rewrites. '
            'The response indicates whether the file was created or overwritten.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path relative to workspace root.',
            },
            'content': {
              'type': 'string',
              'description': 'Complete file content to write.',
            },
          },
          'required': ['path', 'content'],
        },
      },
      'edit_file': const {
        'name': 'edit_file',
        'description': 'Edit a file by replacing text. Accepts a batch of '
            'replacement pairs in one call. You MUST read the file first to get '
            'the exact old_text. Each old_text must match exactly (whitespace '
            'differences are auto-normalized) and must not be empty. If an '
            'old_text matches multiple locations and its replace_all is false, '
            'the whole request is rejected — add more context to make it unique '
            'or set replace_all:true. All pairs are validated against the '
            'original content first; if any pair fails, no changes are applied. '
            'Overlapping edits are rejected. Up to 100 pairs per call.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path relative to workspace root.',
            },
            'edits': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'old_text': {
                    'type': 'string',
                    'description': 'Exact text to find and replace. Must not be empty.',
                  },
                  'new_text': {
                    'type': 'string',
                    'description': 'Replacement text. May be empty to delete text.',
                  },
                  'replace_all': {
                    'type': 'boolean',
                    'default': false,
                    'description': 'Replace all occurrences instead of just the first.',
                  },
                },
                'required': ['old_text', 'new_text'],
              },
              'description': 'Replacement pairs. At least one required; max 100.',
            },
          },
          'required': ['path', 'edits'],
        },
      },
      'list_dir': const {
        'name': 'list_dir',
        'description': 'List the contents of a directory within the workspace.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the directory relative to the workspace root.',
            },
          },
          'required': ['path'],
        },
      },
      'get_current_time': const {
        'name': 'get_current_time',
        'description': 'Get the current date, time, and timezone. Use this when you need to know the actual current time for time-sensitive queries.',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      },
      'glob_file': const {
        'name': 'glob_file',
        'description': 'Find files within the workspace matching a glob pattern '
            '(gitignore-style: supports *, **, ?, and ! negation). '
            'Returns workspace-relative paths, one per line, limited to '
            'max_results (default 200). Use this when you need to discover '
            'which files exist before reading or searching them.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description': 'Glob pattern relative to the workspace root, e.g. "lib/**/*.dart".',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'default': 200,
              'description': 'Maximum number of paths to return.',
            },
          },
          'required': ['pattern'],
        },
      },
      'grep_file': const {
        'name': 'grep_file',
        'description': 'Search file contents within the workspace using a '
            'regular expression. Returns matches as "path:line: text", with '
            'workspace-relative paths, limited to max_results (default 100). '
            'Supports an optional glob filter and case-insensitive search. '
            'Note: when glob is non-empty it overrides gitignore rules — files '
            'matching the glob are searched even if they would otherwise be ignored.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'pattern': {
              'type': 'string',
              'description': 'Regular expression to search for.',
            },
            'glob': {
              'type': 'string',
              'description': 'Optional glob restricting which files are searched '
                  '(e.g. "sidecar/src/*.cpp"). When set, it overrides gitignore rules.',
            },
            'ignore_case': {
              'type': 'boolean',
              'default': false,
              'description': 'Case-insensitive search.',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'default': 100,
              'description': 'Maximum number of matches to return.',
            },
          },
          'required': ['pattern'],
        },
      },
      // 图片工具（add-image-input）：无条件注册。模型能不能收图由 `input_modalities`
      // 决定 —— 关着的时候调用这个工具会**直接失败并说清原因**（见 `_executeTool`），
      // 比"工具不存在"更容易让模型改口。
      'read_image': const {
        'name': 'read_image',
        'description': 'Read a PNG/JPEG/GIF/WebP image file inside the workspace '
            'and return the image itself so you can look at it. Large images are '
            'downscaled by the provider automatically; do not install image '
            'libraries or create thumbnails to inspect an image. The result also '
            'names the file path, media type, pixel size and byte size.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the image file relative to the workspace root.',
            },
          },
          'required': ['path'],
        },
      },
      // Command tool (add-command-tool): 无条件可用（与 read_file / grep_file 一样，
      // 不挂在搜索服务或浏览器栈的可用性判断下）。命令**真的在本机执行** —— 用
      // 用户自己的权限跑，能改动工作区里的文件，没有沙箱；说明文字里必须写明这一点。
      'run_command': const {
        'name': 'run_command',
        'description': 'Run one PowerShell command on this machine and get its '
            'exit code, stdout and stderr. The command really runs with the '
            "user's own permissions and can modify files under the workspace; "
            'there is no sandbox and it cannot be approved or undone after the '
            'fact. Dialect is PowerShell: use native paths (C:\\...) and read '
            'environment variables with \$env:NAME. Each call is a fresh '
            'process — pass workdir instead of using cd. A non-zero exit code '
            'is NOT a tool failure: it is reported in the result so you can read '
            'it. The full output is always written to a spill file first; when it '
            'is long, you get a head+tail preview (1000 characters each by '
            'default) plus the file path as `ref` — read any byte range back with '
            'the read_spill tool.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'The PowerShell command to run.',
            },
            'workdir': {
              'type': 'string',
              'description': 'Working directory for this command. Defaults to the '
                  'workspace; a relative path is resolved against it. A path '
                  'outside the workspace is refused.',
            },
            'timeout_ms': {
              'type': 'integer',
              'minimum': 1,
              'description': 'Timeout in milliseconds for this command. Defaults '
                  'to 120000 (2 minutes) and is capped at 600000 (10 minutes).',
            },
          },
          'required': ['command'],
        },
      },
      // Spill 读回（spill-large-tool-output）：长输出被截成头尾预览后，模型用这条
      // 按字节把中间段取回来。只认 spill 根目录里的引用（C++ 侧校验），不是通用
      // 文件读取器 —— 读文件请用 read_file。
      'read_spill': const {
        'name': 'read_spill',
        'description': 'Read a byte range back out of a spill file that a previous '
            'tool result pointed at (the `ref` field). Use it when a tool result '
            'says bytes were omitted. Only files under the app spill directory are '
            'readable; anything else is refused. Offsets and limits are BYTES, not '
            'characters — a range that cuts a multi-byte character in half is '
            'refused instead of returning half a character.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'ref': {
              'type': 'string',
              'description': 'The `ref` reported by the tool result (the spill '
                  'file path).',
            },
            'offset': {
              'type': 'integer',
              'minimum': 0,
              'description': 'Byte offset to start at. Defaults to 0.',
            },
            'limit': {
              'type': 'integer',
              'minimum': 1,
              'description': 'How many bytes to return. Defaults to twice the '
                  'configured preview length (2000 bytes by default).',
            },
          },
          'required': ['ref'],
        },
      },
      // 一次性子 Agent（add-spawn-subagent-tool）：同步等待子 Agent 整轮结束，
      // 只把最终结论作为工具结果送回父对话。子 Agent 看不到父对话，第一版也不能
      // 再嵌套创建下一层；这些限制必须写在说明里，模型才知道任务要自带背景。
      'spawn_subagent': const {
        'name': 'spawn_subagent',
        'description': 'Create a one-shot sub-agent with its own context, message '
            'history and metering; give it one complete task and wait for its final '
            'answer. The sub-agent CANNOT see this conversation, so put every '
            'necessary background detail and file path into `task`. It inherits the '
            'current workspace. Only its final answer comes back to you: its '
            'intermediate messages, thinking and tool output stay in its own '
            'history and are never added to this conversation. Ask it for a '
            'self-contained conclusion; do not rely on its read_spill references '
            '(its context is destroyed when it finishes) — anything that must '
            'persist should be written into the workspace. Omit `agent_type` to use '
            "this agent's own template. The call runs synchronously: it waits until "
            'the sub-agent finishes, so it does not run in parallel with other tool '
            'calls. A sub-agent cannot create another sub-agent.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'task': {
              'type': 'string',
              'description': 'The complete, self-contained task for the sub-agent. '
                  'Include the background it needs; it cannot see this conversation.',
            },
            'agent_type': {
              'type': 'string',
              'description': 'Optional Agent template name for the sub-agent. '
                  "Defaults to this agent's own template.",
            },
          },
          'required': ['task'],
        },
      },
    };

    // Assign the base tool set SYNCHRONOUSLY before the browser-availability await
    // so _toolDefs is never uninitialized (a message sent while the probe is still
    // pending reads a valid, if browser-less, tool set).
    ToolCatalog.instance.seed(base);

    // Browser tool (add-browser-tool): declare OUTSIDE the hasProviders gate so a
    // browser-runtime probe decides it, independent of search-provider availability
    // (design Decision 6 / spec "Graceful degradation / declaration gating"). When
    // the browser stack (Playwright + Edge/Chromium) is unavailable, the tools are
    // simply absent — never a silent placeholder. Mutates _toolDefs (== base ref).
    bool browserAvailable = false;
    try {
      final probeJson = await _sidecar.browserAvailable();
      final parsed = jsonDecode(probeJson);
      if (parsed is Map) browserAvailable = parsed['available'] == true;
    } catch (e) {
      debugPrint('[AliasAgent] browser_available probe failed: $e');
    }
    if (browserAvailable) {
      base['browser_navigate'] = const {
        'name': 'browser_navigate',
        'description': 'Navigate a user-visible browser to a URL and return a text '
            'snapshot of the page. Drives a persistent headed browser session; '
            'multi-step (navigate/click/type/snapshot) share one session.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The URL to navigate to.',
            },
          },
          'required': ['url'],
        },
      };
      base['browser_click'] = const {
        'name': 'browser_click',
        'description': 'Click an element in the browser and return a text snapshot '
            'of the page.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description': 'CSS selector of the element to click.',
            },
          },
          'required': ['selector'],
        },
      };
      base['browser_type'] = const {
        'name': 'browser_type',
        'description': 'Enter text into a field in the browser and return a text '
            'snapshot of the page.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'selector': {
              'type': 'string',
              'description': 'CSS selector of the field.',
            },
            'text': {
              'type': 'string',
              'description': 'The text to enter.',
            },
          },
          'required': ['selector', 'text'],
        },
      };
      base['browser_snapshot'] = const {
        'name': 'browser_snapshot',
        'description': 'Return a fresh text snapshot of the current browser page '
            '(re-read live, not a cached copy).',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };
    }

    // Initialize search infra from config (task 8.2)
    try {
      final searchConfig = widget.config.search;
      // 把**会话模型当前 provider 的地址与密钥**一起交下去（add-deepseek-web-search
      // 任务 3.4）。C++ 侧只在"地址确实指向 DeepSeek 且 search.deepseek 段存在"
      // 时才允许回落到它，`search.deepseek` 里自己写了的以自己写的为准；地址不是
      // DeepSeek 时那一侧直接报告不可用、不发任何请求（安全边界，见 design 决策 D2）。
      // 字段名：`session_model.{base_url,api_key}`。
      final mergedSearch = <String, dynamic>{
        if (searchConfig != null) ...searchConfig,
      };
      final activeAgent = registry.lookup('general');
      final sessionProvider =
          activeAgent == null ? null : resolver?.resolve(activeAgent.provider);
      if (sessionProvider != null) {
        mergedSearch['session_model'] = <String, dynamic>{
          'base_url': sessionProvider.baseUrl.isNotEmpty
              ? sessionProvider.baseUrl
              : 'https://api.anthropic.com',
          'api_key': sessionProvider.apiKey,
        };
      }
      final searchJson = mergedSearch.isEmpty ? '{}' : jsonEncode(mergedSearch);
      _sidecar.ensureSearchInfra(searchJson);
    } catch (e) {
      debugPrint('[AliasAgent] Search infra init failed: $e');
    }

    // Query configured providers (task 8.6)
    List<dynamic> providers = [];
    try {
      final providersJson = _sidecar.getSearchProviders();
      final parsed = jsonDecode(providersJson);
      if (parsed is List) providers = parsed;
    } catch (e) {
      debugPrint('[AliasAgent] get_search_providers failed: $e');
    }

    final hasProviders = providers.isNotEmpty;

    // Conditionally add web_search (task 8.3, 8.6)
    if (hasProviders) {
      final providerNames = providers.map((p) => (p as Map<String, dynamic>)['name'] as String).toList();
      final providerList = providerNames.join(', ');
      final descriptions = StringBuffer('Search the web using available providers.\n\nAvailable: ');
      for (final p in providers) {
        final name = (p as Map<String, dynamic>)['name'] as String;
        final desc = p['description'] as String? ?? '';
        descriptions.write('\n- $name: $desc');
      }

      base['web_search'] = {
        'name': 'web_search',
        'description': descriptions.toString(),
        'input_schema': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query.',
            },
            'providers': {
              'type': 'array',
              'items': {'type': 'string', 'enum': providerNames},
              'default': <String>[],
              'description': 'Which search providers to use. Empty = use all configured providers ($providerList).',
            },
            'depth': {
              'type': 'string',
              'enum': ['basic', 'deep'],
              'default': 'basic',
              'description': 'basic = snippets only (fast). deep = full page extraction (higher latency).',
            },
            'max_results': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 10,
              'default': 5,
            },
          },
          'required': ['query'],
        },
      };

      // Task 8.4: Add web_fetch tool definition
      base['web_fetch'] = const {
        'name': 'web_fetch',
        'description': 'Fetch a web page and return clean, structured content. '
            'Use this to get full article text when search snippets are insufficient.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The URL of the web page to fetch.',
            },
          },
          'required': ['url'],
        },
      };
    }

    ToolCatalog.instance.seed(base);
    // 到这里动态那批（web_search / web_fetch / 浏览器四件套）也定了 —— 发送入口可以放行。
    // 在此之前 `_toolDefs` 只有本地那 8 个（`base` 在 await 之前就装好了），那一轮请求
    // 会缺搜索工具，所以 `ChatArea` 用 `toolsReady` 挡住发送（fix-silent-truncation 6.1）。
    if (mounted && !_toolsReady) {
      setState(() => _toolsReady = true);
    } else {
      _toolsReady = true;
    }
    if (!_toolsReadyCompleter.isCompleted) _toolsReadyCompleter.complete();
  }


  Future<void> _loadSessions() async {
    final sessions = await _sessionRepo.list();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loading = false;
      if (sessions.isNotEmpty && _currentId == null) {
        _currentId = sessions.first.id;
        _loadMessages();
      }
    });
    // 启动恢复：每个会话都按它自己的 agentType 建 / 复用 Agent 实例。工厂内部
    // ensureContext（created:false 时不会覆盖已有工作区），工具调用不会因为
    // "本进程还没建过这个上下文"报 unknown_context。
    for (final s in sessions) {
      await _ensureAgentFor(s);
    }
  }

  Future<void> _loadMessages() async {
    if (_currentId == null) {
      setState(() => _chatItems = []);
      return;
    }
    try {
      final msgs = await _msgRepo.queryBySession(_currentId!);
      if (!mounted) return;
      setState(() => _chatItems = _buildChatItems(msgs));
    } catch (e) {
      debugPrint('[AliasAgent] _loadMessages error: $e');
      if (!mounted) return;
      setState(() => _chatItems = []);
    }
  }

  /// Build ChatItem list from persisted messages, interleaving tool call cards
  /// before each assistant message that has toolCallsJson.
  List<ChatItem> _buildChatItems(List<Message> messages) {
    final items = <ChatItem>[];
    for (final msg in messages) {
      // Reconstruct thinking blocks (before tool calls, matching API content order)
      if (msg.thinkingJson != null && msg.thinkingJson!.isNotEmpty) {
        try {
          final thinkingBlocks =
              jsonDecode(msg.thinkingJson!) as List<dynamic>;
          // index is derived from array position (0..N-1) — NOT persisted (D6);
          // this also makes history written by add-extended-thinking (blocks
          // without an index field) rebuild correctly with derived indexes.
          for (var i = 0; i < thinkingBlocks.length; i++) {
            final th = thinkingBlocks[i] as Map<String, dynamic>;
            items.add(ChatThinkingItem(
              thinking: (th['thinking'] as String?) ?? '',
              signature: th['signature'] as String?,
              isStreaming: false,
              index: i,
            ));
          }
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse thinkingJson: $e');
        }
      }
      if (msg.toolCallsJson != null && msg.toolCallsJson!.isNotEmpty) {
        try {
          final list = jsonDecode(msg.toolCallsJson!) as List<dynamic>;
          for (final tcJson in list) {
            final activity = ToolCallActivity.fromJson(
                tcJson as Map<String, dynamic>);
            items.add(ChatToolCallItem(activity));
          }
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse toolCallsJson: $e');
        }
      }
      // Always keep the message item — even a content-empty tool call assistant
      // (D7). Its tool_use input (often an absolute path = a re-execution key) must
      // reach BOTH the fold input (the summarizer, model_summary_provider
      // _toolRoundText) AND _buildApiMessages (the model sees the tool round). The
      // empty Content bubble itself is NOT rendered (chat_area hides empty-content
      // messages; the ToolCallCard above represents the response, D7).
      items.add(ChatMessageItem(msg));
    }
    return items;
  }

  void _selectSession(Session s) {
    // 切走：取消旧实例的在途请求与后台压缩（Agent 自己的 cancel），展示状态立刻收尾。
    // 旧实例的写库归属仍是它自己的会话，不读新的 _currentId。
    _currentAgent?.cancel();
    _finishStreamingUi();
    setState(() {
      _currentId = s.id;
      _chatItems = [];
    });
    _loadMessages();
    // 切换到一个本进程还没建过实例的会话时按它的 agentType 建好。
    _ensureAgentFor(s);
  }

  Future<void> _newChat() async {
    _currentAgent?.cancel();
    _finishStreamingUi();
    final s = await _sessionRepo.create();
    if (!mounted) return;
    // 新建会话：AgentFactory 创建实例并确保上下文（created:true ⇒ 缺省工作区在这里设）。
    await _ensureAgentFor(s);
    setState(() {
      _currentId = s.id;
      _chatItems = [];
    });
    _loadSessions();
  }

  Future<void> _deleteSession(Session s) async {
    final wasCurrent = _currentId == s.id;
    // ① 与切换互斥：登记删除（此后该会话的切换被拒），等待已在进行的切换结束，
    //    然后**重新读取**数据库里的 Session —— 切换可能刚把 agent_type 改掉。
    Session? fresh;
    try {
      fresh = await _sessionController.beginDelete(s.id);
    } catch (e) {
      debugPrint('[AliasAgent] 删除会话 ${s.id} 前等待切换结束失败，已放弃删除：$e');
      _sessionController.endDelete(s.id);
      return;
    }
    try {
      if (fresh == null) {
        debugPrint('[AliasAgent] 删除会话 ${s.id}：数据库中这一行已经不存在，'
            '继续清理内存状态与运行实例');
      }
      // ② 销毁实例：cancel 停止在途请求，dispose 先等整轮 Future（模型循环、工具、
      //    insert / touch / updateToolCalls 与后台压缩写库），再 disposeContext
      //    排空桥内队列与 C++ 在途调用。切换可能刚换过实例，所以按 id 重新查一次。
      _agents.lookup(s.id)?.cancel();
      try {
        await _agents.disposeAndRemove(s.id);
      } catch (e) {
        // 底层没能证明排空（例如毒化上下文）：资源仍被保留，**不许假装删成功**。
        debugPrint('[AliasAgent] 删除会话 ${s.id} 的上下文失败，已放弃删除：$e');
        return;
      }
      // ③ 最后才删数据库与更新列表：数据库删除晚于所有写入。
      await _sessionRepo.delete(s.id);
    } finally {
      _sessionController.endDelete(s.id);
    }
    if (!mounted) return;
    if (wasCurrent) _finishStreamingUi();
    setState(() {
      _sessions.removeWhere((x) => x.id == s.id);
      if (wasCurrent) {
        _currentId = _sessions.isNotEmpty ? _sessions.first.id : null;
        _chatItems = [];
        if (_currentId != null) _loadMessages();
      }
    });
    if (wasCurrent && _currentId != null) {
      // 新的当前会话也要有实例（它的下一次发送不能没有上下文）。
      final next = _sessions.firstWhere((x) => x.id == _currentId);
      _ensureAgentFor(next);
    }
  }

  Future<void> _sendMessage(String text, {List<String> attachments = const []}) async {
    if (_isStreaming) return;
    if (_rejectWhileSwitching()) return;
    if (_currentId == null) {
      // Auto-create a session if none exists
      await _newChat();
    }
    final sessionId = _currentId;
    if (sessionId == null) return;
    // 切换可能在 `_newChat()` 的 await 期间开始：数据层这里必须再判一次。
    // 删除期间写入会落到已删的行上，同样拒绝。
    if (_rejectWhileSwitching()) return;
    if (_switchBlockedNotice != null && mounted) {
      setState(() => _switchBlockedNotice = null);
    }
    var agent = _agents.lookup(sessionId);
    if (agent == null) {
      final session = await _sessionRepo.get(sessionId);
      if (session == null) return;
      agent = await _ensureAgentFor(session);
    }
    if (agent == null) return; // 创建失败已在界面显示可区分错误
    // 整轮（模型循环、工具、摘要、写库、后台压缩写库）由 Agent 持有与登记；
    // 删除会话时由 Agent.dispose 等它结束。
    await agent.send(text, attachments: attachments);
  }

  /// Body size threshold above which a verbatim tool_result is treated as
  /// "extremely large" and elided (near-zone). 定义在
  /// `lib/services/tool_result_text.dart`，这里只转发给既有调用点与测试。
  static const int kToolResultElisionThreshold =
      tool_text.kToolResultElisionThreshold;

  /// `run_command` 的模型可见正文（实现见 `lib/services/tool_result_text.dart`）。
  static String composeCommandResultText(Map<String, dynamic> parsed) =>
      tool_text.composeCommandResultText(parsed);

  /// spill 引用行在模型可见正文里的固定标记。
  static const String kSpillRefsMarker = tool_text.kSpillRefsMarker;

  /// 这段正文里有没有 spill 引用。
  static bool bodyHasSpillRefs(String body) =>
      tool_text.bodyHasSpillRefs(body);

  /// Elide an oversized tool_result BODY (near-zone elision).
  static String elideOversizedToolResult({
    required String name,
    required String path,
    required String body,
  }) =>
      tool_text.elideOversizedToolResult(name: name, path: path, body: body);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Row(
      children: [
        SessionSidebar(
          sessions: _sessions,
          currentId: _currentId,
          onNewChat: _newChat,
          onSelect: _selectSession,
          onDelete: _deleteSession,
          onAgents: _showAgentTemplates,
        ),
        const VerticalDivider(width: 1),
        Expanded(
          // (3.2) Wrap the view area in a Column: a small toolbar at top toggles
          // between the original conversation view and the real context view
          // (task 3.2 / design D6). The default remains the conversation view.
          child: Column(
            children: [
              // 旧默认工具清单升级提示（任务 1.3）：必须可见，不能只写日志。
              if (widget.toolMigrationNotice != null)
                Container(
                  key: const ValueKey('tool-migration-notice'),
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    widget.toolMigrationNotice!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              // Agent 创建 / 恢复失败的可区分错误（模板缺失、provider 未定义、
              // 窗口非法、未知工具）：显示出来，不静默改用 general 或隐藏。
              if (_agentError != null)
                Container(
                  key: const ValueKey('agent-error-notice'),
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.errorContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    _agentError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    SegmentedButton<ContextViewMode>(
                      segments: const [
                        ButtonSegment(
                          value: ContextViewMode.conversation,
                          label: Text('对话视图'),
                        ),
                        ButtonSegment(
                          value: ContextViewMode.context,
                          label: Text('真实上下文'),
                        ),
                      ],
                      selected: {_viewMode},
                      onSelectionChanged: (selection) {
                        setState(() => _viewMode = selection.first);
                      },
                      showSelectedIcon: false,
                    ),
                    const Spacer(),
                    // 当前会话的 Agent 模板选择（任务 3.6）：显示当前
                    // `Session.agentType`，切换走 `_switchAgentTemplate`。
                    // 工具未就绪 / 没有当前会话 / 切换或删除中时只禁用这个控件；
                    // 发送不因此被切断（没有会话时仍会自动创建 general）。
                    SessionAgentSwitcher(
                      templateNames: registry.listNames(),
                      current: _currentSession?.agentType,
                      enabled: _toolsReady &&
                          _currentId != null &&
                          !_switchingTemplate &&
                          !_sessionController.isDeleting(_currentId!) &&
                          !_sessionController.isSwitching(_currentId!),
                      onChanged: _switchAgentTemplate,
                    ),
                    // 10.4：占用环从这一行搬走了 —— 现在贴在输入行的发送按钮左侧
                    // （见下面 InputBar 的 accessory）。搬走的原因：右上角被红色 DEBUG
                    // 斜标压住，而且那个位置本身也别扭（用户 2026-10-18 裁定挪到发送按钮附近）。
                  ],
                ),
              ),
              Expanded(
                child: _viewMode == ContextViewMode.conversation
                    ? ChatArea(
                        items: _chatItems,
                        isStreaming: _isStreaming,
                        compactionStatus: compactionStatus,
                        // 气泡据此决定要不要加"本次没有发送图片"那句（11.1）
                        imagesSent: _currentAgent?.acceptsImages ?? false,
                      )
                    : ContextView(
                        snapshot: _contextSnapshot,
                        compactionStatus: compactionStatus,
                      ),
              ),
              // 10.1：输入行在两屏之外（`Expanded` 之后、同一个 Column 里），所以切到
              // 「真实上下文」那一屏时输入框与发送按钮仍在 —— 占用环跟着它一起留下。
              // 贴图失败的提示：贴在输入行正上方（用户刚点的就是那个按钮），
              // 下一次贴图成功或下一次发送时消失。
              if (_pasteImageNotice != null)
                Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.errorContainer,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    _pasteImageNotice!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              // 切换中尝试发送的可见提示（按钮、回车、数据层三处都会被拒，但要让
              // 用户看见"为什么没发出去"，不是静默失败）。
              if (_switchBlockedNotice != null)
                Container(
                  key: const ValueKey('switch-blocked-notice'),
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    _switchBlockedNotice!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              InputBar(
                controller: _inputCtrl,
                onSubmit: _submitInput,
                toolsReady: _toolsReady,
                // 切换 / 删除中：按钮与回车都服从它（数据层在 _submitInput 与
                // _sendMessage 里另有守卫）。
                switching: _switchingTemplate ||
                    (_currentId != null &&
                        (_sessionController.isSwitching(_currentId!) ||
                            _sessionController.isDeleting(_currentId!))),
                // 贴进来还没发出去的图：只参与"没文字时还能不能提交"这一条判断。
                pendingImagePaths: _pendingImagePaths,
                onPasteImage: () {
                  _pasteImageFromClipboard();
                },
                // Ctrl+V：先试贴图，没贴到由输入行退回文本粘贴。
                onPasteShortcut: _pasteImageFromClipboard,
                onRemoveImage: (index) {
                  setState(() => _pendingImagePaths.removeAt(index));
                },
                // 10.4：占用环贴在发送按钮左侧、与它同一行。
                accessory: ContextRingLabeled(
                  breakdown: _contextSnapshot?.breakdown,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
