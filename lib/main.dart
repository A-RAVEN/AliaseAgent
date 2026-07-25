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
        'description': 'Read the contents of a file within the workspace.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Path to the file relative to the workspace root.',
            },
          },
          'required': ['path'],
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
        'description': 'Fetch the text content of a web page by URL. '
            'Use this to get full article text when search snippets are insufficient.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': 'The URL of the web page to fetch.',
            },
            'extract_mode': {
              'type': 'string',
              'enum': ['text'],
              'default': 'text',
              'description': 'Extraction mode. Only "text" is supported in v1.',
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

  void _selectSession(Session s) {
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
    if (wasCurrent) _endStreaming();
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

    // Insert user message
    final userMsg = await _msgRepo.insert(
      sessionId: _currentId!,
      role: 'user',
      content: text,
    );
    await _sessionRepo.touch(_currentId!);

    setState(() {
      _chatItems.add(ChatMessageItem(userMsg));
      _isStreaming = true;
    });

    // Auto-title: update "New Chat" from first user message
    final titleUpdated = await _sessionRepo.updateTitleIfDefault(_currentId!, text);
    if (titleUpdated && mounted) {
      setState(() {
        _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      });
    }

    // Snapshot session state before async gap to prevent race conditions
    final sessionId = _currentId!;
    final snapMessages = _chatItemsToMessages();
    await _callModel(sessionId: sessionId, messages: snapMessages);
  }

  // -------------------------------------------------------------------------
  // Model calling with tool execution loop
  // -------------------------------------------------------------------------

  Future<void> _callModel({required String sessionId, required List<Message> messages}) async {
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
      final messagesJson = jsonEncode(apiMessages);

      String turnText = '';
      final turnToolCalls = <Map<String, dynamic>>[];
      final turnThinkingBlocks = <Map<String, dynamic>>[];
      int doneCode = 0;
      String? doneError;
      String? doneStopReason;

      await _sidecar.sendMessage(
        apiKey: provider.apiKey,
        baseUrl: baseUrl,
        model: agentType.model,
        systemPrompt: '${agentType.systemPrompt}\nCurrent date: ${DateTime.now().toIso8601String().substring(0, 10)}. For precise time-sensitive queries, use the get_current_time tool.',
        messagesJson: messagesJson,
        toolsJson: toolsJson,
        onChunk: (text) {
          turnText += text;
          if (_currentId == sessionId && mounted) {
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
            if (_currentId == sessionId) {
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
            turnThinkingBlocks.add(jsonDecode(json) as Map<String, dynamic>);
          } catch (e) {
            debugPrint('[AliasAgent] onThinking parse error: $e\nraw: $json');
          }
        },
        onDone: (code, error, stopReason) {
          doneCode = code;
          doneError = error;
          doneStopReason = stopReason;
          debugPrint('[AliasAgent] stop_reason: $doneStopReason');
        },
      );

      if (doneCode != 0) {
        if (_currentId == sessionId) _endStreaming();
        await _storeError(doneError ?? 'Unknown error', sessionId: sessionId);
        return;
      }

      // Remove streaming item
      if (_currentId == sessionId && mounted) {
        setState(() {
          _chatItems.removeWhere((i) => i is ChatStreamingItem);
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
          );
          await _sessionRepo.touch(sessionId);
          if (_currentId == sessionId && mounted) {
            setState(() {
              _chatItems.add(ChatMessageItem(assistantMsg));
            });
          }
        }
        if (_currentId == sessionId) _endStreaming();
        return;
      }

      // Tool calls present — accumulate and persist intermediate assistant message
      allTurnToolCalls.addAll(turnToolCalls);
      final turnJson = jsonEncode(turnToolCalls);
      final intermediateMsg = await _msgRepo.insert(
        sessionId: sessionId,
        role: 'assistant',
        content: turnText,
        toolCallsJson: turnJson,
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
        if (_currentId == sessionId) _endStreaming();
        await _sessionRepo.touch(sessionId);
        return;
      }
      turn++;
    }
  }

  /// Build API conversation messages from persisted Message objects,
  /// reconstructing tool_use content blocks and synthetic tool_result messages.
  List<Map<String, dynamic>> _buildApiMessages(List<Message> messages) {
    final apiMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final content = <Map<String, dynamic>>[
        {'type': 'text', 'text': msg.content},
      ];

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
        resultJson = _sidecar.readFile(path);
      case 'list_dir':
        resultJson = _sidecar.listDir(path);
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
          'extract_mode': input['extract_mode'] ?? 'text',
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
      // Task 8.9: Format search results for display
      if (name == 'web_search' || name == 'web_fetch') {
        parsed['content'] = _formatSearchResultForDisplay(name!, parsed);
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
      return [
        ResultSection(
          label: 'Fetched page',
          items: [
            ResultItem(
              title: (result['url'] as String?) ?? '',
              content: content,
            ),
          ],
        ),
      ];
    }
    return [];
  }

  /// Remove streaming indicator only; tool call cards and persistent messages persist.
  void _endStreaming() {
    if (!mounted) return;
    setState(() {
      _isStreaming = false;
      _chatItems.removeWhere((i) => i is ChatStreamingItem);
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