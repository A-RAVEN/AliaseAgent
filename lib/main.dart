import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/agent_type_config.dart';
import 'models/app_config.dart';
import 'models/chat_item.dart';
import 'models/compaction_status.dart';
import 'models/context_breakdown.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'models/tool_call_activity.dart';
import 'services/agent_type_registry.dart';
import 'services/compaction/compaction_plan.dart';
import 'services/compaction/guard_anchors.dart';
import 'services/compaction/model_summary_provider.dart';
import 'services/compaction/seam_selector.dart';
import 'services/compaction/summary_provider.dart';
import 'services/compaction/summary_reference.dart';
import 'services/config_service.dart';
import 'services/context_estimator.dart';
import 'services/context_snapshot.dart';
import 'services/database_service.dart';
import 'services/message_repository.dart';
import 'services/provider_resolver.dart';
import 'services/search_text_assembly.dart';
import 'services/session_repository.dart';
import 'services/sidecar_bridge.dart';
import 'services/summary_node_repository.dart';
import 'ui/chat_area.dart';
import 'ui/context_ring.dart';
import 'ui/input_bar.dart';
import 'ui/context_view.dart';
import 'ui/session_sidebar.dart';
import 'ui/setup_dialog.dart';

final registry = AgentTypeRegistry();
ProviderResolver? resolver;

