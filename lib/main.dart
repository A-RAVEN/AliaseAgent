import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'models/app_config.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'services/agent_type_registry.dart';
import 'services/config_service.dart';
import 'services/message_repository.dart';
import 'services/provider_resolver.dart';
import 'services/session_repository.dart';
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

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await _sessionRepo.list();
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
    final msgs = await _msgRepo.queryBySession(_currentId!);
    setState(() => _messages = msgs);
  }

  void _selectSession(Session s) {
    setState(() {
      _currentId = s.id;
      _isStreaming = false;
      _streamingText = '';
    });
    _loadMessages();
  }

  Future<void> _newChat() async {
    final s = await _sessionRepo.create();
    setState(() {
      _currentId = s.id;
      _messages = [];
      _isStreaming = false;
      _streamingText = '';
    });
    _loadSessions();
  }

  Future<void> _deleteSession(Session s) async {
    await _sessionRepo.delete(s.id);
    final wasCurrent = _currentId == s.id;
    setState(() {
      _sessions.removeWhere((x) => x.id == s.id);
      if (wasCurrent) {
        _currentId = _sessions.isNotEmpty ? _sessions.first.id : null;
        _messages = [];
        _isStreaming = false;
        _streamingText = '';
        if (_currentId != null) _loadMessages();
      }
    });
  }

  Future<void> _sendMessage(String text) async {
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
    });

    _loadSessions();

    // Mock assistant response (3 chunks with delays)
    _mockAssistantReply();
  }

  void _mockAssistantReply() {
    // Predefined mock responses based on user message patterns
    final userText = _messages.last.content.toLowerCase();

    String fullResponse;
    if (userText.contains('hello') || userText.contains('hi')) {
      fullResponse =
          'Hello! How can I help you today?\n\nI\'m a helpful assistant. Feel free to ask me anything!';
    } else if (userText.contains('markdown') || userText.contains('code')) {
      fullResponse =
          'Here\'s an example of **Markdown** support:\n\n```dart\nvoid main() {\n  print("Hello, World!");\n}\n```\n\n- Item 1\n- Item 2\n\nVisit [Flutter](https://flutter.dev) for more info.';
    } else if (userText.contains('tool') || userText.contains('read')) {
      fullResponse =
          'Let me read that file for you.\n\n```json\n{"ok":true,"content":"Hello from workspace!"}\n```';
    } else {
      fullResponse =
          'I received your message. This is a **mock response** while the UI is being built.\n\n*Streaming works!*';
    }

    // Simulate streaming in 3 chunks with delays
    final chunks = <String>[];
    final third = (fullResponse.length / 3).ceil();

    // Split at word boundaries
    int pos = 0;
    for (int i = 0; i < 3; i++) {
      int end;
      if (i == 2) {
        end = fullResponse.length;
      } else {
        final target = pos + third;
        if (target >= fullResponse.length) {
          end = fullResponse.length;
        } else {
          end = target;
          while (end < fullResponse.length && fullResponse[end] != ' ') {
            end++;
          }
        }
      }
      chunks.add(fullResponse.substring(pos, end));
      pos = end;
    }

    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() => _streamingText = chunks[0]);
    });

    Future.delayed(const Duration(milliseconds: 1000), () {
      if (!mounted) return;
      setState(() => _streamingText = chunks[0] + chunks[1]);
    });

    Future.delayed(const Duration(milliseconds: 1500), () async {
      if (!mounted) return;
      setState(() {
        _streamingText = fullResponse;
        _isStreaming = false;
      });

      final assistantMsg = await _msgRepo.insert(
        sessionId: _currentId!,
        role: 'assistant',
        content: fullResponse,
      );
      await _sessionRepo.touch(_currentId!);
      setState(() {
        _messages.add(assistantMsg);
        _streamingText = '';
      });
    });
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
            streamingText: _isStreaming ? _streamingText : null,
            isStreaming: _isStreaming,
            onSendMessage: _sendMessage,
          ),
        ),
      ],
    );
  }
}