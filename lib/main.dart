import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/app_config.dart';
import 'models/chat_item.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'models/tool_call_activity.dart';
import 'services/agent_type_registry.dart';
import 'services/config_service.dart';
import 'services/message_repository.dart';
import 'services/provider_resolver.dart';
import 'services/session_repository.dart';
import 'services/sidecar_bridge.dart';
import 'ui/chat_area.dart';
import 'ui/session_sidebar.dart';
import 'ui/setup_dialog.dart';

final registry = AgentTypeRegistry();
ProviderResolver? resolver;

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

  const ChatScreen({
    super.key,
    required this.config,
    this.sessionRepo,
    this.msgRepo,
    this.sidecar,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final SessionRepository _sessionRepo;
  late final MessageRepository _msgRepo;
  late final ISidecar _sidecar;

  List<Session> _sessions = [];
  String? _currentId;
  List<ChatItem> _chatItems = [];

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
    _initSearchAndTools();
    _loadSessions();
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
      // Skip empty ChatMessageItem when tool cards represent the response (D7)
      if (msg.content.isEmpty &&
          msg.toolCallsJson != null &&
          msg.toolCallsJson!.isNotEmpty) {
        continue;
      }
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
    if (_isStreaming) _switchEpoch = _requestEpoch;
    _endStreaming();
    setState(() {
      _currentId = s.id;
      _chatItems = [];
    });
    _loadMessages();
  }

  Future<void> _newChat() async {
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
    await _sessionRepo.delete(s.id);
    if (!mounted) return;
    final wasCurrent = _currentId == s.id;
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

    // Build API conversation from persisted messages, reconstructing tool_use blocks
    final apiMessages = _buildApiMessages(messages);

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

      // Determine thinking mode/effort from agent config
      const validEfforts = {'low', 'medium', 'high', 'xhigh', 'max'};
      final thinkingMode = (agentType.thinkingEffort != null &&
              validEfforts.contains(agentType.thinkingEffort))
          ? 'adaptive'
          : 'disabled';
      final thinkingEffort = thinkingMode == 'adaptive'
          ? agentType.thinkingEffort!
          : '';

      await _sidecar.sendMessage(
        apiKey: provider.apiKey,
        baseUrl: baseUrl,
        model: agentType.model,
        systemPrompt: '${agentType.systemPrompt}\nCurrent date: ${DateTime.now().toIso8601String().substring(0, 10)}. For precise time-sensitive queries, use the get_current_time tool.',
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
        onDone: (code, error, stopReason) {
          doneCode = code;
          doneError = error;
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
          );
          await _sessionRepo.touch(sessionId);
          if (_currentId == sessionId && mounted) {
            setState(() {
              _chatItems.add(ChatMessageItem(assistantMsg));
            });
          }
        }
        if (_currentId == sessionId && !wasSwitchCancelled) _endStreaming();
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

      // Update intermediate message with enriched tool call data
      if (_currentId == sessionId) {
        await _msgRepo.updateToolCalls(
            intermediateMsg.id, jsonEncode(turnToolCalls));
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
        if (_currentId == sessionId && !wasSwitchCancelled) _endStreaming();
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

  /// Build API conversation messages from persisted Message objects,
  /// reconstructing tool_use content blocks and synthetic tool_result messages.
  List<Map<String, dynamic>> _buildApiMessages(List<Message> messages) {
    final apiMessages = <Map<String, dynamic>>[];
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

      // If assistant message has tool calls, add tool_use blocks
      if (msg.role == 'assistant' &&
          msg.toolCallsJson != null &&
          msg.toolCallsJson!.isNotEmpty) {
        try {
          final toolCalls = jsonDecode(msg.toolCallsJson!) as List<dynamic>;
          for (final tc in toolCalls) {
            final tcMap = tc as Map<String, dynamic>;
            content.add({
              'type': 'tool_use',
              'id': tcMap['id'] ?? '',
              'name': tcMap['toolName'] ?? tcMap['name'] ?? '',
              'input': tcMap['input'] ?? {},
            });
          }
        } catch (e) {
          debugPrint('[AliasAgent] Failed to parse toolCallsJson: $e');
        }
      }

      apiMessages.add({
        'role': msg.role,
        'content': content,
      });

      // If assistant message has tool calls, add synthetic tool_result user message
      if (msg.role == 'assistant' &&
          msg.toolCallsJson != null &&
          msg.toolCallsJson!.isNotEmpty) {
        try {
          final toolCalls = jsonDecode(msg.toolCallsJson!) as List<dynamic>;
          final toolResults = <Map<String, dynamic>>[];
          for (final tc in toolCalls) {
            final tcMap = tc as Map<String, dynamic>;
            toolResults.add({
              'type': 'tool_result',
              'tool_use_id': tcMap['id'] ?? '',
              'content': tcMap['result'] ?? tcMap['resultPreview'] ?? '',
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
          _chatItems.add(ChatMessageItem(errorMsg));
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
          child: ChatArea(
            items: _chatItems,
            isStreaming: _isStreaming,
            onSendMessage: _sendMessage,
          ),
        ),
      ],
    );
  }
}