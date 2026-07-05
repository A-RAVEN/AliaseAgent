import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/app_config.dart';
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
  const AppShell({super.key});

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
    final result = ConfigService.load();
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

  const ChatScreen({super.key, required this.config});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _sessionRepo = SessionRepository();
  final _msgRepo = MessageRepository();

  List<Session> _sessions = [];
  String? _currentId;
  List<Message> _messages = [];

  // Streaming state
  bool _isStreaming = false;
  String _streamingText = '';
  List<ToolCallActivity> _toolActivities = [];

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SidecarBridge.instance.setWorkspace(ConfigService.homeDir);
    _loadSessions();
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
      setState(() => _messages = []);
      return;
    }
    try {
      final msgs = await _msgRepo.queryBySession(_currentId!);
      if (!mounted) return;
      setState(() => _messages = msgs);
    } catch (e) {
      debugPrint('[AliasAgent] _loadMessages error: $e');
      if (!mounted) return;
      setState(() => _messages = []);
    }
  }

  void _selectSession(Session s) {
    _endStreaming();
    setState(() {
      _currentId = s.id;
      _messages = [];
    });
    _loadMessages();
  }

  Future<void> _newChat() async {
    final s = await _sessionRepo.create();
    if (!mounted) return;
    _endStreaming();
    setState(() {
      _currentId = s.id;
      _messages = [];
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
        _messages = [];
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
      _messages.add(userMsg);
      _isStreaming = true;
      _streamingText = '';
      _toolActivities = [];
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
    final snapMessages = List<Message>.from(_messages);
    await _callModel(sessionId: sessionId, messages: snapMessages);
  }

  // -------------------------------------------------------------------------
  // Model calling with tool execution loop
  // -------------------------------------------------------------------------

  static const _toolDefs = {
    'read_file': {
      'name': 'read_file',
      'description': 'Read the contents of a file within the workspace.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Path to the file relative to the workspace root.',
          },
        },
        'required': ['path'],
      },
    },
    'list_dir': {
      'name': 'list_dir',
      'description':
          'List the contents of a directory within the workspace.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Path to the directory relative to the workspace root.',
          },
        },
        'required': ['path'],
      },
    },
  };

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

    final toolsJson = agentType.tools.isEmpty
        ? '[]'
        : jsonEncode(agentType.tools
            .map((n) => _toolDefs[n])
            .where((d) => d != null)
            .toList());

    // Build API conversation from current DB messages
    final apiMessages = <Map<String, dynamic>>[];
    for (final msg in messages) {
      apiMessages.add({
        'role': msg.role,
        'content': [
          {'type': 'text', 'text': msg.content}
        ],
      });
    }

    for (int turn = 0; turn < 5; turn++) {
      final messagesJson = jsonEncode(apiMessages);

      String turnText = '';
      final turnToolCalls = <Map<String, dynamic>>[];
      final turnThinkingBlocks = <Map<String, dynamic>>[];
      int doneCode = 0;
      String? doneError;
      String? doneStopReason;

      await SidecarBridge.instance.sendMessage(
        apiKey: provider.apiKey,
        baseUrl: baseUrl,
        model: agentType.model,
        systemPrompt: agentType.systemPrompt,
        messagesJson: messagesJson,
        toolsJson: toolsJson,
        onChunk: (text) {
          turnText += text;
          if (_currentId == sessionId && mounted) setState(() => _streamingText = turnText);
        },
        onToolCall: (json) {
          try {
            final tc = jsonDecode(json) as Map<String, dynamic>;
            tc['id'] ??= 'tool_${turn}_${turnToolCalls.length}';
            turnToolCalls.add(tc);
            if (_currentId == sessionId) {
              _toolActivities.add(ToolCallActivity(
                id: tc['id'] as String,
                toolName: (tc['name'] as String?) ?? 'unknown',
                input: (tc['input'] as Map<String, dynamic>?) ?? {},
              ));
            }
            if (_currentId == sessionId && mounted) setState(() {});
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

      // No tool calls — store final assistant message and done
      if (turnToolCalls.isEmpty) {
        if (turnText.isNotEmpty) {
          final assistantMsg = await _msgRepo.insert(
            sessionId: sessionId,
            role: 'assistant',
            content: turnText,
          );
          await _sessionRepo.touch(sessionId);
          if (_currentId == sessionId && mounted) {
            setState(() {
              _messages.add(assistantMsg);
            });
          }
          if (_currentId == sessionId) _endStreaming();
        } else {
          if (_currentId == sessionId) _endStreaming();
        }
        return;
      }

      // Build assistant content blocks for the API
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
        final result = _executeTool(tc);
        final resultContent = result['ok'] == true
            ? (result['content'] as String? ?? '')
            : (result['error'] as String? ?? 'Tool failed');

        // Update tool activity card
        final toolId = (tc['id'] as String?) ?? '';
        final idx = _toolActivities.indexWhere((a) => a.id == toolId);
        if (_currentId == sessionId && idx >= 0) {
          _toolActivities[idx] = _toolActivities[idx].copyWith(
            status: result['ok'] == true ? ToolCallStatus.done : ToolCallStatus.error,
            result: resultContent,
            resultPreview: resultContent.length > 300
                ? '${resultContent.substring(0, 300)}...'
                : resultContent,
          );
        }

        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': tc['id'] ?? '',
          'content': resultContent,
        });
      }

      // Batch setState after all tools executed
      if (_currentId == sessionId && mounted) setState(() {});

      apiMessages.add({
        'role': 'user',
        'content': toolResults,
      });

      // Reset per-turn state; loop continues for model's tool-result reply
      turnText = '';
      turnToolCalls.clear();
      turnThinkingBlocks.clear();
    }

    // Max tool turns exceeded
    if (_currentId == sessionId) _endStreaming();
    await _sessionRepo.touch(sessionId);
  }

  Map<String, dynamic> _executeTool(Map<String, dynamic> toolCall) {
    final name = toolCall['name'] as String?;
    final input = (toolCall['input'] as Map<String, dynamic>?) ?? {};
    final path = (input['path'] as String?) ?? '';

    String resultJson;
    switch (name) {
      case 'read_file':
        resultJson = SidecarBridge.instance.readFile(path);
      case 'list_dir':
        resultJson = SidecarBridge.instance.listDir(path);
      default:
        resultJson = '{"ok":false,"error":"Unknown tool: $name"}';
    }

    try {
      return jsonDecode(resultJson) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[AliasAgent] _executeTool parse error: $e');
      return {'ok': false, 'error': 'Failed to parse tool result'};
    }
  }

  // NOTE: Will be refactored in Phase 18.9 when _chatItems replaces separate lists
  void _endStreaming() {
    if (!mounted) return;
    setState(() {
      _isStreaming = false;
      _streamingText = '';
      _toolActivities = [];
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
          _messages.add(errorMsg);
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
            messages: _messages,
            toolActivities: _toolActivities,
            streamingText: _isStreaming ? _streamingText : null,
            isStreaming: _isStreaming,
            onSendMessage: _sendMessage,
          ),
        ),
      ],
    );
  }
}