import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/agent_type_config.dart';
import 'models/app_config.dart';
import 'models/chat_item.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'models/tool_call_activity.dart';
import 'services/agent_type_registry.dart';
import 'services/compaction/compaction_plan.dart';
import 'services/compaction/guard_anchors.dart';
import 'services/compaction/model_summary_provider.dart';
import 'services/compaction/seam_selector.dart';
import 'services/compaction/summary_provider.dart';
import 'services/config_service.dart';
import 'services/context_snapshot.dart';
import 'services/database_service.dart';
import 'services/message_repository.dart';
import 'services/provider_resolver.dart';
import 'services/session_repository.dart';
import 'services/sidecar_bridge.dart';
import 'services/summary_node_repository.dart';
import 'ui/chat_area.dart';
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
  late final Map<String, Map<String, dynamic>> _toolDefs;

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
    _summaryNodeRepo = SummaryNodeRepository();
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
  void _initSearchAndTools() {
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
    };

    // Initialize search infra from config (task 8.2)
    try {
      final searchConfig = widget.config.search;
      final searchJson = searchConfig != null && searchConfig.isNotEmpty
          ? jsonEncode(searchConfig)
          : '{}';
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
    if (maxContextTokens > 0) {
      // D10 cost discipline: a session that exhausted its fold budget skips ALL
      // on-demand compaction — INCLUDING the seam-chooser LLM call, which would
      // otherwise fire before the budget check and remain unbounded — and sends
      // verbatim (best-effort over-budget known limit), so it cannot pay unbounded
      // fold-related LLM cost per turn. The seam call is a real /v1/messages call
      // (seam_selector.dart) and is NOT counted in the fold-budget token proxy.
      if (await _foldBudgetExceeded(sessionId)) {
        debugPrint('[AliasAgent] fold budget exceeded for session $sessionId — '
            'skipping on-demand fold, sending verbatim (best-effort)');
        apiMessages = _buildApiMessages(messages);
      } else {
        final closed = await _loadClosedSegments(sessionId);
        // 4.3 design D5 option A: when a seam selector is available, prefetch/memoize
        // the LLM L1 topic seams for the current fold BEFORE building the plan, then
        // pass a memo-backed L1SeamChooser. A seam failure degrades gracefully to the
        // arithmetic-safe skeleton (never splits a tool round, never blocks the turn).
        final seamChooser =
            await _prepareSeamChooser(messages, closed, agentType, maxContextTokens);
        final plan = CompactionEngine.buildTree(
            history: messages,
            maxContextTokens: maxContextTokens,
            closed: closed,
            seamChooser: seamChooser);
        if (plan.shouldCompact) {
          ({List<CompactionSegment> segments, List<SummaryResult> summaries}) resolved =
              (segments: const [], summaries: const []);
          try {
            resolved = await _resolveSummaries(
                sessionId, plan, agentType, maxContextTokens);
          } catch (e) {
            // Summarization failed — never silently replace the folded context with
            // a placeholder. Fall back to sending the conversation verbatim.
            debugPrint('[AliasAgent] compaction summary failed, sending verbatim: $e');
            resolved = (segments: const [], summaries: const []);
          }
          if (resolved.segments.isEmpty) {
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
            // segments carries the (measure→adjusted) summary segments + the verbatim
            // tail; summaries may be empty after an omit-most-of-the-far, in which
            // case _buildCompactionProjection sends only the verbatim tail (the older
            // omitted content stays on disk, D9).
            apiMessages = _buildCompactionProjection(resolved.summaries, resolved.segments);
          }
        } else {
          apiMessages = _buildApiMessages(messages);
        }
      }
    } else {
      // maxContextTokens not configured — keep the current full-send behavior.
      apiMessages = _buildApiMessages(messages);
    }

    // Track all tool calls across turns for final assistant message
    final allTurnToolCalls = <Map<String, dynamic>>[];

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
      assistantBlocks.addAll(turnToolCalls);

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
      int maxContextTokens, {bool Function()? isAborted}) async {
    if (_seamSelector == null) return null;
    final seamInputs = CompactionEngine.resolveFoldSeamInputs(
        history: history, maxContextTokens: maxContextTokens, closed: closed);
    if (seamInputs == null) return null;
    final seamSel = _seamSelector;
    // 2.6 abort gate: the seam ensure makes its own model call (SeamSelector.ensure
    // -> a real sendMessage on the single-slot _chain). A preempted background fold
    // must NOT enqueue it ahead of the user's request. Inline send path passes null.
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled('background fold aborted before seam selection');
    }
    try {
      await seamSel.ensure(
          far: seamInputs.far, k: seamInputs.k, config: agentType);
      return (far, k) => seamSel.memoizedSeams(far: far, k: k) ?? const [];
    } catch (e) {
      debugPrint('[AliasAgent] seam selection failed, using arithmetic skeleton: $e');
      return null;
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
      final closed = await _loadClosedSegments(sessionId);
      // D10 cost discipline: a session that has exhausted its fold budget stops
      // auto-folding (best-effort) so a runaway session cannot spend unbounded
      // summarization cost. Logged as a debug/replay view (not user-facing).
      if (await _foldBudgetExceeded(sessionId)) return;
      // Durable resume point (D8 progressive closure) = the persisted `closed`
      // segments passed into buildTree; the top closed seq is only logged for
      // observability (there is no separate in-memory checkpoint control value).
      final topClosedMax = closed.isEmpty
          ? 0
          : closed.map((c) => c.coveredMaxSeq).reduce((a, b) => a > b ? a : b);
      final seamChooser = await _prepareSeamChooser(messages, closed, agentType,
          maxContextTokens, isAborted: () => _foldGen != myGen);
      final plan = CompactionEngine.buildTree(
          history: messages,
          maxContextTokens: maxContextTokens,
          closed: closed,
          seamChooser: seamChooser);
      if (!plan.shouldCompact) {
        debugPrint('[AliasAgent] background fold: conversation within budget, '
            'nothing to fold (top closed seq=$topClosedMax) -> no-op');
        return;
      }
      final resolved = await _resolveSummaries(
          sessionId, plan, agentType, maxContextTokens,
          isAborted: () => _foldGen != myGen);
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

  /// Per-session fold budget caps (D10 cost discipline, "折卷次数/token 上限").
  /// These bound how much a single session is allowed to spend on folding — a
  /// cost guard, visible only via logs (a debug/replay view), NOT a user-facing
  /// "manage compression" control. A normal session folds a handful of times
  /// over its life; the caps are set generously so they only trip on runaway
  /// folding, then the session reverts to best-effort (sends verbatim / at the
  /// known over-budget limit) rather than paying unbounded summarization cost.
  static const int kMaxFoldsPerSession = 30;
  static const int kMaxFoldTokensPerSession = 500000;

  /// Public cap getter so tests can reference the fold-budget limit.
  static int get maxFoldsPerSession => kMaxFoldsPerSession;
  static int get maxFoldTokensPerSession => kMaxFoldTokensPerSession;

  /// Pure fold-budget cap check (D10): a session exceeds its budget when it has
  /// folded more than [kMaxFoldsPerSession] times OR spent more than
  /// [kMaxFoldTokensPerSession] tokens. Exposed for deterministic unit tests;
  /// the widget path computes [foldCount]/[foldTokens] from the persisted nodes
  /// and calls this.
  static bool isFoldBudgetExceeded({required int foldCount, required int foldTokens}) =>
      foldCount > kMaxFoldsPerSession || foldTokens > kMaxFoldTokensPerSession;

  /// True when [sessionId] has exhausted its fold budget. Uses the persisted
  /// [SummaryNodeRepository.queryBySession] accounting (count of nodes + sum of
  /// their measured output `token_cost` as a monotonic proxy for fold cost —
  /// fold INPUT cost is not stored per-session, so the summary output size is
  /// the available bounded proxy). Hermetic tests (no DB) return false.
  Future<bool> _foldBudgetExceeded(String sessionId) async {
    if (!DatabaseService.isOpen) return false;
    try {
      final nodes = await _summaryNodeRepo.queryBySession(sessionId);
      var foldCount = 0;
      var foldTokens = 0;
      for (final n in nodes) {
        if (n.level >= 1 && n.tokenCost != null && n.tokenCost! > 0) {
          foldCount++;
          foldTokens += n.tokenCost!;
        }
      }
      if (isFoldBudgetExceeded(foldCount: foldCount, foldTokens: foldTokens)) {
        debugPrint('[AliasAgent] fold budget exceeded for session $sessionId: '
            '$foldCount folds / $foldTokens fold-tokens (cap '
            '$kMaxFoldsPerSession / $kMaxFoldTokensPerSession) — skipping auto-fold');
        return true;
      }
    } catch (e) {
      debugPrint('[AliasAgent] fold budget query failed: $e');
    }
    return false;
  }

  Future<List<ClosedSummary>> _loadClosedSegments(String sessionId) async {
    if (!DatabaseService.isOpen) return const [];
    try {
      final nodes = await _summaryNodeRepo.queryBySession(sessionId);
      // Prefer the COARSEST covering node for each span (R8-d). A coarsened
      // level-2 "summary of summaries" covers the same span as the level-1s it
      // rolled up; sorting by (coveredMinSeq ASC, coveredMaxSeq DESC, level DESC)
      // puts the covering coarser node FIRST, so the greedy non-overlap advance
      // below adopts it and subsumes the L1s — instead of skipping the L2 in favor
      // of the larger frozen L1s (which discarded the coarsening + inflated the
      // fold budget). Still yields D9 dense non-overlap.
      final sorted = nodes
          .where((n) =>
              n.level >= 1 &&
              n.summaryJson != null &&
              n.coveredMinSeq > 0)
          .toList()
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
        if (n.coveredMinSeq > lastMax) {
          picked.add(ClosedSummary(
            level: n.level,
            coveredMinSeq: n.coveredMinSeq,
            coveredMaxSeq: n.coveredMaxSeq,
            tokenCost: n.tokenCost ?? 0,
          ));
          lastMax = n.coveredMaxSeq;
        }
      }
      return picked;
    } catch (e) {
      debugPrint('[AliasAgent] closed segments load failed: $e');
      return const [];
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

  /// Summarize an OPEN level-1 batch with SPLIT-IF-INVALID (design D3/D4).
  ///
  /// A compression is valid ONLY if the produced summary's MEASURED token count
  /// (real `output_tokens`, ⑪.1) is LESS than the batch it replaced. If invalid,
  /// split the batch in half and recurse (deterministic — always terminates: the
  /// batch halves). If a single (atomic) batch still cannot compress, RETURN an
  /// empty list — the atomic batch is OMITTED from the projection (DATA KEPT on
  /// disk, D9), never sent as a summary larger than the content it replaced.
  Future<List<({CompactionSegment seg, String text, int tokens, bool isClosed})>>
      _resolveOpenLevel1(List<Message> msgs, AgentTypeConfig agentType,
          {bool Function()? isAborted, void Function(int minSeq, int maxSeq)? onOmit}) async {
    // 2.6 abort gate (split-if-invalid recursion makes its own model calls): a
    // preempted background fold must stop at the next model call rather than
    // enqueueing an un-cancelled summarize onto the single-slot _chain ahead of the
    // user's request. Checked at each recursion entry. Inline callers pass null.
    if (isAborted?.call() ?? false) {
      throw const _BackgroundFoldCancelled('background fold aborted during open-batch resolve');
    }
    if (msgs.isEmpty) return const [];
    final raw = CompactionEngine.rawTokens(msgs);
    final summary = await _summaryProvider.summarize(folded: msgs, config: agentType);
    if (summary.tokens < raw) {
      return [
        (seg: CompactionSegment(messages: msgs, summary: true, level: 1),
            text: summary.text, tokens: summary.tokens, isClosed: false),
      ];
    }
    // Invalid (summary ≥ batch raw): split the batch in half and recurse.
    if (msgs.length > 1) {
      final mid = msgs.length ~/ 2;
      return [
        ...await _resolveOpenLevel1(msgs.sublist(0, mid), agentType,
            isAborted: isAborted, onOmit: onOmit),
        ...await _resolveOpenLevel1(msgs.sublist(mid), agentType,
            isAborted: isAborted, onOmit: onOmit),
      ];
    }
    // Atomic batch that cannot compress — omit (never send a bloated summary).
    // DATA KEPT on disk (D9). But a stale span omitted here is NEITHER re-summarized
    // NOR re-persisted, so the caller must NOT consume the dirty watermark (R8-c) —
    // surface the omission so clearDirty is skipped (else next round reuses a stale
    // cached summary, R2-2 reuse-gate failure).
    if (onOmit != null && msgs.isNotEmpty) {
      onOmit(msgs.first.seq ?? 0, msgs.last.seq ?? 0);
    }
    return const [];
  }

  Future<({List<CompactionSegment> segments, List<SummaryResult> summaries})>
      _resolveSummaries(String sessionId, CompactionPlan plan,
          AgentTypeConfig agentType, int budget,
          {bool Function()? isAborted}) async {
    final dbOpen = DatabaseService.isOpen;
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
    for (final seg in plan.segments) {
      if (isAborted?.call() ?? false) {
        throw const _BackgroundFoldCancelled('background fold aborted between segments');
      }
      if (!seg.summary || seg.messages.isEmpty) continue;
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

      // OPEN level-1 batch: resolve with split-if-invalid (D3/D4). A summary is
      // valid ONLY if its MEASURED token count is less than the batch it replaced
      // (else split in half + recurse); an atomic batch that still cannot compress
      // is OMITTED from the projection (data kept on disk, D9) — never send a
      // bloat- > batch summary.
      final leafEntries = await _resolveOpenLevel1(seg.messages, agentType,
          isAborted: isAborted,
          // R8-c: if a STALE (dirty-reaching) span is omitted (un-compressible → not
          // re-summarized/persisted), do NOT consume the dirty watermark — else the
          // next fold reuses a stale cached summary. Mark persistFailed so the
          // clearDirty gate (below) is skipped.
          onOmit: (minSeq, maxSeq) {
            if (dirtySince > 0 && maxSeq >= dirtySince) persistFailed = true;
          });
      for (final leaf in leafEntries) {
        // Hermetic tests (no DB open) never persist the derived index.
        if (dbOpen && leaf.seg.messages.isNotEmpty &&
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

    // Phase B — fold→measure→adjust (⑪.3). Closed segments are FROZEN; only the
    // OPEN (tail) L1 batches are adjustable. Over budget → coarsen the OLDEST
    // open L1s into a level-2 "summary of summaries" (measured token > T) and
    // re-measure; when no coarsening would merge ≥2 → OMIT the oldest open.
    final closedEntries = entries.where((e) => e.isClosed).toList();
    var open = entries.where((e) => !e.isClosed).toList();
    final verbatimRaw = CompactionEngine.rawTokens(plan.verbatim);
    final closedSum = closedEntries.fold(0, (m, e) => m + e.tokens);
    var openSum = open.fold(0, (m, e) => m + e.tokens);
    final T = budget ~/ 2;
    var total = closedSum + openSum + verbatimRaw;
    while (total > budget && open.isNotEmpty) {
      if (isAborted?.call() ?? false) {
        throw const _BackgroundFoldCancelled('background fold aborted during coarsen');
      }
      // Never re-coarsen an existing level-2 into a new level-2: that would make
      // the new L2 a "summary of a summary + more L1s" (violates design D1 "只做两
      // 级 / L2 的输入是 L1 摘要文本") and persist overlapping level-2 rows. An
      // already-coarse L2 is handled by omission only.
      if (open[0].seg.level >= 2) {
        open.removeAt(0);
        openSum = open.fold(0, (m, e) => m + e.tokens);
        total = closedSum + openSum + verbatimRaw;
        continue;
      }
      // Prefer coarsening the OLDEST consecutive open L1s whose cumulative
      // measured tokens exceed T into ONE level-2 "summary of summaries".
      final l1Tokens = <int>[];
      var consecutiveL1 = 0;
      for (final e in open) {
        if (e.seg.level >= 2) break;
        l1Tokens.add(e.tokens);
        consecutiveL1++;
      }
      final groupCount = CompactionEngine.l2GroupCount(l1Tokens, T);
      if (consecutiveL1 >= 2 && groupCount >= 2) {
        final group = open.sublist(0, groupCount);
        final groupSum = group.fold(0, (m, e) => m + e.tokens);
        final l2 = await _summaryProvider.summarizeText(
            text: group.map((e) => e.text).join('\n\n'), config: agentType);
        if (l2.tokens >= groupSum) {
          // INVALID coarsen: the level-2 is NOT smaller than the L1 summaries it
          // would replace — the same "valid only if measured < replaced" criterion
          // split-if-invalid enforces for L1. A bloated L2 would INFLATE total, so
          // reject it and DRAIN (omit) the group's entries one-at-a-time, re-measuring
          // total, WITHOUT re-coarsening the same futile group — this avoids O(n)
          // fresh summarizeText calls while preserving the still-valid L1s (each omit
          // is projection-only; data kept on disk, D9).
          var drain = groupCount;
          while (drain > 0 && open.isNotEmpty && total > budget) {
            open.removeAt(0);
            drain--;
            openSum = open.fold(0, (m, e) => m + e.tokens);
            total = closedSum + openSum + verbatimRaw;
          }
        } else {
          final mergedMsgs = group.expand((e) => e.seg.messages).toList();
          final l2seg = CompactionSegment(
              messages: mergedMsgs,
              summary: true,
              level: 2,
              l2SubSpans:
                  group.map((e) => CompactionEngine.segmentSpan(e.seg)).toList());
          final l2Entry =
              (seg: l2seg, text: l2.text, tokens: l2.tokens, isClosed: false);
          if (dbOpen && mergedMsgs.isNotEmpty &&
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
                    {'type': 'text', 'text': l2.text},
                  ],
                }),
                tokenCost: l2.tokens,
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
          open = [l2Entry, ...open.sublist(groupCount)];
          openSum = open.fold(0, (m, e) => m + e.tokens);
        }
      } else {
        // Fully coarsened (no merge of ≥2 L1s) — OMIT the OLDEST open content from
        // the projection (data kept on disk, D9).
        open.removeAt(0);
        openSum = open.fold(0, (m, e) => m + e.tokens);
      }
      total = closedSum + openSum + verbatimRaw;
    }
    // Residual-over-budget detection (⑪ review finding): the loop exits on
    // `open.isEmpty`, NOT on `total <= budget`. If open is fully coarsened+omitted
    // and closedSum + verbatimRaw alone still exceeds budget (frozen closed
    // summaries + newest verbatim are both excluded from omission — D8 "闭段冻结"
    // and D3/D4 "最新始终 verbatim"), the projection is sent over budget. This is
    // the acknowledged pathological "known limit"; surface it rather than hide it.
    if (total > budget) {
      debugPrint('[AliasAgent] compaction projection still over budget by '
          '${total - budget} tokens (closed+verbatim alone exceed maxContextTokens; '
          'sending best-effort projection — a pathological known limit)');
    }

    final finalSegments = <CompactionSegment>[
      ...closedEntries.map((e) => e.seg),
      ...open.map((e) => e.seg),
      if (plan.verbatim.isNotEmpty)
        CompactionSegment(messages: plan.verbatim, summary: false),
    ];
    final finalSummaries = <SummaryResult>[
      ...closedEntries.map((e) => SummaryResult(text: e.text, tokens: e.tokens)),
      ...open.map((e) => SummaryResult(text: e.text, tokens: e.tokens)),
    ];

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
    return (segments: finalSegments, summaries: finalSummaries);
  }

  /// Extract the summary text from a stored summary_json block document.
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

  /// Build the compacted projection: leading role:user summary-prefix messages
  /// (one per summary segment, oldest → newest) followed by the near-verbatim
  /// span replayed via [_buildApiMessages]. If the verbatim span starts on a user
  /// turn, the LAST summary's marker+text is merged into that leading user
  /// message to keep valid role alternation (user,user would violate the schema).
  ///
  /// [segments] is the FINAL (measure→adjusted) segment list (⑪.3); summaries are
  /// aligned one-to-one with the summary segments, in order.
  List<Map<String, dynamic>> _buildCompactionProjection(
      List<SummaryResult> summaries, List<CompactionSegment> segments) {
    final summarySegs =
        segments.where((s) => s.summary && s.messages.isNotEmpty).toList();
    final verbatimMsg =
        segments.where((s) => !s.summary).expand((s) => s.messages).toList();
    final verbatim = _buildApiMessages(verbatimMsg);
    // Concatenate ALL summary segments into a SINGLE role:user prefix message
    // (one text block per segment, each with its own marker). This guarantees the
    // projection never emits consecutive role:user messages — DeepSeek does NOT
    // document same-role merging, so user,user would be fragile — keeping
    // role alternation valid.
    final summaryBlocks = <Map<String, dynamic>>[];
    for (var i = 0; i < summaries.length; i++) {
      final count = i < summarySegs.length ? summarySegs[i].messages.length : summaries.length;
      summaryBlocks.add({
        'type': 'text',
        'text': buildSummaryContent(
            result: summaries[i], foldedCount: count, level: summarySegs[i].level),
      });
    }
    final out = <Map<String, dynamic>>[];
    if (summaryBlocks.isNotEmpty) {
      if (verbatim.isNotEmpty && verbatim.first['role'] == 'user') {
        // Merge the summary blocks into the leading user message (preserves the
        // current user's text; avoids a leading user,user when the safe boundary
        // lands on a real user text).
        final content = (verbatim.first['content'] as List<Map<String, dynamic>>);
        content.insertAll(0, summaryBlocks);
        out.addAll(verbatim);
      } else {
        out.add({'role': 'user', 'content': summaryBlocks});
        out.addAll(verbatim);
      }
    } else {
      out.addAll(verbatim);
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
            final refetchPath = (tcInput['path'] as String?) ?? '';
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
                name: toolName, path: refetchPath, body: rawBody),
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
  static const int kToolResultElisionThreshold = 8000;

  /// Elide an oversized tool_result BODY (near-zone elision). Keeps a head/tail
  /// preview (~the threshold total) + a truncation marker recording the original
  /// byte length + the refetch path, so the round stays a valid tool_use/
  /// tool_result pair and the full body is recoverable via the tool + path
  /// (never deleted, D9). Under the threshold the body is passed through intact.
  static String _elideOversizedToolResult({
    required String name,
    required String path,
    required String body,
  }) {
    if (body.length <= kToolResultElisionThreshold) return body;
    final half = kToolResultElisionThreshold ~/ 2;
    final head = body.substring(0, half);
    final tail = body.substring(body.length - half);
    final refetch = path.isNotEmpty ? '; refetch via $name "$path"' : '';
    return '$head\n...[truncated middle of ${body.length - 2 * half} chars]...\n$tail'
        '\n[tool_result body elided: ${body.length} chars > threshold '
        '$kToolResultElisionThreshold$refetch]';
  }

  /// Execute a tool call. Returns a JSON-like result map.
  /// Async because web_search/web_fetch run on worker isolates (tasks 8.3a, 8.5).
  Future<Map<String, dynamic>> _executeTool(Map<String, dynamic> toolCall) async {
    final name = toolCall['name'] as String?;
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
        parsed['content'] = content;
      } else if (name == 'glob_file') {
        // Model-facing content: one relative path per line. Show the full
        // requested result set (C++ already bounds paths to max_results) — a
        // smaller hard cap would silently drop results without a marker.
        final maxResults = (input['max_results'] as int?) ?? 200;
        final paths = parsed['paths'] as List? ?? [];
        final count = parsed['count'] as int? ?? paths.length;
        final truncated = parsed['truncated'] == true;
        final sb = StringBuffer();
        for (final p in paths.take(maxResults)) {
          sb.writeln(p);
        }
        if (truncated) sb.writeln('... (truncated, showing ${paths.length} of $count)');
        parsed['content'] = sb.toString().trim().isEmpty
            ? '(no files matched)'
            : sb.toString().trim();
      } else if (name == 'grep_file') {
        // Model-facing content: "path:line: text" per match. Show the full
        // requested result set; only strip the trailing newline rg adds, not
        // leading indentation (which is meaningful in code lines).
        final maxResults = (input['max_results'] as int?) ?? 100;
        final matches = parsed['matches'] as List? ?? [];
        final count = parsed['count'] as int? ?? matches.length;
        final truncated = parsed['truncated'] == true;
        final sb = StringBuffer();
        for (final m in matches.take(maxResults)) {
          final mm = m is Map<String, dynamic> ? m : <String, dynamic>{};
          final p = mm['path'] ?? '?';
          final l = mm['line'];
          final t = (mm['text'] ?? '').toString().trimRight();
          sb.writeln('$p:${l ?? '?'}: $t');
        }
        if (truncated) sb.writeln('... (truncated, showing ${matches.length} of $count)');
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
  String _formatSearchResultForDisplay(String toolName, Map<String, dynamic> result) {
    if (result['ok'] != true) {
      // Error — use the error message directly
      final error = (result['error'] as String?) ?? 'Unknown error';
      return error.length > 200 ? '${error.substring(0, 200)}...' : error;
    }

    final buf = StringBuffer();

    if (toolName == 'web_search') {
      final results = result['results'] as Map<String, dynamic>?;
      if (results == null || results.isEmpty) {
        return 'No results found.';
      }

      var totalLen = 0;
      const maxLen = 2000;
      var nsCount = 0;
      var resultsBeyond = 0;

      for (final ns in results.keys) {
        nsCount++;
        if (totalLen >= maxLen) { resultsBeyond++; continue; }

        final nsData = results[ns] as Map<String, dynamic>?;
        if (nsData == null) continue;

        if (nsData.containsKey('error')) {
          final err = (nsData['error'] as String?) ?? 'Unknown error';
          final line = '$ns: ERROR — ${err.length > 200 ? '${err.substring(0, 200)}...' : err}\n';
          if (totalLen + line.length > maxLen) { resultsBeyond++; continue; }
          buf.write(line);
          totalLen += line.length;
        } else {
          final items = nsData['results'] as List<dynamic>?;
          final count = items?.length ?? 0;
          final line = '$ns: $count results\n';
          if (totalLen + line.length > maxLen) { resultsBeyond++; continue; }
          buf.write(line);
          totalLen += line.length;

          // First result preview
          if (items != null && items.isNotEmpty) {
            final first = items[0] as Map<String, dynamic>?;
            if (first != null) {
              final title = (first['title'] as String?) ?? '';
              final url = (first['url'] as String?) ?? '';
              final content = (first['content'] as String?) ?? '';
              var preview = '';
              if (title.isNotEmpty) preview += title;
              if (url.isNotEmpty) {
                if (preview.isNotEmpty) preview += ' — ';
                preview += url;
              }
              if (content.isNotEmpty) {
                if (preview.isNotEmpty) preview += '\n';
                preview += content.length > 200
                    ? '${content.substring(0, 200)}...'
                    : content;
              }
              if (preview.isNotEmpty) {
                if (totalLen + preview.length + 2 > maxLen) {
                  preview = '${preview.substring(0, maxLen - totalLen - 5)}...';
                }
                buf.write('$preview\n');
                totalLen += preview.length + 1;
              }
            }
          }
        }
      }

      if (resultsBeyond > 0) {
        buf.write('... ($resultsBeyond more providers not shown)');
      }
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
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: SegmentedButton<ContextViewMode>(
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
                ),
              ),
              Expanded(
                child: _viewMode == ContextViewMode.conversation
                    ? ChatArea(
                        items: _chatItems,
                        isStreaming: _isStreaming,
                        onSendMessage: _sendMessage,
                      )
                    : ContextView(snapshot: _contextSnapshot),
              ),
            ],
          ),
        ),
      ],
    );
  }
}