/// Thrown by [_resolveSummaries] when a background fold is aborted (preempted by
/// a user send). Distinct from a real summarization failure: the inline send path
/// never passes `isAborted`, so it never raises this; the background fold catches
/// it as "resume next idle". Its `message` must not be confused with a model error.
class _BackgroundFoldCancelled implements Exception {
  final String reason;
  const _BackgroundFoldCancelled(this.reason);
  @override
  String toString() => reason;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
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

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _loadConfig() {
    final result = widget.configLoader != null ? widget.configLoader!() : ConfigService.load();
    switch (result.status) {
      case ConfigStatus.ok:
        setState(() {
          _config = result.config;
          _populateRegistry(result.config!);
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
      builder: (_) => SetupDialog(onComplete: () {
        Navigator.of(context).pop();
        _loadConfig();
      }),
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
      body: ChatScreen(config: _config!),
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
  });

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  late final SessionRepository _sessionRepo;
  late final MessageRepository _msgRepo;
  late final ISidecar _sidecar;
  late final SummaryProvider _summaryProvider;
  late final SeamSelector? _seamSelector;
  late final GuardAnchors _guard;
  late final SummaryNodeRepository _summaryNodeRepo;
  /// 2.6 background folding: enabled iff no summary provider is injected
  /// (production), unless the test overrides [ChatScreen.backgroundFoldEnabled].
  late final bool _backgroundFoldEnabled;

  // 2.6 idle-gated background folding state. A fold runs only when the model slot
  // is free (not streaming), the user is idle (debounce window elapsed), and no
  // fold is already in flight. `_foldGen` is a generation token: a user send
  // increments it to invalidate a running fold, whose in-flight summarize then
  // throws (ModelSummaryProvider throws on done != 0) and aborts — so the fold is
  // preempted and does not delay the user's request (BEST-EFFORT, see design D8
  // known-limit: the single-slot global cancel leaves a bounded race where an
  // already-enqueued fold call can run ahead of the user). The durable resume
  // point is the persisted summary_nodes (progressive closure folds only the
  // not-yet-closed tail next idle); the top closed seq is logged, not stored as a
  // control value.
  bool _foldInFlight = false;
  int _foldGen = 0;
  Timer? _foldIdleTimer;

  List<Session> _sessions = [];
  String? _currentId;
  List<ChatItem> _chatItems = [];

  /// The most recent deep-copied context snapshot actually sent to the gateway
  /// on a main-conversation request. `null` means nothing has been captured
  /// since the app started. Retained (never silently cleared) across session
  /// switches and labeled with its `sessionId` — see task 1.4 / design D6.
  ContextSnapshot? _contextSnapshot;

  /// Read-only view of the captured snapshot for the UI and tests. Returns null
  /// only before the first send has captured anything.
  ContextSnapshot? get contextSnapshot => _contextSnapshot;

  /// 压缩进行中的状态（空闲时是 [CompactionStatus.idle]）。
  ///
  /// 它**只**说明"压缩这一件事正在做"：置位与清除都发生在真正要发起压缩相关模型
  /// 请求的地方 —— 挑选分段主题（[_prepareSeamChooser]，冷缓存时它自己要发一次
  /// 请求）与生成 / 合成摘要（[_resolveSummaries]）。刻意不从"正在发送"
  /// （`_isStreaming`）推断：没触发压缩的普通发送它也是开的，那样提示就是假的。
  CompactionStatus _compactionStatus = CompactionStatus.idle;

  /// 压缩进行中的状态，供两个视图与测试读取。
  CompactionStatus get compactionStatus => _compactionStatus;

  /// 这个状态现在**归谁**：每次置位的人拿一个自己的标记，清除时只清自己那一份。
  /// 没有这一层时，两条并发的压缩（后台那趟被抢占后收尾 + 你自己的发送前压缩）
  /// 会互相把对方正在显示的提示清掉 —— 谁先结束谁清。
  Object? _compactionOwner;

  /// 改压缩状态并重画。[owner] 非空时同时把归属改成它。
  /// [sessionId] 非空时只有它**就是当前会话**才显示：切走之后，旧会话那趟压缩还会继续
  /// 跑一阵，它后续的置位不许把提示画到新会话的界面上。
  /// 压缩期间界面可能已经被销毁（切换会话、关窗口），所以带 `mounted` 判断。
  void _setCompactionStatus(CompactionStatus status,
      {Object? owner, String? sessionId}) {
    if (!mounted) return;
    if (sessionId != null && sessionId != _currentId) return;
    if (owner != null) _compactionOwner = owner;
    setState(() => _compactionStatus = status);
  }

  /// 把状态清成空闲，但**只在它还是 [owner] 置的那一份时才清**：别人正在显示的
  /// 提示不许被我清掉（`owner == null` 表示无条件清，只有"整条链收尾"用它）。
  void _clearCompactionStatus({Object? owner}) {
    if (!mounted) return;
    if (owner != null &&
        _compactionOwner != null &&
        !identical(_compactionOwner, owner)) {
      return;
    }
    _compactionOwner = null;
    setState(() => _compactionStatus = CompactionStatus.idle);
  }

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

  // Streaming state
  bool _isStreaming = false;

  bool _loading = true;

  // Dynamic tool definitions (task 8.3 — was static const, now late final)
  // Tool definitions sent to the model. Mutable (not late): _initSearchAndTools
  // assigns the base set synchronously BEFORE the browser-availability await, so
  // a sendMessage that reads it while the probe is still pending never hits a
  // LateInitializationError (browser/prober gates resolve later and mutate it).
  Map<String, Map<String, dynamic>> _toolDefs = {};

  /// 工具清单是否已经装好（含动态那批）。`_initSearchAndTools()` 完成时置真；
  /// 在此之前 `ChatArea` 会挡住发送 —— 否则那一轮请求里的工具清单是残缺的（缺
  /// `web_search` / `web_fetch` / 浏览器四件套），模型会白白空转一轮（真机实测过）。
  bool _toolsReady = false;

  /// 输入框的文本控制器。**2026-10-18 从 `ChatArea` 搬到这里** —— 输入行现在由这个
  /// 文件构造、两屏共用（见 `lib/ui/input_bar.dart` 的 `InputBar`）。
  final _inputCtrl = TextEditingController();

  /// 提交输入框里的内容（按 Enter 或点发送都会走这里）。
  ///
  /// 工具清单没装好就不发：那一轮请求会带着残缺的工具清单出去，模型白白空转一轮。
  void _submitInput() {
    if (!_toolsReady) return;
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    _sendMessage(text);
    _inputCtrl.clear();
  }

  /// 当前工具清单里的工具名（**只读出口，给测试用**）。
  ///
  /// 为什么要有它：`tasks.md` 6.4 要断言"启动就绪那一刻清单里只有本地那 8 个、还没有
  /// `web_search`"，而 `_toolDefs` 是私有的、窗口用例从外面读不到。加这一个只读方法就
  /// 让那句话变成**能失败的断言**，而不是靠源码顺序去推。它不改变任何行为。
  List<String> currentToolNames() => _toolDefs.keys.toList(growable: false);

  /// 工具清单是否已就绪（只读出口，给测试断言用）。
  bool get toolsReady => _toolsReady;

  @override
  void initState() {
    super.initState();
    _sessionRepo = widget.sessionRepo ?? SessionRepository();
    _msgRepo = widget.msgRepo ?? MessageRepository();
    _sidecar = widget.sidecar ?? SidecarBridge.instance;
    // Skip sidecar init when in test mode (DI detected)
    if (widget.sidecar == null && widget.sessionRepo == null) {
      _sidecar.setWorkspace(ConfigService.homeDir);
    }
    // Seed the guard producer from the ACTIVE agent type's explicit standing
    // requirements (R2-3). Previously _guard was created empty and never seeded,
    // so inject() returned '' on every turn — the non-compressible anchor never
    // fired. Registry is populated (via _populateRegistry) before this initState.
    _guard = widget.guard ?? _seedGuardFromConfig();
    _summaryProvider = widget.summaryProvider ??
        (resolver != null
            ? ModelSummaryProvider(sidecar: _sidecar, resolver: resolver!)
            : FakeSummaryProvider());
    // Seam selector (4.3, design D5 option A): AI picks the L1 topic seam. Wired
    // only on the production path (no injected summaryProvider == a real model
    // gateway). Hermetic tests inject a FakeSeamSelector or leave it null (the
    // arithmetic-safe skeleton then applies, so no extra LLM call is consumed
    // from a FakeSidecar event queue).
    _seamSelector = widget.seamSelector ??
        (widget.summaryProvider == null && resolver != null
            ? ModelSeamSelector(sidecar: _sidecar, resolver: resolver!)
            : null);
    _summaryNodeRepo = widget.summaryNodeRepo ?? SummaryNodeRepository();
    // 2.6: production enables background folding (real summary provider); a
    // hermetic test injects a fake provider and must opt in explicitly.
    _backgroundFoldEnabled =
        widget.backgroundFoldEnabled ?? (widget.summaryProvider == null);
    _initSearchAndTools();
    _loadSessions();
  }

  @override
  void dispose() {
    // 2.6: cancel any pending idle-fold debounce timer before teardown, so a
    // foreground fold scheduled in the 2s window is not left pending (which would
    // trip widget-test "Timer still pending" and, on real dispose, hold the State).
    _foldIdleTimer?.cancel();
    _foldIdleTimer = null;
    _inputCtrl.dispose();
    super.dispose();
  }

  /// Build a GuardAnchors seeded from the active agent type's standing
  /// requirements. Shared mutable global `registry` is read at init time; the
  /// anchor set stays as caller/config produces it (deterministic, not LLM).
  GuardAnchors _seedGuardFromConfig() {
    final g = GuardAnchors();
    final agent = registry.lookup('general');
    if (agent != null && agent.standingRequirements.isNotEmpty) {
      g.setStandingRequirements(agent.standingRequirements);
    }
    return g;
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
            'it. Long output is truncated to its tail and the full output is '
            'written to a temp file whose path is reported.',
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
    };

    // Assign the base tool set SYNCHRONOUSLY before the browser-availability await
    // so _toolDefs is never uninitialized (a message sent while the probe is still
    // pending reads a valid, if browser-less, tool set).
    _toolDefs = base;

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

    _toolDefs = base;
    // 到这里动态那批（web_search / web_fetch / 浏览器四件套）也定了 —— 发送入口可以放行。
    // 在此之前 `_toolDefs` 只有本地那 8 个（`base` 在 await 之前就装好了），那一轮请求
    // 会缺搜索工具，所以 `ChatArea` 用 `toolsReady` 挡住发送（fix-silent-truncation 6.1）。
    if (mounted && !_toolsReady) {
      setState(() => _toolsReady = true);
    } else {
      _toolsReady = true;
    }
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

  /// Extract Message objects from ChatItem list for API conversation building.
  List<Message> _chatItemsToMessages() {
    return _chatItems
        .whereType<ChatMessageItem>()
        .map((item) => item.message)
        .toList();
  }

  /// Request generation counter (15.1): every _sendMessage increments it and
  /// passes the value into _callModel; a session switch records the current
  /// generation in _switchEpoch. A call whose epoch <= _switchEpoch was
  /// invalidated by a switch — its remaining tool loop is aborted (whether or
  /// not the user switches back) and its done is treated as a switch-cancel.
  /// This replaces the earlier _cancelSwitchSessionId flag, whose
  /// single-slot semantics could not distinguish "my request was switched
  /// away" from "a newer request was switched away".
  int _requestEpoch = 0;
  int _switchEpoch = -1;

  void _selectSession(Session s) {
    // 2.6: navigating away invalidates any running/scheduled background fold for
    // the previous session. Bump gen to abort a RUNNING fold (its isAborted closure
    // sees a stale myGen); cancel a PENDING idle timer so a SCHEDULED fold is not
    // started for the session the user just left (a scheduled fold captures myGen
    // AFTER any bump, so gen alone would not stop it).
    _foldGen++;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = null;
    if (_isStreaming) _switchEpoch = _requestEpoch;
    _endStreaming();
    setState(() {
      _currentId = s.id;
      _chatItems = [];
      // 压缩状态属于**一个会话**：切走之后旧会话的压缩提示不许挂在新会话界面上。
      // （被抢占的那趟压缩还会回来清它自己那一份，但它已经不是当前归属，会被忽略；
      // 它后续的置位也会被 `_setCompactionStatus` 的会话校验挡掉。）
      _compactionStatus = CompactionStatus.idle;
      _compactionOwner = null;
    });
    _loadMessages();
  }

  Future<void> _newChat() async {
    // 2.6: a new chat invalidates any running/scheduled background fold (bump gen
    // for a running fold; cancel the pending timer for a scheduled one) BEFORE the
    // await — the 2s idle timer could otherwise fire during the create gap and start
    // a fold for the session being left.
    _foldGen++;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = null;
    final s = await _sessionRepo.create();
    if (!mounted) return;
    if (_isStreaming) _switchEpoch = _requestEpoch;
    _endStreaming();
    setState(() {
      _currentId = s.id;
      _chatItems = [];
    });
    _loadSessions();
  }

  Future<void> _deleteSession(Session s) async {
    final wasCurrent = _currentId == s.id;
    if (wasCurrent) {
      // 2.6: deleting the current session invalidates any running/scheduled fold
      // BEFORE the await — the idle timer could otherwise fire during the delete
      // gap and start a fold for the session being abandoned.
      _foldGen++;
      _foldIdleTimer?.cancel();
      _foldIdleTimer = null;
    }
    await _sessionRepo.delete(s.id);
    if (!mounted) return;
    if (wasCurrent) {
      if (_isStreaming) _switchEpoch = _requestEpoch;
      _endStreaming();
    }
    setState(() {
      _sessions.removeWhere((x) => x.id == s.id);
      if (wasCurrent) {
        _currentId = _sessions.isNotEmpty ? _sessions.first.id : null;
        _chatItems = [];
        if (_currentId != null) _loadMessages();
      }
    });
  }

  Future<void> _sendMessage(String text) async {
    if (_isStreaming) return;
    // 2.6 —— preempt ANY scheduled or in-flight background fold before issuing the
    // user's request. A PENDING idle timer means a fold is SCHEDULED (not yet
    // started, `_foldInFlight` still false); an in-flight fold is RUNNING. Both
    // must be suppressed here, otherwise the timer can fire inside this send's
    // setup gap (before `_isStreaming` is set) and start a fold that is never
    // preempted, enqueueing a model call ahead of the user's request (D8 user
    // priority / "never delay"). Bump the generation (invalidate the isAborted
    // closure), cancel the slot if a fold is mid-model-call, and clear the timer.
    if (_foldInFlight || _foldIdleTimer != null) {
      _foldGen++;
      _sidecar.cancelRequest();
      _foldIdleTimer?.cancel();
      _foldIdleTimer = null;
    }
    if (_currentId == null) {
      // Auto-create a session if none exists
      await _newChat();
    }
    if (_currentId == null) return;

    // 17.5 (FINAL-R10-01): capture session + epoch BEFORE any async gap —
    // a session switch during the inserts below must not redirect this
    // message to the new session (user message persisted into the wrong
    // session) or lose the epoch association. A switch after this point
    // invalidates the call via _switchEpoch and the loop-top abort check.
    final sessionId = _currentId!;
    final epoch = ++_requestEpoch;

    // Insert user message
    final userMsg = await _msgRepo.insert(
      sessionId: sessionId,
      role: 'user',
      content: text,
    );
    await _sessionRepo.touch(sessionId);

    setState(() {
      _chatItems.add(ChatMessageItem(userMsg));
      _isStreaming = true;
    });

    // Auto-title: update "New Chat" from first user message
    final titleUpdated = await _sessionRepo.updateTitleIfDefault(sessionId, text);
    if (titleUpdated && mounted) {
      setState(() {
        _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      });
    }

    // Snapshot conversation state before the model call
    final snapMessages = _chatItemsToMessages();
    try {
      await _callModel(sessionId: sessionId, messages: snapMessages, epoch: epoch);
    } catch (e, st) {
      // 13.6: an unexpected exception inside _callModel (e.g. DB insert
      // failing) must not leave _isStreaming stuck true — that would block
      // all future sends with no error surfaced.
      debugPrint('[AliasAgent] _callModel error: $e\n$st');
      // 16.4 (E4): only restore streaming state if THIS call was not
      // invalidated by a switch — a stale call's exception must not cancel
      // the newer in-flight request (whose done(-1,'cancelled') would then be
      // misclassified as a switch-cancel and silently dropped).
      if (_switchEpoch < epoch && mounted) _endStreaming();
    }
  }

  // -------------------------------------------------------------------------
  // Model calling with tool execution loop
  // -------------------------------------------------------------------------

  Future<void> _callModel(
      {required String sessionId,
      required List<Message> messages,
      required int epoch}) async {
    final agentType = registry.lookup('general');
    if (agentType == null) {
      setState(() => _isStreaming = false);
      await _storeError('No agent type configured.', sessionId: sessionId);
      return;
    }

    final provider = resolver?.resolve(agentType.provider);
    if (provider == null) {
      setState(() => _isStreaming = false);
      await _storeError('Provider "${agentType.provider}" not found.', sessionId: sessionId);
      return;
    }

    final baseUrl = provider.baseUrl.isNotEmpty
        ? provider.baseUrl
        : 'https://api.anthropic.com';

    // Use all configured tool definitions (including dynamically added
    // web_search / web_fetch when providers are available).
    final toolsJson = _toolDefs.isEmpty
        ? '[]'
        : jsonEncode(_toolDefs.values.toList());

    // Build API conversation. When the conversation exceeds maxContextTokens,
    // compact it: fold the far span into a role:user summary and replay only the
    // near-verbatim span (projection [摘要][近段原文][当前]). The guard anchors
    // (non-compressible invariants) are injected into the system prompt.
    final maxContextTokens = agentType.maxContextTokens ?? 0;
    final List<Map<String, dynamic>> apiMessages;
    // 3.1（环）：这条投影的时间线。声明在分支外，好让「发送前捕获拆分」那一处
    // （在工具循环里、每次发送都走到）也能拿到它。退化路径（不走压缩 / 投影为空）
    // 留空列表，那一处据此造一条整段按原文发的退化时间线。
    List<ProjectionPiece> projectionTimeline = const [];
    if (maxContextTokens > 0) {
      // NOTE (2026-09-20): a per-session cap on how much a session may compress
      // used to sit here and skip ALL on-demand compaction once the session had
      // produced enough summary rows. It was removed on purpose — see the note
      // above [_summaryStoreOpen]. Compaction now always runs when the threshold
      // is crossed; "cost must not run away" is currently unowned (nothing guards
      // it).
      final loaded = await _loadClosedSegments(sessionId, messages,
          maxContextTokens, agentType.compactionThresholdPercent);
      // 这一轮要不要**为压缩等待**（用户 2026-10-02 的要求）：只看"不压就发"的那一趟
      // 投影占模型总上下文多少 —— 超过等待上界才等；不到就不压、一个摘要调用都不发，
      // 攒过阈值的内容照原文发，压缩留给空闲时的后台折叠。
      // 判定必须放在**分段选择之前**：生产环境的分段选择器自己要发一次模型请求
      // （冷缓存时），放在它后面就等于没做到"不等"。
      final waitPercent = agentType.compactionWaitThresholdPercent;
      final shareTokens = CompactionEngine.estimatedProjectionTokens(
          summaryMeasuredTokens: loaded.projected.map((c) => c.tokenCost),
          rawTail: [
            for (final m in messages)
              if ((m.seq ?? 0) > loaded.coveredThrough) m,
          ]);
      final waitForCompaction = CompactionEngine.exceedsWaitBound(
          projectedTokens: shareTokens,
          maxContextTokens: maxContextTokens,
          waitPercent: waitPercent);
      debugPrint('[AliasAgent] 压缩等待门槛：不压就发的投影≈$shareTokens token / '
          '模型容量 $maxContextTokens（等待上界 '
          '${CompactionEngine.waitBoundTokens(maxContextTokens, waitPercent)}，'
          '$waitPercent%）⇒ ${waitForCompaction ? "这一轮等它压完再发" : "不等：照原文发，压缩留给空闲后台"}');
      // 4.3 design D5 option A: when a seam selector is available, prefetch/memoize
      // the LLM L1 topic seams for the current fold BEFORE building the plan, then
      // pass a memo-backed L1SeamChooser. A seam failure degrades gracefully to the
      // arithmetic-safe skeleton (never splits a tool round, never blocks the turn).
      // 不等的那一轮连分段选择都不发起（它自己要发一次模型请求）。
      final seamChooser = waitForCompaction
          ? await _prepareSeamChooser(
              messages, loaded.projected, agentType, maxContextTokens,
              coverageFloorSeq: loaded.coveredThrough, sessionId: sessionId)
          : null;
      final planned = CompactionEngine.buildTree(
          history: messages,
          maxContextTokens: maxContextTokens,
          closed: loaded.projected,
          coverageFloorSeq: loaded.coveredThrough,
          seamChooser: seamChooser,
          thresholdPercent: agentType.compactionThresholdPercent);
      // 不等 ⇒ 把这一趟还没落盘的摘要段降级成原文段：只取已落盘的摘要拼投影。
      final plan = waitForCompaction
          ? planned
          : CompactionEngine.projectionWithoutNewSummaries(planned);
      if (plan.shouldCompact) {
        ({List<ProjectionPiece> timeline, List<SummaryResult> summaries})
            resolved = (timeline: const [], summaries: const []);
        try {
          resolved = await _resolveSummaries(sessionId, plan, agentType,
              maxContextTokens,
              history: messages,
              generate: waitForCompaction);
        } catch (e) {
          // Summarization failed — never silently replace the folded context with
          // a placeholder. Fall back to sending the conversation verbatim.
          debugPrint('[AliasAgent] compaction summary failed, sending verbatim: $e');
          resolved = (timeline: const [], summaries: const []);
        }
        if (resolved.timeline.isEmpty) {
          // Empty-far pathological case: compaction split-omitted the ENTIRE far
          // span (no compressible batch) and there was no verbatim tail, so the
          // projection is empty — we fall back to the full conversation (which is
          // over budget, since we entered the fold path). Surface it rather than
          // silently resend over budget.
          debugPrint('[AliasAgent] compaction produced no projection (far fully '
              'omit-worthy, no verbatim tail) — resending the full over-budget '
              'conversation (known pathological limit)');
          apiMessages = _buildApiMessages(messages);
        } else {
          // timeline 是这条投影的时间线：发摘要的段与发原文的段按时间排好；某一趟把
          // 远端几乎全省略时摘要会为空，那时投影里只剩原文（更早的内容留在磁盘上，D9）。
          apiMessages = _buildCompactionProjection(resolved.timeline);
          projectionTimeline = resolved.timeline;
        }
      } else {
        apiMessages = _buildApiMessages(messages);
      }
    } else {
      // maxContextTokens not configured — keep the current full-send behavior.
      apiMessages = _buildApiMessages(messages);
    }

    // Track all tool calls across turns for final assistant message
    final allTurnToolCalls = <Map<String, dynamic>>[];

    // 3.1（环）：投影定下来那一刻的消息条数。工具轮里往 apiMessages 追加的那些
    // （`add` 出来的助手 tool_use 与工具结果）没有投影段，稍后按原文补进拆分里 ——
    // 不补的话，最后一轮的快照与拆分描述的不是同一份请求。
    final projectionMessageCount = apiMessages.length;

    int turn = 0;
    while (true) {
      // 12.1/15.1: abort the remaining tool loop if the user switched
      // sessions while this call was in flight — either away (12.1) or back
      // (15.1 epoch check: a switched-away call is invalidated for good).
      // Further turns would stream into the wrong session, interleave DB
      // history, and tear down a newer request's streaming state.
      if (_switchEpoch >= epoch || _currentId != sessionId) return;
      final messagesJson = jsonEncode(apiMessages);

      String turnText = '';
      final turnToolCalls = <Map<String, dynamic>>[];
      final turnThinkingBlocks = <Map<String, dynamic>>[];
      int doneCode = 0;
      String? doneError;
      // Measured usage from the provider (Anthropic-format /v1/messages
      // input_tokens/output_tokens, defensively parsed). Persisted to the
      // assistant message's token_count (the budget trigger/calibration signal).
      int lastInputTokens = 0;
      int lastOutputTokens = 0;

      // Determine thinking mode/effort from agent config
      const validEfforts = {'low', 'medium', 'high', 'xhigh', 'max'};
      final thinkingMode = (agentType.thinkingEffort != null &&
              validEfforts.contains(agentType.thinkingEffort))
          ? 'adaptive'
          : 'disabled';
      final thinkingEffort = thinkingMode == 'adaptive'
          ? agentType.thinkingEffort!
          : '';

      // (1.2) Pull the inline system-prompt expression into a named local so it
      // is readable at the capture point below. Its final content is unchanged —
      // purely a capture-side refactor.
      final systemPrompt =
          '${agentType.systemPrompt}\n${_guard.inject()}\nCurrent date: ${DateTime.now().toIso8601String().substring(0, 10)}. For precise time-sensitive queries, use the get_current_time tool.';

      // (1.3) Before each send, deep-copy the exact context handed to the
      // gateway. `messagesJson` (computed at :913) is the verbatim serialized
      // `apiMessages` for THIS round, so re-decoding it is both a faithful deep
      // copy and immune to the later in-place `.add` growth of `apiMessages` in
      // the tool loop. Captured here — NOT at the :913 jsonEncode — because only
      // here are systemPrompt / thinkingMode / thinkingEffort / toolsJson all in
      // scope. The last send of a multi-round turn wins (the grown version).
      if (mounted) {
        // 3.1/3.2（环）：占用拆分必须与快照在**同一次** setState 里写入 —— 分两次
        // 会出现一帧「快照换了、拆分还是上一次的」，那时点开面板就是错的。固定开销用
        // 仓库既有的估算器算（不是写死的数）。工具轮里这一轮比投影多出来的消息按原文
        // 补进去，两者才描述同一份请求。
        final fixedOverheadTokens =
            ContextEstimator.estimateTokens(systemPrompt) +
                ContextEstimator.estimateTokens(toolsJson);
        final trailingRawMessages =
            apiMessages.sublist(projectionMessageCount);
        // 12.3（2026-10-18 用户要求「有原文，一级，二级摘要 3 瓣条的占用量」）：
        // 环改成量**整段对话按层级划分**的构成，而不是"这一次发出去的请求的构成"。
        // 旧算法（`fromTimeline`）只在二级摘要真的进投影时二级那一段才非零，而按
        // `CompactionEngine.substitutesSpan`（2 级要两端都 > 2T）它在实际对话里几乎永远
        // 不进投影 ⇒ 那一瓣永远是 0。
        //
        // 新算法：对每条消息取**盖住它的最高层级**（二级 > 一级 > 原文），三段之和就是
        // 这段对话的 token 总量，同一条消息不会被算两次。
        // 2026-10-18 回退说明：这里曾经改成 `ContextBreakdown.fromSummaries`（按"各层摘要
        // 的 tokenCost"算三瓣），但那样必须在发送路径里 `await _summaryNodeRepo.queryBySession`
        // —— 多出来的这次查询会让 `_contextSnapshot` 在假 DB 的用例里永远落不了地
        // （context_breakdown_capture_test 4.1/4.2、ring_three_tiers_test 全红）。
        // 先把树恢复成绿的，环的分瓣口径另找数据源（见 tasks 12.5 的待办）。
        // 2026-10-18 定稿：环量的是"**这一次实际发出去那份请求**的构成"。
        //
        // 期间试过两版"按层级算"的口径，都被实测否掉：
        //  · 取最高层级：真机跑出 level2=10859 level1=0（一条大二级盖住了全部折叠内容）
        //    ⇒ 三瓣只剩两瓣，而且总量能超过窗口；
        //  · 各层摘要自身大小之和：真机跑出 1098+3948+1568 = 6614 > 窗口 6495 ⇒ **101.83%**，
        //    因为二级盖住的一级又被重复计了一次。
        // 用户 2026-10-18 明说「不应该超 100%，超了说明压缩机制有问题」—— 环必须量真实占用，
        // 而真实占用就是这份请求的大小：它天然不可能超过窗口（超了压缩根本不会发出去）。
        // 代价：二级那瓣只在二级摘要真的进投影时才非零（`substitutesSpan` 要求两端都 > 2T）。
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
        setState(() {
          _contextSnapshot = ContextSnapshot(
            sessionId: sessionId,
            systemPrompt: systemPrompt,
            messages: (jsonDecode(messagesJson) as List<dynamic>)
                .cast<Map<String, dynamic>>(),
            toolsJson: toolsJson,
            model: agentType.model,
            thinkingMode: thinkingMode,
            thinkingEffort: thinkingEffort,
            capturedAt: DateTime.now(),
            breakdown: breakdown,
          );
        });
      }

      await _sidecar.sendMessage(
        apiKey: provider.apiKey,
        baseUrl: baseUrl,
        model: agentType.model,
        systemPrompt: systemPrompt,
        messagesJson: messagesJson,
        toolsJson: toolsJson,
        thinkingMode: thinkingMode,
        thinkingEffort: thinkingEffort,
        onChunk: (text) {
          turnText += text;
          // 16.2 (E2): late chunks from a switched-away call must not render
          if (_currentId == sessionId && _switchEpoch < epoch && mounted) {
            setState(() {
              final lastIdx = _chatItems.length - 1;
              if (lastIdx >= 0 && _chatItems[lastIdx] is ChatStreamingItem) {
                _chatItems[lastIdx] = ChatStreamingItem(turnText);
              } else {
                // First text chunk — lazily create streaming item
                _chatItems.add(ChatStreamingItem(turnText));
              }
            });
          }
        },
        onToolCall: (json) {
          try {
            final tc = jsonDecode(json) as Map<String, dynamic>;
            tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}';
            turnToolCalls.add(tc);
            if (_currentId == sessionId && _switchEpoch < epoch) {
              final activity = ToolCallActivity(
                id: tc['id'] as String,
                toolName: (tc['name'] as String?) ?? 'unknown',
                input: (tc['input'] as Map<String, dynamic>?) ?? {},
              );
              if (mounted) {
                setState(() {
                  // Insert tool card before the streaming item
                  final streamIdx = _chatItems.lastIndexWhere(
                      (i) => i is ChatStreamingItem);
                  if (streamIdx >= 0) {
                    _chatItems.insert(streamIdx, ChatToolCallItem(activity));
                  } else {
                    _chatItems.add(ChatToolCallItem(activity));
                  }
                });
              }
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
              // Incremental event — UI only, NEVER persisted (D8): find the
              // active (streaming) card for this index in the current turn and
              // append the delta; create the card on first delta (D4/D6).
              if (_currentId == sessionId && _switchEpoch < epoch && mounted) {
                final delta = (th['delta'] as String?) ?? '';
                setState(() {
                  var target = -1;
                  for (int i = _chatItems.length - 1; i >= 0; i--) {
                    final item = _chatItems[i];
                    if (item is ChatThinkingItem &&
                        item.isStreaming &&
                        item.index == idx) {
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
                      index: idx,
                    );
                  } else {
                    _chatItems.add(ChatThinkingItem(
                      thinking: delta,
                      isStreaming: true,
                      index: idx,
                    ));
                  }
                });
              }
            } else if (type == 'thinking') {
              // Final block (content_block_stop): complete text + signature.
              // ONLY final blocks enter turnThinkingBlocks → thinking_json →
              // API context reconstruction (D8 / F4 fix). The `index` key is
              // stripped before persisting/replay (9.2): per D6 the index is
              // not a persisted field and is undocumented in the API's
              // thinking content block schema.
              turnThinkingBlocks.add(_thinkingBlockWithoutIndex(th));
              if (_currentId == sessionId && _switchEpoch < epoch && mounted) {
                setState(() {
                  var target = -1;
                  for (int i = _chatItems.length - 1; i >= 0; i--) {
                    final item = _chatItems[i];
                    if (item is ChatThinkingItem &&
                        item.isStreaming &&
                        item.index == idx) {
                      target = i;
                      break;
                    }
                  }
                  if (target >= 0) {
                    _chatItems[target] = ChatThinkingItem(
                      thinking: (th['thinking'] as String?) ?? '',
                      signature: th['signature'] as String?,
                      isStreaming: true,
                      index: idx,
                    );
                  } else {
                    _chatItems.add(ChatThinkingItem(
                      thinking: (th['thinking'] as String?) ?? '',
                      signature: th['signature'] as String?,
                      isStreaming: true,
                      index: idx,
                    ));
                  }
                });
              }
            } else {
              // Unknown thinking event type — never persist or render (9.7)
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
        // 12.2 (RTD-R4-02): decide switch-cancellation FIRST (context captured
        // at switch time, race-free) so the _endStreaming call is guarded too —
        // a stale cancelled done must not tear down a newer request's
        // streaming state (rapid A→B→A + new message).
        final switchCancelled = _switchEpoch >= epoch || doneError == 'cancelled';
        if (_currentId == sessionId && !switchCancelled) _endStreaming();
        // 9.5/10.2/15.1: cancellation (session switch / new chat / delete)
        // must not pollute the old session's history with an error card.
        if (switchCancelled) {
          return;
        }
        await _storeError(doneError ?? 'Unknown error', sessionId: sessionId);
        return;
      }

      // 11.1 (R3-F1/R3-F6): a request whose cancellation was triggered by a
      // session switch may still complete successfully (lost-cancel window,
      // stream already finished, or cancel during a tool-loop gap). The flag
      // MUST be cleared on the success path too (otherwise a later real error
      // in this session would be misjudged as a switch-cancel and silently
      // dropped), and this turn's _endStreaming calls must be skipped — the
      // user may have switched back and already started a new request, whose
      // streaming state must not be torn down by the stale request's done.
      final wasSwitchCancelled = _switchEpoch >= epoch;
      // 16.1 (E1): a switch invalidated this call — even if it completed
      // successfully (lost-cancel window), its late reply must NOT be
      // persisted (it would land after a newer message in DB history and get
      // replayed to the API), rendered, or tear down the newer request's
      // streaming cards. Return immediately. Release the streaming flag too
      // (17.2): the stale completion must not block a new send when the user
      // has switched back to this session.
      if (wasSwitchCancelled) {
        if (_currentId == sessionId) _endStreaming();
        return;
      }

      // Transition thinking cards to non-streaming + remove streaming item
      final thinkingJsonStr = turnThinkingBlocks.isNotEmpty
          ? jsonEncode(turnThinkingBlocks)
          : null;
      if (_currentId == sessionId && mounted) {
        setState(() {
          _chatItems.removeWhere((i) => i is ChatStreamingItem);
          // Transition all ChatThinkingItems from streaming to done,
          // preserving their derived index (D6: index survives instance rebuild)
          for (int i = 0; i < _chatItems.length; i++) {
            if (_chatItems[i] is ChatThinkingItem) {
              final old = _chatItems[i] as ChatThinkingItem;
              _chatItems[i] = ChatThinkingItem(
                thinking: old.thinking,
                signature: old.signature,
                isStreaming: false,
                index: old.index,
              );
            }
          }
        });
      }

      // No tool calls — store final assistant message and done
      if (turnToolCalls.isEmpty) {
        if (turnText.isNotEmpty) {
          final toolCallsJson = allTurnToolCalls.isNotEmpty
              ? jsonEncode(allTurnToolCalls)
              : null;
          final assistantMsg = await _msgRepo.insert(
            sessionId: sessionId,
            role: 'assistant',
            content: turnText,
            toolCallsJson: toolCallsJson,
            thinkingJson: thinkingJsonStr,
            tokenCount: lastInputTokens,
            outputTokenCount: lastOutputTokens,
          );
          await _sessionRepo.touch(sessionId);
          if (_currentId == sessionId && mounted) {
            setState(() {
              _chatItems.add(ChatMessageItem(assistantMsg, isFinalReply: true));
            });
          }
        }
        if (_currentId == sessionId && !wasSwitchCancelled) {
          _endStreaming();
          // 2.6: turn completed — schedule an idle-gated background fold so the
          // far span is pre-folded for the next turn (does not delay this turn's end).
          _maybeScheduleBackgroundFold(sessionId);
        }
        return;
      }

      // 15.5 (F2): a switch invalidated this call — do NOT execute the
      // received tool_use (side-effect tools like write_file must not run
      // after the user switched away).
      if (_switchEpoch >= epoch) return;

      // Tool calls present — accumulate and persist intermediate assistant message
      allTurnToolCalls.addAll(turnToolCalls);
      final turnJson = jsonEncode(turnToolCalls);
      final intermediateMsg = await _msgRepo.insert(
        sessionId: sessionId,
        role: 'assistant',
        content: turnText,
        toolCallsJson: turnJson,
        thinkingJson: thinkingJsonStr,
        tokenCount: lastInputTokens,
        outputTokenCount: lastOutputTokens,
      );
      await _sessionRepo.touch(sessionId);
      if (_currentId == sessionId && mounted && turnText.isNotEmpty) {
        setState(() {
          _chatItems.add(ChatMessageItem(intermediateMsg));
        });
      }

      // Build assistant content blocks for the API:
      // Order: thinking blocks first, then text, then tool_use
      final assistantBlocks = <Map<String, dynamic>>[];
      assistantBlocks.addAll(turnThinkingBlocks);
      if (turnText.isNotEmpty) {
        assistantBlocks.add({'type': 'text', 'text': turnText});
      }
      // 只放 tool_use 必需的四个键，与重放路径 _buildApiMessages 一致。
      // 下面的工具循环会 tc.addAll(activity.toJson()) 原地填充同一个 Map
      // （result / resultPreview / hunks…），若这里持有它的引用，那些字段
      // 就会随同一工具轮的第二发请求被真的发出去。
      for (final tc in turnToolCalls) {
        assistantBlocks.add({
          'type': tc['type'] ?? 'tool_use',
          'id': tc['id'] ?? '',
          'name': tc['name'] ?? '',
          'input': tc['input'] ?? <String, dynamic>{},
        });
      }

      apiMessages.add({
        'role': 'assistant',
        'content': assistantBlocks,
      });

      // Execute tools and build tool results
      final toolResults = <Map<String, dynamic>>[];
      for (final tc in turnToolCalls) {
        // 16.3 (E3/F3): per-tool epoch check — a switch during a long tool
        // await (web_search/web_fetch up to 120s) must abort the remaining
        // batch so side-effect tools (write_file/edit_file) don't run after
        // the user switched away.
        if (_switchEpoch >= epoch) break;
        final result = await _executeTool(tc);
        final resultContent = result['ok'] == true
            ? (result['content'] as String? ?? '')
            : (result['error'] as String? ?? 'Tool failed');

        // Update tool activity card in _chatItems
        final toolId = (tc['id'] as String?) ?? '';
        if (_currentId == sessionId && mounted) {
          setState(() {
            for (int i = 0; i < _chatItems.length; i++) {
              final item = _chatItems[i];
              if (item is ChatToolCallItem && item.activity.id == toolId) {
                final toolName2 = (tc['name'] as String?) ?? '';
                final isSearchTool = toolName2 == 'web_search' || toolName2 == 'web_fetch';
                _chatItems[i] = ChatToolCallItem(item.activity.copyWith(
                  status: result['ok'] == true
                      ? ToolCallStatus.done
                      : ToolCallStatus.error,
                  result: resultContent,
                  resultPreview: resultContent.length > 300
                      ? '${resultContent.substring(0, 300)}...'
                      : resultContent,
                  resultSections: isSearchTool
                      ? _buildResultSections(toolName2, result)
                      : null,
                  hunks: _parseEditHunks(result['hunks']),
                  hunksOmitted: result['hunks_omitted'] as String?,
                ));
                break;
              }
            }
          });
        }

        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': tc['id'] ?? '',
          'content': resultContent,
        });

        // Enrich turnToolCalls entry with result data for persistence (D6)
        if (_currentId == sessionId) {
          for (int j = 0; j < _chatItems.length; j++) {
            final ci = _chatItems[j];
            if (ci is ChatToolCallItem && ci.activity.id == toolId) {
              tc.addAll(ci.activity.toJson());
              break;
            }
          }
        }
      }

      // Update intermediate message with enriched tool call data. This is the
      // sole leaf-level content mutation, so it invalidates the compaction tree
      // via the dirty-since-seq watermark (markDirty below) — no full-table
      // tree_version bump (R2-2). Any cached summary over a span that includes
      // this message must be recomputed (buildTree recomputes lazily next turn).
      if (_currentId == sessionId) {
        await _msgRepo.updateToolCalls(
            intermediateMsg.id, jsonEncode(turnToolCalls));
        // Record the leaf-level content mutation as a dirty-since-seq watermark
        // (D8 lazy recompute). Instead of a full-table tree_version bump on every
        // leaf change (R2-2), lower dirty_since_seq so _resolveSummaries
        // re-summarizes only spans that reach the dirty region. Gated on a real
        // DB being open: hermetic widget tests never open one, and this must not
        // lazily create the user DB as a side effect.
        if (DatabaseService.isOpen) {
          try {
            final dirtySeq = intermediateMsg.seq;
            if (dirtySeq != null) {
              await _summaryNodeRepo.markDirty(sessionId, dirtySeq);
            }
          } catch (e) {
            debugPrint('[AliasAgent] mark dirty watermark failed: $e');
          }
        }
      }

      apiMessages.add({
        'role': 'user',
        'content': toolResults,
      });

      // Reset per-turn state
      turnText = '';
      turnToolCalls.clear();
      turnThinkingBlocks.clear();
      if (turn >= 50) {
        debugPrint('[AliasAgent] Max tool turns (50) exceeded — aborting');
        if (_currentId == sessionId && !wasSwitchCancelled) {
          _endStreaming();
          _maybeScheduleBackgroundFold(sessionId);
        }
        await _sessionRepo.touch(sessionId);
        return;
      }
      turn++;
    }
  }

  /// Strip the internal `index` key from a thinking block before persisting
  /// or replaying it to the API (9.2): per D6 the index is not a persisted
  /// field, and it is undocumented in the API's thinking content-block schema.
  static Map<String, dynamic> _thinkingBlockWithoutIndex(
      Map<String, dynamic> th) {
    if (!th.containsKey('index')) return th;
    final cleaned = Map<String, dynamic>.from(th)..remove('index');
    return cleaned;
  }

  /// Resolve summaries for every summary segment of a fold plan: reuse a
  /// previously-persisted summary node covering that segment (so the send path
  /// does NOT re-invoke the LLM), else generate via [_summaryProvider] and
  /// best-effort persist it to summary_nodes (background-folding reuse). The
  /// persistence write is transactional re: tree_version.
  /// Read the session's CLOSED (frozen) summary segments from summary_nodes so
  /// buildTree can do progressive closure — only fold the unclosed tail, never
  /// re-open or re-shape a closed segment (⑨). Returns a non-overlapping set
  /// sorted by span (D9 dense non-overlap), cheapest-first priority on coarser
  /// nodes is refined by Phase-4 frontier logic; here we just avoid overlap.
  /// Prefetch/memoize the LLM L1 topic seams (4.3, D5 option A) for a fold and
  /// return a memo-backed chooser. Shared by the inline send path and the
  /// background fold so both produce the SAME segment topology: a closed segment
  /// materialized by the background fold is then cache-hit by the inline path.
  /// A seam failure degrades to the arithmetic-safe skeleton (never splits a
  /// tool round, never blocks the turn).
  Future<L1SeamChooser?> _prepareSeamChooser(List<Message> history,
      List<ClosedSummary> closed, AgentTypeConfig agentType,
      int maxContextTokens,
      {int? coverageFloorSeq,
      bool Function()? isAborted,
      bool background = false,
      String? sessionId}) async {
    if (_seamSelector == null) return null;
    final seamInputs = CompactionEngine.resolveFoldSeamInputs(
        history: history,
        maxContextTokens: maxContextTokens,
        closed: closed,
        coverageFloorSeq: coverageFloorSeq,
        thresholdPercent: agentType.compactionThresholdPercent);
    // 这一条同时是界面的闸门：`resolveFoldSeamInputs` 返回空 ⇔ 这次没有远端内容要压
    // （它和算计划的 `_foldEndFor` 共用同一个判断），所以"没到阈值就返回"的路径上
    // 界面上不会亮任何东西 —— 后台压缩每次空闲都会试一次，亮在这里会次次闪一下。
    if (seamInputs == null) return null;
    final seamSel = _seamSelector;
    // 2.6 abort gate: the seam ensure makes its own model call (SeamSelector.ensure
    // -> a real sendMessage on the single-slot _chain). A preempted background fold
    // must NOT enqueue it ahead of the user's request. Inline send path passes null.
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled('background fold aborted before seam selection');
    }
    // 热缓存时 `ensure` 直接返回、不发请求，所以只有冷缓存才亮提示（否则会闪）。
    // 提示在这里自己收尾：无论成功、失败还是抛异常，出这个函数前都回到空闲。
    // 归属标记：这一趟的提示只有这一趟能清（后台那趟被抢占后收尾时不许清掉
    // 发送前那趟正在显示的提示）。
    final seamOwner = Object();
    final coldSeam =
        seamSel.memoizedSeams(far: seamInputs.far, k: seamInputs.k) == null;
    if (coldSeam) {
      _setCompactionStatus(CompactionStatus.seam(background: background),
          owner: seamOwner, sessionId: sessionId);
    }
    try {
      await seamSel.ensure(
          far: seamInputs.far, k: seamInputs.k, config: agentType);
      return (far, k) => seamSel.memoizedSeams(far: far, k: k) ?? const [];
    } catch (e) {
      debugPrint('[AliasAgent] seam selection failed, using arithmetic skeleton: $e');
      return null;
    } finally {
      if (coldSeam) _clearCompactionStatus(owner: seamOwner);
    }
  }

  /// Schedule a background fold for the idle gap after a completed user turn
  /// (2.6). Idle-gated + preemptible: it runs only when the model slot is free
  /// (not streaming, no fold in flight), the DB is open, `maxContextTokens` is
  /// set, and the user stays idle past a short debounce window. Hermetic widget
  /// tests (which inject a fake summary provider) leave it disabled by default.
  void _maybeScheduleBackgroundFold(String sessionId) {
    if (!_backgroundFoldEnabled) return;
    if (_isStreaming || _foldInFlight) return;
    if ((registry.lookup('general')?.maxContextTokens ?? 0) <= 0) return;
    _foldIdleTimer?.cancel();
    _foldIdleTimer = Timer(const Duration(seconds: 2), () {
      _foldIdleTimer = null;
      if (mounted && !_isStreaming && !_foldInFlight) {
        _runBackgroundFold(sessionId);
      }
    });
  }

  /// Run a background fold for `sessionId`: build a fold plan from the persisted
  /// history and fold+materialize the far span via [_resolveSummaries] (which
  /// writes closed summary nodes transactionally + bumps tree_version). Reuses
  /// the SAME pure fold path as the user's inline send, so a materialized closed
  /// segment is then cache-hit by the inline `_resolveSummaries` — the user's
  /// token-time is NOT consumed by re-summarization. Preemptible: a user send
  /// increments `_foldGen` (=`myGen` mismatch → `isAborted`) and cancels the
  /// in-flight model request (request-id targeted cancel); the fold aborts and
  /// does not delay the user (design D8 per-request-id cancel).
  Future<void> _runBackgroundFold(String sessionId) async {
    if (_foldInFlight) return;
    final agentType = registry.lookup('general');
    if (agentType == null) return;
    final maxContextTokens = agentType.maxContextTokens ?? 0;
    if (maxContextTokens <= 0) return;

    _foldInFlight = true;
    final myGen = _foldGen;
    try {
      // Durable resume point (D8 progressive closure): the already-persisted
      // closed segments are an INPUT, so only the not-yet-closed tail is folded.
      // NOTE: we do NOT gate on DatabaseService.isOpen here. In production the DB
      // is always open, so materialize persists; in hermetic tests (fake repos,
      // no DB) the fold still runs and computes summaries but skips persist
      // (the materialize calls inside _resolveSummaries are `if (dbOpen)`).
      final messages = await _msgRepo.queryBySession(sessionId);
      if (messages.isEmpty) return;
      final loaded = await _loadClosedSegments(sessionId, messages,
          maxContextTokens, agentType.compactionThresholdPercent);
      // Durable resume point (D8 progressive closure) = how far the persisted
      // summaries already cover; logged only for observability (there is no
      // separate in-memory checkpoint control value).
      final topClosedMax =
          loaded.coveredThrough < 0 ? 0 : loaded.coveredThrough;
      final seamChooser = await _prepareSeamChooser(
          messages, loaded.projected, agentType, maxContextTokens,
          coverageFloorSeq: loaded.coveredThrough,
          isAborted: () => _foldGen != myGen,
          background: true,
          sessionId: sessionId);
      final plan = CompactionEngine.buildTree(
          history: messages,
          maxContextTokens: maxContextTokens,
          closed: loaded.projected,
          coverageFloorSeq: loaded.coveredThrough,
          seamChooser: seamChooser,
          thresholdPercent: agentType.compactionThresholdPercent);
      if (!plan.shouldCompact) {
        debugPrint('[AliasAgent] background fold: nothing to fold — the '
            'accumulated content has not passed the threshold yet '
            '(top closed seq=$topClosedMax) -> no-op');
        return;
      }
      final resolved = await _resolveSummaries(
          sessionId, plan, agentType, maxContextTokens,
          history: messages, isAborted: () => _foldGen != myGen,
          background: true);
      debugPrint('[AliasAgent] background fold: folded '
          '${resolved.summaries.length} summary segment(s) for session $sessionId, '
          'top closed seq=$topClosedMax');
    } catch (e) {
      // A preempted fold's in-flight summarize throws (ModelSummaryProvider throws
      // on done != 0, which includes cancel). Treat as "aborted, resume next idle"
      // — the already-materialized closed nodes are durable; never a hard failure.
      debugPrint('[AliasAgent] background fold aborted for session $sessionId: $e');
    } finally {
      _foldInFlight = false;
    }
  }

  // NOTE (2026-09-20): a per-session cap on how much a session may compress used
  // to live here. It was
  // removed on purpose — do NOT reinvent it. What it was: two constants (a cap of
  // 30 and a cap of 500000), a pure check, a DB-backed check, and two early exits
  // (one in _callModel, one at the top of _runBackgroundFold) that made a session
  // stop compacting once either cap tripped. Why it was removed:
  //  1. It measured the WRONG thing. It counted the summary rows the session had
  //     ever produced (`summary_nodes` rows with level >= 1 and a token cost).
  //     Rows covered by a coarser summary are never deleted, so that count only
  //     ever grows: it treated finished, useful work as if it were the cost.
  //  2. Its failure mode was worse than the thing it guarded. Crossing it once
  //     turned compaction OFF for good — both the inline path and the background
  //     fold — so the session went back to sending the whole conversation every
  //     turn. That is not a degradation, it is a permanent stop, and it never
  //     recovers. Compaction existing at all is what it destroyed.
  //  3. Its thresholds were both of the kinds the user has forbidden: 30 is a
  //     COUNT gate, and 500000 is an absolute number unrelated to the model
  //     window. The threshold is only ever the model's context window times a
  //     percentage (see CompactionEngine.thresholdTokens and the locked
  //     requirement in TODO.md).
  //  4. It tripped BEFORE that threshold did, so the behaviour the user asked for
  //     (compress once enough has accumulated) could never even happen.
  // As a result, "cost must not run away" currently has NO owner: nothing guards
  // summarization spend (each pass that produces a new batch is one more model
  // call, so it grows with the conversation). That is stated plainly rather than
  // papered over. If a guard is ever added again, it must (a) measure the resource
  // it protects — tokens or money, not a count, (b) derive its threshold from the
  // model window, and (c) DEGRADE (compress less, or coarser) rather than stop,
  // and recover on its own.

  /// True when the compaction tree store (summary_nodes) can be used.
  ///
  /// An INJECTED repository is always usable — it is the in-memory stand-in a
  /// hermetic widget test supplies, and it needs no database. The production
  /// repository needs the real database to be open. Using this instead of a raw
  /// `DatabaseService.isOpen` is what lets a widget test preset "nodes already
  /// persisted by an earlier round" and still exercise the real pipeline.
  bool get _summaryStoreOpen =>
      widget.summaryNodeRepo != null || DatabaseService.isOpen;

  /// Load the summaries an earlier round already persisted, as the fixed floor the
  /// new fold builds on. Two kinds come back, and the difference is only whether
  /// they may be an input to a NEW roll-up (see [ClosedSummary.rollable]):
  ///  - level 1 → may be combined with other level-1 summaries into a coarser
  ///    level-2 summary. This is what lets accumulation carry across rounds: a
  ///    summary written last round is not dead weight, it counts toward the
  ///    threshold together with this round's.
  ///  - level 2 and above → frozen, never an input to another roll-up.
  /// BOTH kinds keep excluding the raw conversation they cover: [CompactionEngine]
  /// takes the highest covered sequence of every loaded node as the floor, so the
  /// original messages under any of them are never compressed a second time.
  ///
  /// 返回两个东西：
  ///  - [projected]：这次投影要用的节点，互不重叠、从旧到新；
  ///  - [coveredThrough]：**所有**已落盘节点覆盖到的最远 seq（不只是被选中的那些）。
  ///    那段原文已经压过一次，不许再被当成尾部重新压，所以它单独给出来；一条节点都
  ///    没有时是 -1。
  ///
  /// 选谁进投影按"离现在多远"判（用户 2026-09-26 的要求：压缩随时做，但只有位置足够
  /// 靠后时才对模型换成摘要；判据见 [CompactionEngine.substitutesWholeSpan]）：
  ///  - 一条摘要要顶替它盖住的整段，那段得**整段**都落到它该在的档里（1 级要整段超过
  ///    阈值，2 级要整段超过两倍阈值）。
  ///  - 所以一条 2 级还不够远时**不收它、改收它盖住的那几条 1 级**（更细、多花一点
  ///    token，但不重复、也不提前顶替）；够远才收它，那时它盖住的 1 级整条跳过。
  ///  - 谁都没盖住的那部分不会丢：[CompactionEngine.buildTree] 拿 [coveredThrough] 当
  ///    已闭合区间的上界，把那部分按原文补进投影。
  Future<({List<ClosedSummary> projected, int coveredThrough})>
      _loadClosedSegments(String sessionId, List<Message> history,
          int maxContextTokens, int? thresholdPercent) async {
    if (!_summaryStoreOpen) {
      return (projected: const <ClosedSummary>[], coveredThrough: -1);
    }
    try {
      final nodes = await _summaryNodeRepo.queryBySession(sessionId);
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
          maxContextTokens, thresholdPercent);
      final distances = CompactionEngine.distancesFromNewest(history);
      // 同一起点上跨度大的排前面：够远的 2 级因此先被选中，它盖住的 1 级接着被跳过，
      // 仍然得到"互不重叠、从旧到新"的一份。
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
        // 已经被前面选中的那条盖住了 ⇒ 同一段不许有两种表示。
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
        // 2 级还不够远 ⇒ 不收它，改收它盖住的那几条 1 级（更细的表示）。
        // 1 级不够远也要收：它是这一段最细的摘要表示，而且"1 级攒够阈值就合成 2 级"这条
        // 规则要靠它的实测 token 参与累加 —— 收进来由投影那一趟决定它到底发摘要还是发
        // 原文（见 [_resolveSummaries]），压缩本身不受影响。
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

  /// Fetch or produce the level-1 summary TEXT for a sub-span [msgs] (used by the
  /// 2-pass level-2 "summary of summaries"): reuse the persisted level-1 node if
  /// present & not stale, else summarize the span and best-effort persist level-1.
  Future<String> _l1SummaryText(String sessionId, bool dbOpen, int dirtySince,
      List<Message> msgs, AgentTypeConfig agentType,
      {bool Function()? isAborted}) async {
    if (msgs.isEmpty) return '';
    final minSeq = msgs.first.seq;
    final maxSeq = msgs.last.seq;
    if (dbOpen && minSeq != null && maxSeq != null) {
      try {
        final node = await _summaryNodeRepo.findCovering(sessionId, minSeq, maxSeq, level: 1);
        if (node != null && node.summaryJson != null &&
            (dirtySince == 0 || node.coveredMaxSeq < dirtySince)) {
          final t = _summaryTextFromJson(node.summaryJson!);
          if (t.isNotEmpty) return t;
        }
      } catch (e) {
        debugPrint('[AliasAgent] L1 sub-span reuse failed: $e');
      }
    }
    // 2.6 abort gate: this helper makes its own model call INSIDE the fold, and a
    // preempted fold must NOT enqueue a further summarize onto the single-slot
    // _chain ahead of the user's request. Check the generation before issuing it
    // (the in-flight request is cancelled by the preempt's cancelRequest; the next
    // one is prevented here). Inline callers pass isAborted:null -> no-op.
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled('background fold aborted during L1 sub-span');
    }
    final s = await _summaryProvider.summarize(folded: msgs, config: agentType);
    if (dbOpen && minSeq != null && maxSeq != null) {
      try {
        await _summaryNodeRepo.materialize(
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
          model: agentType.model,
          coveredMinSeq: minSeq,
          coveredMaxSeq: maxSeq,
        );
      } catch (e) {
        debugPrint('[AliasAgent] L1 sub-span persist failed: $e');
      }
    }
    return s.text;
  }

  /// 把一批还没闭合的原文解析成它**这一级**的内容（design D2/D3）。
  ///
  /// 规则（用户 2026-10-05，两级同一条）：压缩前、压缩后比 token，**取小的那一侧**。
  /// 压缩后的实测 token 真的更小就采用它；否则**这一级的内容就是这批原文本身** ——
  /// 返回一个 [CompactionSegment.verbatimAtLevel] 为真的条目：它照样在这一级上占位
  /// （能进合成更粗的一级、参与阈值累积），但渲染永远走原文路径，一个块不少。
  ///
  /// 原来那条"折半重试、切到原子批就 `return const []` 把它丢掉"的路径已经删掉 ——
  /// 压不短不再是一个失败态，所以不存在"因为压不短而丢内容"。
  ///
  /// [onNotResummarized]：这一批这一趟**没有重新生成摘要**时回调（压缩前赢那一支）。
  /// 调用方据此不消费脏水位（R8-c）—— 否则下一趟会复用一条陈旧的缓存摘要。
  Future<List<({CompactionSegment seg, String text, int tokens, bool isClosed})>>
      _resolveOpenLevel1(List<Message> msgs, AgentTypeConfig agentType,
          {bool Function()? isAborted,
          void Function(int minSeq, int maxSeq)? onNotResummarized,
          List<SummaryReference> reference = const []}) async {
    // 2.6 abort gate: a preempted background fold must stop at the next model call
    // rather than enqueueing an un-cancelled summarize onto the single-slot _chain
    // ahead of the user's request. Inline callers pass null.
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled('background fold aborted during open-batch resolve');
    }
    if (msgs.isEmpty) return const [];
    final raw = CompactionEngine.rawTokens(msgs);
    final summary = await _summaryProvider.summarize(
        folded: msgs, config: agentType, reference: reference);
    if (CompactionEngine.summarySideWins(raw, summary.tokens)) {
      return [
        (seg: CompactionSegment(messages: msgs, summary: true, level: 1),
            text: summary.text, tokens: summary.tokens, isClosed: false),
      ];
    }
    // 压缩后不比压缩前小 ⇒ 取压缩前那一侧：这一级的内容就是这批原文本身。
    // 它没有被重新摘要，所以照旧要把"没重生成摘要"这件事告诉调用方（脏水位规则）。
    if (onNotResummarized != null && msgs.isNotEmpty) {
      onNotResummarized(msgs.first.seq ?? 0, msgs.last.seq ?? 0);
    }
    return [
      (
        seg: CompactionSegment(
            messages: msgs, summary: true, level: 1, verbatimAtLevel: true),
        // text 只给"合成更粗一级"当输入用；真正发出去时走的是 seg.messages 的
        // 原文渲染路径（见 Phase C）。
        text: msgs
            .map((m) => m.content)
            .where((c) => c.isNotEmpty)
            .join('\n\n'),
        tokens: raw,
        isClosed: false,
      ),
    ];
  }

