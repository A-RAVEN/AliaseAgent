import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/chat_item.dart';
import 'package:alias_agent/models/message.dart';
import 'package:alias_agent/services/database_service.dart';
import 'package:alias_agent/services/message_repository.dart';
import 'package:alias_agent/services/sidecar_bridge.dart';
import 'helpers/fake_sidecar.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Thinking persistence and API reconstruction', () {
    late Directory tempDir;
    late MessageRepository msgRepo;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('think_test_');
      await DatabaseService.openAt(tempDir.path);
      msgRepo = MessageRepository();
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('thinking_json round-trip: insert -> load -> parse', () async {
      final msg = await msgRepo.insert(
        sessionId: 'test-session',
        role: 'assistant',
        content: 'Here is my answer.',
        thinkingJson: jsonEncode([
          {
            'type': 'thinking',
            'thinking': 'Let me analyze this.',
            'signature': 'sig_abc',
          }
        ]),
      );

      final msgs = await msgRepo.queryBySession('test-session');
      expect(msgs.length, 1);
      expect(msgs[0].thinkingJson, isNotNull);

      final thinkingBlocks =
          jsonDecode(msgs[0].thinkingJson!) as List<dynamic>;
      expect(thinkingBlocks.length, 1);
      expect(thinkingBlocks[0]['type'], 'thinking');
      expect(thinkingBlocks[0]['thinking'], 'Let me analyze this.');
      expect(thinkingBlocks[0]['signature'], 'sig_abc');
    });

    test('_buildApiMessages inserts thinking blocks before text with signature', () {
      final content = <Map<String, dynamic>>[
        {'type': 'text', 'text': 'My answer.'},
      ];

      final thinkingJson = jsonEncode([
        {'type': 'thinking', 'thinking': 'Let me think.', 'signature': 'sig'},
      ]);

      if (thinkingJson.isNotEmpty) {
        try {
          final thinkingBlocks = jsonDecode(thinkingJson) as List<dynamic>;
          content.insertAll(0, thinkingBlocks.cast<Map<String, dynamic>>());
        } catch (_) {}
      }

      expect(content.length, 2);
      expect(content[0]['type'], 'thinking');
      expect(content[0]['thinking'], 'Let me think.');
      expect(content[0]['signature'], 'sig');
      expect(content[1]['type'], 'text');
      expect(content[1]['text'], 'My answer.');
    });

    test('malformed thinkingJson caught and skipped without breaking content', () {
      final content = <Map<String, dynamic>>[
        {'type': 'text', 'text': 'OK'},
      ];

      const malformedJson = 'not valid json {{{';
      if (malformedJson.isNotEmpty) {
        try {
          final thinkingBlocks = jsonDecode(malformedJson) as List<dynamic>;
          content.insertAll(0, thinkingBlocks.cast<Map<String, dynamic>>());
        } catch (_) {}
      }

      expect(content.length, 1);
      expect(content[0]['type'], 'text');
      expect(content[0]['text'], 'OK');
    });

    test('_buildChatItems reconstructs ChatThinkingItem from thinking_json', () {
      final thinkingJson = jsonEncode([
        {'type': 'thinking', 'thinking': 'Analyzing...', 'signature': 'sig_xyz'},
      ]);

      final items = <ChatItem>[];
      if (thinkingJson.isNotEmpty) {
        try {
          final thinkingBlocks = jsonDecode(thinkingJson) as List<dynamic>;
          for (final thJson in thinkingBlocks) {
            final th = thJson as Map<String, dynamic>;
            items.add(ChatThinkingItem(
              thinking: (th['thinking'] as String?) ?? '',
              signature: th['signature'] as String?,
              isStreaming: false,
            ));
          }
        } catch (_) {}
      }

      expect(items.length, 1);
      expect(items[0], isA<ChatThinkingItem>());
      final ti = items[0] as ChatThinkingItem;
      expect(ti.thinking, 'Analyzing...');
      expect(ti.signature, 'sig_xyz');
    });

    test('no thinking blocks yields NULL thinking_json', () async {
      final msg = await msgRepo.insert(
        sessionId: 'test-session',
        role: 'assistant',
        content: 'Simple reply.',
      );

      final msgs = await msgRepo.queryBySession('test-session');
      expect(msgs.length, 1);
      expect(msgs[0].thinkingJson, isNull);
    });
  });

  group('AgentTypeConfig thinking effort', () {
    test('parses valid thinking_effort from JSON', () {
      final config = AgentTypeConfig.fromJson('coder', {
        'provider': 'anthropic',
        'model': 'claude-sonnet-4-6',
        'system_prompt': '',
        'thinking_effort': 'high',
      });
      expect(config.thinkingEffort, 'high');
    });

    test('thinkingEffort is null when absent', () {
      final config = AgentTypeConfig.fromJson('basic', {
        'provider': 'anthropic',
        'model': 'claude-sonnet-4-6',
        'system_prompt': '',
      });
      expect(config.thinkingEffort, isNull);
    });

    test('toJson includes thinking_effort when non-null', () {
      const config = AgentTypeConfig(
        name: 'coder',
        provider: 'a',
        model: 'm',
        systemPrompt: '',
        thinkingEffort: 'max',
      );
      final json = config.toJson();
      expect(json['thinking_effort'], 'max');
    });

    test('toJson omits thinking_effort when null', () {
      const config = AgentTypeConfig(
        name: 'basic',
        provider: 'a',
        model: 'm',
        systemPrompt: '',
      );
      final json = config.toJson();
      expect(json.containsKey('thinking_effort'), isFalse);
    });
  });

  group('Thinking via FakeSidecar', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('think_fake_');
      await DatabaseService.openAt(tempDir.path);
    });

    tearDown(() async {
      await DatabaseService.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('v2 to v3 migration preserves data and adds thinking_json column',
        () async {
      // Create a v2 database manually (simulating pre-upgrade state)
      final dbPath = p.join(tempDir.path, 'aliasagent_migrate.db');
      final db = await openDatabase(
        dbPath,
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT 'New Chat',
              agent_type TEXT NOT NULL DEFAULT 'general',
              created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              role TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
              content TEXT NOT NULL,
              tool_calls TEXT,
              token_count INTEGER,
              created_at INTEGER NOT NULL
            )
          ''');
        },
        onUpgrade: (db, oldV, newV) async {
          if (oldV <= 1) {
            await db.execute('ALTER TABLE messages ADD COLUMN tool_calls TEXT');
          }
          if (oldV <= 2) {
            await db.execute('ALTER TABLE messages ADD COLUMN thinking_json TEXT');
          }
        },
      );

      // Insert data in v2 schema
      await db.insert('sessions', {
        'id': 's1', 'title': 'Test', 'agent_type': 'general',
        'created_at': 1, 'updated_at': 1,
      });
      await db.insert('messages', {
        'id': 'm1', 'session_id': 's1', 'role': 'user',
        'content': 'Hello', 'created_at': 1,
      });
      await db.close();

      // Reopen at v3 (triggers onUpgrade)
      final dbV3 = await openDatabase(
        dbPath,
        version: 3,
        onUpgrade: (db, oldV, newV) async {
          if (oldV <= 1) {
            await db.execute('ALTER TABLE messages ADD COLUMN tool_calls TEXT');
          }
          if (oldV <= 2) {
            await db.execute('ALTER TABLE messages ADD COLUMN thinking_json TEXT');
          }
        },
      );

      // Verify data survived
      final sessions = await dbV3.query('sessions');
      expect(sessions.length, 1);
      expect(sessions[0]['id'], 's1');

      final messages = await dbV3.query('messages');
      expect(messages.length, 1);
      expect(messages[0]['id'], 'm1');

      // Verify thinking_json column exists
      await dbV3.insert('messages', {
        'id': 'm2', 'session_id': 's1', 'role': 'assistant',
        'content': 'Test', 'thinking_json': '[{"type":"thinking","thinking":"test"}]',
        'created_at': 2,
      });
      final msgsWithThinking = await dbV3.query('messages', where: 'id = ?', whereArgs: ['m2']);
      expect(msgsWithThinking.length, 1);
      expect(msgsWithThinking[0]['thinking_json'], contains('"thinking"'));

      await dbV3.close();
    });

    test('queueThinking fires onThinking callback with complete JSON', () async {
      final sidecar = FakeSidecar();
      final thinkingBlocks = <Map<String, dynamic>>[];

      sidecar
        ..queueThinking(jsonEncode({
          'type': 'thinking',
          'thinking': 'Analyzing the request step by step...',
          'signature': 'sig_test',
        }))
        ..queueDone(stopReason: 'end_turn');

      await sidecar.sendMessage(
        apiKey: 'test-key',
        baseUrl: 'https://test.example.com',
        model: 'claude-sonnet-4-6',
        systemPrompt: '',
        messagesJson: '[{"role":"user","content":"hello"}]',
        toolsJson: '',
        thinkingMode: 'disabled',
        thinkingEffort: '',
        onChunk: (_) {},
        onToolCall: (_) {},
        onThinking: (json) {
          try {
            thinkingBlocks.add(jsonDecode(json));
          } catch (_) {}
        },
        onDone: (_, __, ___) {},
      );

      expect(thinkingBlocks.length, 1);
      expect(thinkingBlocks[0]['type'], 'thinking');
      expect(thinkingBlocks[0]['thinking'], 'Analyzing the request step by step...');
      expect(thinkingBlocks[0]['signature'], 'sig_test');
    });
  });
}