  /// 这个函数只做一件事：保证压缩状态**无论成功、失败、异常还是被打断都回到空闲**
  /// （放在 finally 里，所以不需要每个出口各写一遍）。真正干活的在
  /// [_resolveSummariesInner]，它按段把状态推进到"正在生成第几段"。
  /// [background] 为真表示这是空闲时自动跑的那趟压缩，界面据此说明"发消息会让它先让路"。
  Future<({List<ProjectionPiece> timeline, List<SummaryResult> summaries})>
      _resolveSummaries(String sessionId, CompactionPlan plan,
          AgentTypeConfig agentType, int maxContextTokens,
          {required List<Message> history,
          bool Function()? isAborted,
          bool background = false,
          bool generate = true}) async {
    // 归属标记：这一趟置位的提示只有这一趟能清。反过来，别的压缩流（例如被抢占的
    // 后台那趟）收尾时也不会把这一趟正在显示的提示清掉。
    final statusOwner = Object();
    try {
      return await _resolveSummariesInner(sessionId, plan, agentType,
          maxContextTokens,
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
      _resolveSummariesInner(String sessionId, CompactionPlan plan,
          AgentTypeConfig agentType, int maxContextTokens,
          {required List<Message> history,
          bool Function()? isAborted,
          bool background = false,
          bool generate = true,
          Object? statusOwner}) async {
    final dbOpen = _summaryStoreOpen;
    // Dirty-since-seq watermark (D8 lazy recompute): a cached summary may be
    // reused only if its covered span is strictly below the watermark (clean —
    // no leaf content changed in it). Spans reaching the dirty region are stale
    // and must be re-summarized, never blindly reused (R2-2).
    var dirtySince = 0;
    if (dbOpen) {
      try {
        dirtySince = await _summaryNodeRepo.dirtySinceSeq(sessionId);
      } catch (e) {
        debugPrint('[AliasAgent] dirty watermark read failed: $e');
      }
    }
    var persistFailed = false;

    // Phase A — resolve each summary segment to text + MEASURED tokens (⑪.1 real
    // output_tokens), keeping its identity for the measure→adjust loop (⑪.3).
    final entries = <({CompactionSegment seg, String text, int tokens, bool isClosed})>[];
    // 界面进度：这一步一共要**生成**几条摘要段（已落盘的段是取库、不算进度），
    // 每开始一条就把状态推进一次。`generate == false`（这一轮不等）时下面不会有
    // 任何需要生成的段，所以状态不会被点亮。
    final summarySegTotal = plan.segments
        .where((s) => s.summary && s.messages.isNotEmpty && s.reuse == null)
        .length;
    var summarySegNo = 0;
    // 参考上下文的候选：这一趟开始前从库里读**一次**快照（本变更第一条决定）。
    // 库没打开或读不到 ⇒ 空 ⇒ 整条参考路径退化成今天的行为。快照只读一次，
    // 所以同一趟里前面几段刚压出来的摘要不会跑进后面几段的参考里。
    final referenceCandidates = await _loadReferenceCandidates(sessionId, dbOpen);
    for (final seg in plan.segments) {
      if (isAborted?.call() ?? false) {
        throw const _BackgroundFoldCancelled('background fold aborted between segments');
      }
      if (!seg.summary || seg.messages.isEmpty) continue;
      // 已落盘的段（reuse != null）只取库、不发请求，也不算进度。
      if (seg.reuse == null) {
        summarySegNo++;
        _setCompactionStatus(CompactionStatus.level1(
            segment: summarySegNo, total: summarySegTotal, background: background),
            owner: statusOwner, sessionId: sessionId);
      }
      final minSeq = seg.messages.first.seq;
      final maxSeq = seg.messages.last.seq;

      // A CLOSED (frozen) segment must ALWAYS cache-hit its persisted summary —
      // never re-summarized, regardless of the dirty watermark (spec "Segment
      // closure and summary immutability" / D8 progressive closure). Its content
      // is fixed history, so it can never be stale.
      if (seg.reuse != null) {
        if (!dbOpen) {
          throw StateError('closed segment ${seg.reuse!.coveredMinSeq}..'
              '${seg.reuse!.coveredMaxSeq} cache lookup requires an open DB');
        }
        final node = await _summaryNodeRepo.findCovering(sessionId,
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
        entries.add((seg: seg, text: text, tokens: node.tokenCost ?? 0, isClosed: true));
        continue;
      }
      if (dbOpen && minSeq != null && maxSeq != null) {
        // Open (not-yet-closed) segment: reuse its cached summary only if it is
        // not stale (covered span strictly below the dirty watermark). Query at
        // the segment's level (1 or 2) so an open level-2 node can be reused.
        try {
          final node = await _summaryNodeRepo.findCovering(sessionId, minSeq, maxSeq,
              level: seg.level);
          if (node != null && node.summaryJson != null &&
              (dirtySince == 0 || node.coveredMaxSeq < dirtySince)) {
            final text = _summaryTextFromJson(node.summaryJson!);
            if (text.isNotEmpty) {
              entries.add((seg: seg, text: text, tokens: node.tokenCost ?? 0, isClosed: false));
              continue;
            }
          }
        } catch (e) {
          debugPrint('[AliasAgent] summary reuse read failed: $e');
        }
      }

      // 2-pass "summary of summaries" (level-2) — nominal buildTree no longer
      // yields an open level-2, but a closed level-2 is handled above; keep this
      // path for safety (l2SubSpans = null → single coarser pass).
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
          l1Texts.add(
              await _l1SummaryText(sessionId, dbOpen, dirtySince, l1Msgs, agentType,
                  isAborted: isAborted));
        }
        final summary = await _summaryProvider.summarizeText(
            text: l1Texts.join('\n\n'), config: agentType);
        if (dbOpen && minSeq != null && maxSeq != null) {
          debugPrint('[AliasAgent] folding ${seg.messages.length} messages '
              '(seq $minSeq..$maxSeq) into a level-${seg.level} summary');
          try {
            await _summaryNodeRepo.materialize(
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
              model: agentType.model,
              coveredMinSeq: minSeq,
              coveredMaxSeq: maxSeq,
            );
          } catch (e) {
            persistFailed = true;
            debugPrint('[AliasAgent] persist summary failed: $e');
          }
        }
        entries.add((seg: seg, text: summary.text, tokens: summary.tokens, isClosed: false));
        continue;
      }

      // OPEN level-1 batch：按"取小者"解析它这一级的内容。压缩后的实测 token 真的更小
      // 就用摘要；否则这一级的内容就是这批原文本身（`verbatimAtLevel`），渲染走原文
      // 路径、一个块不少。压不短不再丢任何东西。
      final leafEntries = await _resolveOpenLevel1(seg.messages, agentType,
          // 参考上下文：最多两条、只取覆盖范围严格早于这一批的（挑选规则见
          // selectSummaryReferences）。
          reference: selectSummaryReferences(
              persisted: referenceCandidates, batchOldestSeq: minSeq ?? 0),
          isAborted: isAborted,
          // R8-c: 这一批这一趟**没有重新生成摘要**（走了"压缩前赢"那一支）时，不许消费
          // 脏水位 —— 否则下一趟会复用一条陈旧的缓存摘要。置 persistFailed 让下面那道
          // clearDirty 的门跳过。
          onNotResummarized: (minSeq, maxSeq) {
            if (dirtySince > 0 && maxSeq >= dirtySince) persistFailed = true;
          });
      for (final leaf in leafEntries) {
        // Hermetic tests (no DB open) never persist the derived index. 这一级的内容是
        // 它自己的原文时（verbatimAtLevel）也不落盘：写进去的话下一趟会被当成一条普通
        // 一级摘要加载，就有可能被文本化渲染 —— 那正是要避免的事。
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
            await _summaryNodeRepo.materialize(
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
              model: agentType.model,
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

    // Phase B — fold→measure→adjust over ONE table, oldest → newest.
    //
    // The table holds every entry that goes into the projection: summaries loaded
    // from earlier rounds and the batches produced by this pass, in time order.
    // What an entry may be used for depends on its LEVEL, not on whether it was
    // loaded or freshly produced:
    //  - level 1 → adjustable: consecutive level-1 entries may be rolled up into
    //    one coarser level-2 summary, and may be dropped from THIS request;
    //  - level 2+ → frozen: never an input to another roll-up (two levels only).
    //    A level-2 persisted by an earlier round is also never dropped from the
    //    request — that is the real "frozen closed summary" guarantee.
    //
    // Two independent reasons to keep going, and nothing else:
    //  - the projection is still over the model capacity ⇒ keep rolling up or
    //    drop the oldest adjustable entry from THIS request (data stays on disk);
    //  - a run of level-1 summaries has accumulated past the threshold T and has
    //    not been submitted yet ⇒ roll it up, EVEN IF the projection already
    //    fits. The threshold alone is the trigger; spare room in the window is
    //    not a reason to skip it (the user's pinned rule) — and this is what makes
    //    accumulation carry across rounds instead of resetting each request.
    //
    // Termination rule (explicit, else this loop can spin): a roll-up that was
    // REJECTED (the level-2 measured no smaller than the L1s it would replace) is
    // recorded, and its entries are never submitted again in this pass. Below the
    // capacity bound a rejection just stops that attempt — the valid L1s stay,
    // nothing is dropped, and no second model call is made for the same futile merge.
    //
    // 合成与投影是两件事：这一趟合出来的 2 级如果**还没整段落到最远档**，就只落盘、
    // 不拿它顶替（被它盖住的 1 级照旧留在表里参与投影），同样标记成已提交以免反复合成。
    // 判据见 [CompactionEngine.substitutesSpan]；这一条不影响"阈值到了就做合成"。
    final verbatimRaw = CompactionEngine.rawTokens(plan.verbatim);
    final T = CompactionEngine.thresholdTokens(
        maxContextTokens, agentType.compactionThresholdPercent);
    // 这一条会不会真的以"摘要"的形式发出去：1 级看它盖住的整段的起点是否已经离开最近
    // 的原文窗口（距离超过 T），2 级要求整段都落到最远档（两端都超过 2T）。还不够远的
    // 那些这一趟按更细的表示发 —— 压缩照做、也照落盘，只是还没有轮到它顶替（用户
    // 2026-09-26 的要求：只有位置足够靠后时才对模型换成摘要）。
    final distances = CompactionEngine.distancesFromNewest(history);
    // 同一条段会被反复问"它在历史里的下标"（收拢循环每一轮都要问），所以按段缓存一次；
    // 用 identity 的 Map：段是按对象认的，不是按内容相等。
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

    bool sentAsSummary(({CompactionSegment seg, String text, int tokens, bool isClosed}) e) {
      final span = spanOf(e.seg);
      if (span == null) return false;
      return CompactionEngine.substitutesSpan(
        distanceAtOldest: distances[span.oldest],
        distanceAtNewest: distances[span.newest],
        level: e.seg.level,
        t: T,
      );
    }

    // 投影的真实大小：会当摘要发出去的按摘要实测 token 算，其余（照原文发的）按原文
    // 估算算 —— 不许拿"存下来了但这一趟不会发"的摘要去抵投影大小。
    int projectedTotal(
            List<({CompactionSegment seg, String text, int tokens, bool isClosed})> t) =>
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
    // 因为容量不够而把一条内容从这次请求里拿掉时，**只有二级及以上、且这一趟确实按
    // 摘要发出去的**条目允许被拿掉（用户 2026-10-05：允许静默丢弃的只有超过上下文上限
    // 的 L2 级摘要，不应该有其它东西允许静默丢弃）。一级摘要与原文一条都不许拿 ——
    // 拿掉一条按原文发的条目等于直接丢内容，不是换一种更粗的表示。
    bool omittable(
            ({CompactionSegment seg, String text, int tokens, bool isClosed}) e) =>
        CompactionEngine.mayBeLeftOut(
            level: e.seg.level, sentAsSummary: sentAsSummary(e));
    // Identity set: entry records compare structurally, so identity is what tells
    // "this exact entry was already submitted" apart from an equal-looking one.
    final attempted = Set<Object>.identity();
    var rollUpNo = 0;
    // 这一轮不等（generate == false）时**一次合成请求都不发**：库里的摘要只拿来拼投影。
    // 占比不到等待上界 ⇒ 投影不超容量 ⇒ 也不需要省略，所以跳过整个收拢循环是安全的。
    while (generate && table.isNotEmpty) {
      if (isAborted?.call() ?? false) {
        throw const _BackgroundFoldCancelled('background fold aborted during coarsen');
      }
      final overCapacity = total > maxContextTokens;
      // The roll-up target: the OLDEST run of consecutive level-1 summaries whose
      // accumulated measured tokens pass T, skipping entries already submitted.
      // A level-2 entry only ever BREAKS a run; it is never merged (merging it
      // would make the new one "a summary of a summary + more" and persist
      // overlapping level-2 rows).
      var candStart = -1;
      var candCount = 0;
      var candGroup = <({CompactionSegment seg, String text, int tokens, bool isClosed})>[];
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
        // Already-submitted entries form a PREFIX of their run (groups are always
        // taken from the run's oldest), so skip them and consider the fresh tail.
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
        // Nothing left to roll up. Over capacity ⇒ leave the OLDEST adjustable
        // entry out of this request (data kept on disk); otherwise this pass is done.
        if (!overCapacity) break;
        final dropAt = table.indexWhere(omittable);
        if (dropAt < 0) break;
        table.removeAt(dropAt);
        total = projectedTotal(table);
        continue;
      }
      final groupSum = candGroup.fold(0, (m, e) => m + e.tokens);
      // 界面进度：这一趟的第几次合成。总数事先不知道（要看收拢循环怎么走），
      // 所以只报"正在生成第几段"，不编造分母。
      rollUpNo++;
      _setCompactionStatus(CompactionStatus.level2(
          segment: rollUpNo, background: background),
          owner: statusOwner, sessionId: sessionId);
      final l2 = await _summaryProvider.summarizeText(
          text: candGroup.map((e) => e.text).join('\n\n'), config: agentType);
      // 取小者（用户 2026-10-05，两级同一条）：压缩后的实测 token 真的更小，就用模型
      // 给的那条；否则**这一级的正文就是那几条一级的文本拼接**（压缩前那一侧）。
      //
      // 原来那条"二级不比那几条一级短就拒绝、装不下就把那组一级逐条丢掉"的路径已经
      // 删掉 —— 取小者之后不存在"拒绝"这个态，也就不存在"因为压不短而丢内容"。
      final l2Wins = CompactionEngine.summarySideWins(groupSum, l2.tokens);
      // 只要输入里有一条的内容是**它自己的原文**（verbatimAtLevel），这一级也标成
      // verbatimAtLevel：渲染仍走原文路径，工具块与思考块一个不少。不这么传的话，
      // 一条"内容是原文"的一级被合成进二级之后，就会被当成一段纯文本发出去。
      final l2IsVerbatim = candGroup.any((e) => e.seg.verbatimAtLevel);
      final l2Text =
          l2Wins ? l2.text : candGroup.map((e) => e.text).join('\n\n');
      final l2Tokens = l2Wins ? l2.tokens : groupSum;
      final mergedMsgs = candGroup.expand((e) => e.seg.messages).toList();
      final l2seg = CompactionSegment(
          messages: mergedMsgs,
          summary: true,
          level: 2,
          verbatimAtLevel: l2IsVerbatim,
          l2SubSpans:
              candGroup.map((e) => CompactionEngine.segmentSpan(e.seg)).toList());
      final l2Entry =
          (seg: l2seg, text: l2Text, tokens: l2Tokens, isClosed: false);
      // 这一级的内容是它自己的原文（verbatimAtLevel）时不落盘，理由与 level-1 那一侧
      // 相同：写进去的话下一趟会被当成一条普通二级摘要加载，就有可能被文本化渲染。
      if (dbOpen &&
          !l2IsVerbatim &&
          mergedMsgs.isNotEmpty &&
          mergedMsgs.first.seq != null && mergedMsgs.last.seq != null) {
        final lo = mergedMsgs.first.seq!;
        final hi = mergedMsgs.last.seq!;
        try {
          await _summaryNodeRepo.materialize(
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
            model: agentType.model,
            coveredMinSeq: lo,
            coveredMaxSeq: hi,
          );
        } catch (e) {
          persistFailed = true;
          debugPrint('[AliasAgent] persist level-2 summary failed: $e');
        }
      }
      if (sentAsSummary(l2Entry)) {
        // 够远 ⇒ 这一组 1 级由它顶替（同一段只有一种表示）。
        table = [
          ...table.sublist(0, candStart),
          l2Entry,
          ...table.sublist(candStart + candCount),
        ];
      } else {
        // 还不够远 ⇒ 这一趟先不拿它顶替：它盖住的 1 级继续按各自的距离决定怎么发
        // （更细、多花一点 token，但不重复、也不提前顶替）。合成与落盘照做 —— 用户
        // 钉死的是"阈值到了就做合成"，这里改的只是"什么时候对模型换成摘要"。
        // 标记成已提交，避免同一组在本趟被反复送去合成。
        for (final e in candGroup) {
          attempted.add(e);
        }
      }
      total = projectedTotal(table);
    }
    // Residual-over-capacity detection: the loop can exit because nothing is left
    // to roll up or drop. If what remains (a frozen level-2 from an earlier round
    // plus the newest verbatim span, both excluded from dropping) still exceeds the
    // capacity, the projection is sent over it. This is the acknowledged
    // pathological "known limit"; surface it rather than hide it.
    if (total > maxContextTokens) {
      debugPrint('[AliasAgent] compaction projection still over budget by '
          '${total - maxContextTokens} tokens (frozen level-2 summaries + newest '
          'verbatim alone exceed maxContextTokens; sending best-effort projection — '
          'a pathological known limit)');
    }

    // Phase C —— 按时间顺序拼出这条投影的时间线，一段内容只用一种表示：
    //  - 表里剩下的条目：够远的发摘要；还不够远的（它自己那一档还没轮到）发原文；
    //  - 计划里还没被任何摘要盖住的原文段（含尾部）：原样发；
    //  - 其余的摘要段：这一趟什么都不发（已经被更粗的那条顶替，或者因为容量被拿掉）。
    //    按容量拿掉的**只可能是二级摘要**（判据见 `CompactionEngine.mayBeLeftOut`）——
    //    一级摘要与原文一条都不许拿；把所有二级都拿光还是装不下时，投影直接超预算
    //    发出去，那句 `compaction projection still over budget by …` 就是这时候打印的
    //    （它的条件是 `total > maxContextTokens`，与"这一趟有没有丢过东西"无关；
    //    `generate == false` 时整个收拢循环不跑，也不会打印）。
    final pieces = <({int at, ProjectionPiece piece})>[];
    final finalSummaries = <SummaryResult>[];
    // 位置按消息在历史里的下标算：seq 允许为空（合成测试的历史就没有 seq），位置永远在。
    final posOf = Map<Message, int>.identity();
    for (var i = 0; i < history.length; i++) {
      posOf[history[i]] = i;
    }
    int startPos(List<Message> msgs) =>
        msgs.isEmpty ? -1 : (posOf[msgs.first] ?? -1);

    for (final e in table) {
      if (e.seg.messages.isEmpty) continue;
      final at = startPos(e.seg.messages);
      // `verbatimAtLevel` 的条目**永远按原文发**：这一级的内容本来就是它自己的原文
      // （压缩后不比压缩前短，"取小者"取中了压缩前那一侧），不许因为"够远了"就改发一段
      // 文本 —— 那会把那段里的 tool_use / tool_result / thinking 块换成文字。
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
              segment: CompactionSegment(
                  messages: e.seg.messages, summary: false)),
        ));
      }
    }
    for (final seg in plan.segments) {
      if (seg.summary || seg.messages.isEmpty) continue;
      pieces.add((at: startPos(seg.messages), piece: ProjectionPiece(segment: seg)));
    }
    pieces.sort((a, b) => a.at - b.at);

    // 时间线上相邻的原文段合成一段：`_buildApiMessages` 一次处理一段连续的原文，
    // 顺带避免同一条 tool_use 被两段各发一遍。
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

    // Consume the dirty watermark ONLY if every stale span was re-summarized AND
    // persisted in this pass. If any materialize write failed, the stale cached
    // node is still on disk; clearing the watermark would make the next refold
    // reuse it (dirtySince==0 short-circuits the reuse gate), hiding real
    // staleness. So on a write failure we keep the watermark (recomputed next turn).
    if (dbOpen && !persistFailed) {
      try {
        await _summaryNodeRepo.clearDirty(sessionId);
      } catch (e) {
        debugPrint('[AliasAgent] clear dirty watermark failed: $e');
      }
    }
    return (timeline: orderedTimeline, summaries: finalSummaries);
  }

  /// Extract the summary text from a stored summary_json block document.
  /// 把库里已落盘的摘要节点读成"参考上下文候选"（纯数据，本变更新增）。库没打开
  /// 或读失败 ⇒ 空列表 ⇒ 这条路径退化成今天的行为（请求里不加参考）。读的是**快照**：
  /// 同一趟里后面才压出来的摘要不会进前面几段的参考。
  Future<List<SummaryReference>> _loadReferenceCandidates(
      String sessionId, bool dbOpen) async {
    if (!dbOpen) return const [];
    try {
      final nodes = await _summaryNodeRepo.queryBySession(sessionId);
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
      // 参考只是"读得懂前文"的辅助手段，读不到就按今天的方式压（绝不因此中断折叠）。
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

  /// Build the compacted projection from its TIMELINE: summary entries and raw
  /// spans in the order they happened — oldest → newest, and they interleave
  /// (a span too near to be summarized yet is sent as raw text even when older
  /// spans are already summarized).
  ///
  /// Role alternation: every summary is emitted as role:user text (with its own
  /// marker). Raw spans are replayed via [_buildApiMessages]. To keep the request
  /// from carrying two consecutive role:user messages — DeepSeek does NOT document
  /// same-role merging, so user,user would be fragile — a summary's text blocks are
  /// merged INTO the next raw span when that span starts on a user turn; only when
  /// there is no such span (nothing after it, or the span starts on an assistant
  /// message) does the summary get a role:user message of its own.
  List<Map<String, dynamic>> _buildCompactionProjection(
      List<ProjectionPiece> timeline) {
    final out = <Map<String, dynamic>>[];
    // Summary text blocks that have not been placed yet (they belong just before
    // the next raw span).
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
          // 并进这段原文的第一条 user 消息：既不丢摘要，也不产生相邻的 role:user。
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

  /// Build API conversation messages from persisted Message objects,
  /// reconstructing tool_use content blocks and synthetic tool_result messages.
  /// Build the API conversation from persisted [messages], reconstructing
  /// tool_use blocks + synthetic tool_result user messages.
  ///
  /// A tool round is emitted EXACTLY ONCE per tool_use_id: an assistant message
  /// carries its own tool calls (`turnToolCalls`), and — in the persisted history —
  /// the turn's FINAL assistant redundantly re-carries the accumulated `allTurnToolCalls`
  /// (a superset). Without deferring to the first owner, `_buildApiMessages` would
  /// synthesize the same tool_use_id / tool_result twice (an invalid request). So
  /// only the FIRST (oldest) assistant to carry a tool_use_id emits its tool_use
  /// block + its tool_result; later duplicates are skipped. This is also why a
  /// content-empty tool-call assistant must be retained in the message list: it is
  /// the first owner of its tool calls, so the round (and its tool_use input, a
  /// re-execution key) reaches the model and the summarizer.
  List<Map<String, dynamic>> _buildApiMessages(List<Message> messages) {
    final apiMessages = <Map<String, dynamic>>[];
    final emittedToolUseIds = <String>{};
    for (final msg in messages) {
      final content = <Map<String, dynamic>>[
        {'type': 'text', 'text': msg.content},
      ];

      // If assistant message has thinking blocks, prepend them before text
      if (msg.role == 'assistant' &&
          msg.thinkingJson != null &&
          msg.thinkingJson!.isNotEmpty) {
        try {
          final thinkingBlocks =
              jsonDecode(msg.thinkingJson!) as List<dynamic>;
          // Strip any persisted index keys (9.2) — old rows may carry them
          content.insertAll(0,
              thinkingBlocks.map((b) => _thinkingBlockWithoutIndex(
                  b as Map<String, dynamic>)));
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse thinkingJson: $e');
        }
      }

      // Determine which tool calls this assistant OWNS (its first occurrence of
      // each id). A duplicate id carried by a later assistant is NOT re-emitted.
      var ownedToolCalls = const <Map<String, dynamic>>[];
      if (msg.role == 'assistant' &&
          msg.toolCallsJson != null &&
          msg.toolCallsJson!.isNotEmpty) {
        try {
          final toolCalls = jsonDecode(msg.toolCallsJson!) as List<dynamic>;
          ownedToolCalls = <Map<String, dynamic>>[];
          for (final tc in toolCalls) {
            final id = ((tc as Map<String, dynamic>)['id'] ?? '').toString();
            // Empty id is treated as always-unique (never deduped wrongly).
            if (id.isEmpty || emittedToolUseIds.add(id)) {
              ownedToolCalls.add(tc);
            }
          }
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse toolCallsJson: $e');
          ownedToolCalls = const [];
        }
      }

      // If assistant message has tool calls, add tool_use blocks (owned only)
      for (final tc in ownedToolCalls) {
        content.add({
          'type': 'tool_use',
          'id': tc['id'] ?? '',
          'name': tc['toolName'] ?? tc['name'] ?? '',
          'input': tc['input'] ?? {},
        });
      }

      apiMessages.add({
        'role': msg.role,
        'content': content,
      });

      // If assistant message owns tool calls, add synthetic tool_result user message
      if (ownedToolCalls.isNotEmpty) {
        try {
          final toolResults = <Map<String, dynamic>>[];
          for (final tc in ownedToolCalls) {
            final rawBody = (tc['result'] ?? tc['resultPreview'] ?? '').toString();
            final tcInput = (tc['input'] as Map<String, dynamic>?) ?? const {};
            final toolName = (tc['toolName'] ?? tc['name'] ?? '').toString();
            // 再取入口按**可用输入**拼（fix-silent-truncation 的 5.1）：
            //   ① 有 `path` 用 `path`（读文件类工具走这条）；
            //   ② 否则有 `url` 用 `url`（`web_fetch` 只有 url —— 以前这里给了个空的
            //      refetch，模型知道中间没了却拿不回来）；
            //   ③ 两者都没有就明说取不回，不留空。
            final refetchPath = (tcInput['path'] as String?) ?? '';
            final refetchUrl = (tcInput['url'] as String?) ?? '';
            final refetchArg = refetchPath.isNotEmpty
                ? refetchPath
                : (refetchUrl.isNotEmpty ? refetchUrl : '');
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': tc['id'] ?? '',
              // Near-zone oversized tool_result body elision (spec "Near-zone
              // oversized tool_result body elision"): a verbatim tool_result whose
              // body is extremely large is elided to a truncation marker + refetch
              // record (path/bytes), preserving the tool_use block, the tool_result
              // placement, and the round structure. Never folds/splits the round;
              // full body stays on disk and is recoverable via the tool+path.
              'content': _elideOversizedToolResult(
                name: toolName, path: refetchArg, body: rawBody),
            });
          }
          apiMessages.add({
            'role': 'user',
            'content': toolResults,
          });
        } catch (e) {
          debugPrint('[AliasAgent] Failed to build tool_results: $e');
        }
      }
    }
    return apiMessages;
  }

  /// Body size threshold above which a verbatim tool_result is treated as
  /// "extremely large" and elided (near-zone). A normal tool_result is a few
  /// thousand chars; beyond ~8K chars the model gains little from the full body
  /// and the body dominates the request, so it is elided to a head/tail preview +
  /// marker + refetch record (D10 "近端超大 tool_result 正文…截断标记+再取记录").
  ///
  /// 定义在 `search_text_assembly.dart`（本文件只 re-export 这个名字给内部用）。
  static const int kToolResultElisionThreshold = searchTextElisionThreshold;

  /// Elide an oversized tool_result BODY (near-zone elision). Keeps a head/tail
  /// preview (~the threshold total) + a truncation marker recording the original
  /// byte length + the refetch path, so the round stays a valid tool_use/
  /// tool_result pair and the full body is recoverable via the tool + path
  /// (never deleted, D9). Under the threshold the body is passed through intact.
  ///
  /// 阈值常量住在 `lib/services/search_text_assembly.dart`（`kToolResultElisionThreshold`）：
  /// 搜索结果那段拼装也用它当预算，两处**只留一份定义**，结构上不会漂移。
  static String _elideOversizedToolResult({
    required String name,
    required String path,
    required String body,
  }) {
    if (body.length <= kToolResultElisionThreshold) return body;
    final half = kToolResultElisionThreshold ~/ 2;
    final head = body.substring(0, half);
    final tail = body.substring(body.length - half);
    // 再取记录：有可用的入参就给一条**能照抄**的动作；一个都没有就明说取不回，
    // 不许留空（留空等于告诉模型"中间没了"却不给它办法）。
    final refetch = path.isNotEmpty
        ? '; refetch via $name "$path"'
        : '; 本篇无法自动再取，请重新给出地址后再试';
    return '$head\n...[truncated middle of ${body.length - 2 * half} chars]...\n$tail'
        '\n[tool_result body elided: ${body.length} chars > threshold '
        '$kToolResultElisionThreshold$refetch]';
  }

  /// `edit_file` 模型可见文本的尾巴：`— 第 12、40 行`。
  ///
  /// 行号清单本身也受 [kToolResultElisionThreshold] 约束：超过它时只列前几条，
  /// 并写明共几处、其余去哪看——砍内容必须可见、可见之后必须可取回。
  static String _editLineSuffix(List<dynamic> hunks) {
    final lines = <int>[];
    for (final hunk in hunks) {
      if (hunk is! Map) continue;
      final line = (hunk['start_line'] as num?)?.toInt();
      if (line != null && line > 0 && !lines.contains(line)) lines.add(line);
    }
    if (lines.isEmpty) return '';
    final full = ' — 第 ${lines.join('、')} 行';
    if (full.length <= kToolResultElisionThreshold) return full;
    final note = ' — 共 ${lines.length} 处改动，其余行号见卡片';
    final budget =
        kToolResultElisionThreshold - note.length - ' — 第  行'.length;
    final shown = <int>[];
    var used = 0;
    for (final line in lines) {
      final added = (shown.isEmpty ? 0 : 1) + '$line'.length;
      if (used + added > budget) break;
      shown.add(line);
      used += added;
    }
    if (shown.isEmpty) return note;
    return ' — 第 ${shown.join('、')} 行$note';
  }

  /// 把 sidecar 返回的 hunks 转成活动对象用的形态；不可用时给 null。
  static List<EditHunk>? _parseEditHunks(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    final hunks = <EditHunk>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final line = (item['start_line'] as num?)?.toInt();
      final oldText = item['old_text'];
      final newText = item['new_text'];
      if (line == null || oldText is! String || newText is! String) continue;
      hunks.add(EditHunk(startLine: line, oldText: oldText, newText: newText));
    }
    return hunks.isEmpty ? null : hunks;
  }

  /// Execute a tool call. Returns a JSON-like result map.
  /// Async because web_search/web_fetch run on worker isolates (tasks 8.3a, 8.5).
  Future<Map<String, dynamic>> _executeTool(Map<String, dynamic> toolCall) async {    final name = toolCall['name'] as String?;
    final input = (toolCall['input'] as Map<String, dynamic>?) ?? {};
    final path = (input['path'] as String?) ?? '';

    String resultJson;
    switch (name) {
      case 'read_file':
        // Build JSON request with optional offset/limit
        final readReq = <String, dynamic>{'path': path};
        final offset = input['offset'];
        final limit = input['limit'];
        if (offset is int) readReq['offset'] = offset;
        if (limit is int) readReq['limit'] = limit;
        resultJson = _sidecar.readFile(jsonEncode(readReq));
      case 'write_file':
        resultJson = _sidecar.writeFile(jsonEncode({
          'path': path,
          'content': input['content'] ?? '',
        }));
      case 'edit_file':
        final edits = input['edits'];
        if (edits is! List || edits.isEmpty) {
          resultJson = '{"ok":false,"error":"edits must contain at least one replacement"}';
        } else {
          resultJson = _sidecar.editFile(jsonEncode({'path': path, 'edits': edits}));
        }
      case 'list_dir':
        resultJson = _sidecar.listDir(path);
      case 'glob_file':
        resultJson = _sidecar.globFile(jsonEncode({
          'pattern': input['pattern'] ?? '',
          'max_results': input['max_results'] ?? 200,
        }));
      case 'grep_file':
        resultJson = _sidecar.grepFile(jsonEncode({
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
        resultJson = await _sidecar.webSearch(request);
      case 'web_fetch':
        final request = jsonEncode({
          'url': input['url'] ?? '',
        });
        resultJson = await _sidecar.webFetch(request);
      case 'browser_navigate':
        resultJson = await _sidecar.browserNavigate(jsonEncode({
          'url': input['url'] ?? '',
        }));
      case 'browser_click':
        resultJson = await _sidecar.browserClick(jsonEncode({
          'selector': input['selector'] ?? '',
        }));
      case 'browser_type':
        resultJson = await _sidecar.browserType(jsonEncode({
          'selector': input['selector'] ?? '',
          'text': input['text'] ?? '',
        }));
      case 'browser_snapshot':
        resultJson = await _sidecar.browserSnapshot(jsonEncode({}));
      case 'run_command':
        // 命令工具（add-command-tool）：四个配置值随每次调用一起传到执行侧，
        // 执行侧不读配置文件（design 决策 7）。缺省值在这里补一份，与 C++ 侧一致。
        final cmdCfg = registry.lookup('general');
        final request = <String, dynamic>{
          'command': input['command'] ?? '',
        };
        if (input['workdir'] is String &&
            (input['workdir'] as String).isNotEmpty) {
          request['workdir'] = input['workdir'];
        }
        request['timeout_ms'] =
            (input['timeout_ms'] as int?) ?? cmdCfg?.commandTimeoutMs ?? 120000;
        request['max_timeout_ms'] = cmdCfg?.commandMaxTimeoutMs ?? 600000;
        request['max_output_chars'] = cmdCfg?.commandMaxOutputChars ?? 8000;
        request['full_output_chars'] = cmdCfg?.commandOutputFullChars ?? 2000000;
        resultJson = await _sidecar.runCommand(jsonEncode(request));
      case 'get_current_time':
        final now = DateTime.now();
        final dt = now.toIso8601String();
        final date = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        final tz = now.timeZoneOffset;
        final tzStr = '${tz.isNegative ? '-' : '+'}${tz.inHours.abs().toString().padLeft(2, '0')}:${tz.inMinutes.abs().remainder(60).toString().padLeft(2, '0')}';
        resultJson = jsonEncode({
          'ok': true,
          'datetime': dt,
          'date': date,
          'time': time,
          'timezone': tzStr,
          'content': 'Current time: $date $time $tzStr',
        });
      default:
        resultJson = '{"ok":false,"error":"Unknown tool: $name"}';
    }

    try {
      final parsed = jsonDecode(resultJson) as Map<String, dynamic>;
      // Format tool results for display
      if (name == 'web_search' || name == 'web_fetch') {
        parsed['content'] = _formatSearchResultForDisplay(name!, parsed);
      } else if (name == 'browser_navigate' ||
          name == 'browser_click' ||
          name == 'browser_type' ||
          name == 'browser_snapshot') {
        // Model-facing content = the page's text snapshot (plus url/title and a
        // divergence note). The per-call counters stay in sidecar.log, NOT here.
        final snap = (parsed['snapshot'] as String?) ?? '';
        final url = (parsed['url'] as String?) ?? '';
        final title = (parsed['title'] as String?) ?? '';
        final note = (parsed['divergent'] == true)
            ? (parsed['note'] as String? ?? '')
            : '';
        final sb = StringBuffer();
        if (title.isNotEmpty) sb.writeln(title);
        if (url.isNotEmpty) sb.writeln(url);
        if (note.isNotEmpty) sb.writeln(note);
        sb.write(snap);
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no page text captured)'
            : sb.toString().trim();
      } else if (name == 'run_command') {
        // 模型看到的是"正文 + 可选的 stderr + 状态标记"，不是原始 JSON。
        // 顺序有讲究：截断说明与全文路径必须留在结果里（它们可能紧跟在被截断的
        // 尾部之后），而整段结果要落在 kToolResultElisionThreshold 之内 —— 工具
        // 侧的上限取 8000 就是为了这件事，见 agent_type_config.dart 的注释。
        final sb = StringBuffer();
        final outText = (parsed['stdout'] as String?) ?? '';
        final errText = (parsed['stderr'] as String?) ?? '';
        if (outText.trim().isEmpty && errText.trim().isEmpty) {
          sb.writeln('(no output)');
        } else {
          if (outText.isNotEmpty) sb.write(outText.endsWith('\n') ? outText : '$outText\n');
          if (errText.isNotEmpty) {
            sb.writeln('[stderr]');
            sb.write(errText.endsWith('\n') ? errText : '$errText\n');
          }
        }
        final paths = parsed['full_output_paths'];
        if (paths is Map) {
          for (final entry in paths.entries) {
            sb.writeln('[output truncated; full output: ${entry.value}]');
          }
        }
        if (parsed['timed_out'] == true) {
          sb.writeln('[timed out after ${(parsed['duration_ms'] ?? 0)}ms]');
        }
        final exitCode = parsed['exit_code'];
        if (exitCode is int && exitCode != 0) {
          sb.writeln('[exit code: $exitCode]');
        }
        parsed['content'] = sb.toString().trimRight();
      } else if (name == 'write_file') {
        final bytes = parsed['bytes_written'] as int? ?? 0;
        final created = parsed['created'] as bool? ?? false;
        final p = (parsed['path'] as String?) ?? path;
        parsed['content'] = created
            ? 'Created $p ($bytes bytes)'
            : 'Wrote $p ($bytes bytes)';
      } else if (name == 'edit_file') {
        final reps = parsed['replacements'] as int? ?? 0;
        final matchedWith = parsed['matched_with'] as String?;
        var content = 'Edited $path ($reps replacement${reps == 1 ? '' : 's'})';
        if (matchedWith != null) content += ' — matched with $matchedWith';
        final hunks = parsed['hunks'];
        if (parsed['ok'] == true && hunks is List) {
          content += _editLineSuffix(hunks);
        }
        parsed['content'] = content;
      } else if (name == 'glob_file') {
        // Model-facing content: one relative path per line. Show the full
        // requested result set (C++ already bounds paths to max_results) — a
        // smaller hard cap would silently drop results without a marker.
        final maxResults = (input['max_results'] as int?) ?? 200;
        final paths = parsed['paths'] as List? ?? [];
        final truncated = parsed['truncated'] == true;
        final sb = StringBuffer();
        for (final p in paths.take(maxResults)) {
          sb.writeln(p);
        }
        if (truncated) {
          // 截断要**可恢复**（fix-silent-truncation 8.3）：说清本次给了几条，并给一个能
          // 直接照抄的取回写法。**不写"of <count>"** —— C++ 侧收满 max_results 就掐断了
          // rg，`count` 因此等于本次条数、**不是**总条数，写成"showing N of N"等于编一个总数。
          sb.writeln('... (truncated: only the first $maxResults entries are shown; '
              'to get more, call glob_file again with max_results=${maxResults * 2})');
        }
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no files matched)'
            : sb.toString().trim();
      } else if (name == 'grep_file') {
        // Model-facing content: "path:line: text" per match. Show the full
        // requested result set; only strip the trailing newline rg adds, not
        // leading indentation (which is meaningful in code lines).
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
          // 同 glob_file：说清本次给了几条 + 可照抄的取回写法；同样不声称总条数。
          sb.writeln('... (truncated: only the first $maxResults matches are shown; '
              'to get more, call grep_file again with max_results=${maxResults * 2}, '
              'or narrow the pattern/glob)');
        }
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no matches)'
            : sb.toString().trim();
      }
      return parsed;
    } catch (e) {
      debugPrint('[AliasAgent] _executeTool parse error: $e');
      return {'ok': false, 'error': 'Failed to parse tool result'};
    }
  }

  /// Format search/fetch results into a human-readable string for tool card display (task 8.9).
  ///
  /// `web_search` 的正文由 [assembleSearchText] 拼（单独一个文件，便于单测传小预算
  /// 逼出"预览被省略"那一支）；这里只负责把它接上。
  String _formatSearchResultForDisplay(String toolName, Map<String, dynamic> result) {
    if (result['ok'] != true) {
      // Error — use the error message directly
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
      buf.write(content.length > 2000 ? '${content.substring(0, 2000)}...' : content);
    }

    return buf.toString().trimRight();
  }

  /// Build structured result sections from raw tool result JSON (for ToolCallCard UI).
  /// Returns empty list for no results; returns null only when called on non-search tools.
  List<ResultSection> _buildResultSections(String toolName, Map<String, dynamic> result) {
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
      final displayTitle = pageTitle.isNotEmpty ? pageTitle : (pageUrl.isNotEmpty ? pageUrl : 'Fetched page');
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

  /// Remove streaming indicator only; tool call cards and persistent messages persist.
  /// Also cancels any in-flight C++ request (D7): the session switch / new chat
  /// / timeout paths must truly terminate the previous request instead of
  /// letting it stream into the next one (F1 fix — the Dart serialization gate
  /// in SidecarBridge then releases once the cancelled done is delivered).
  /// On the error/cancel path, residual streaming ChatThinkingItems are
  /// transitioned to done (9.1): otherwise the animated dots run forever AND a
  /// later turn's thinking_delta with the same index would match the stale
  /// card (cross-turn index collision violating the chat-ui spec).
  void _endStreaming() {
    _sidecar.cancelRequest();
    if (!mounted) return;
    setState(() {
      _isStreaming = false;
      _chatItems.removeWhere((i) => i is ChatStreamingItem);
      for (int i = 0; i < _chatItems.length; i++) {
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
    });
  }

  Future<void> _storeError(String message, {required String sessionId}) async {
    final errorMsg = await _msgRepo.insert(
      sessionId: sessionId,
      role: 'assistant',
      content: 'Error: $message',
    );
    await _sessionRepo.touch(sessionId);
    if (mounted) {
      setState(() {
        if (_currentId == sessionId) {
          _chatItems.add(ChatMessageItem(errorMsg, isFinalReply: true));
        }
      });
    }
  }

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
        ),
        const VerticalDivider(width: 1),
        Expanded(
          // (3.2) Wrap the view area in a Column: a small toolbar at top toggles
          // between the original conversation view and the real context view
          // (task 3.2 / design D6). The default remains the conversation view.
          child: Column(
            children: [
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
                        compactionStatus: _compactionStatus,
                      )
                    : ContextView(
                        snapshot: _contextSnapshot,
                        compactionStatus: _compactionStatus,
                      ),
              ),
              // 10.1：输入行在两屏之外（`Expanded` 之后、同一个 Column 里），所以切到
              // 「真实上下文」那一屏时输入框与发送按钮仍在 —— 占用环跟着它一起留下。
              InputBar(
                controller: _inputCtrl,
                onSubmit: _submitInput,
                toolsReady: _toolsReady,
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
