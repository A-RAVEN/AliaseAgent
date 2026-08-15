import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/sidecar_bridge.dart';

/// Live test (6.4): the real model (DeepSeek Anthropic-compatible endpoint)
/// uses glob_file / grep_file / batch edit_file to complete a multi-file task.
///
/// Tagged [live] — requires a configured model API key in
/// %USERPROFILE%\.aliasagent\config.json and network access to the endpoint.
/// Skips with a clear reason when no key is configured.
void main() {
  late SidecarBridge bridge;
  late Map<String, dynamic> cfg;

  setUpAll(() {
    bridge = SidecarBridge.instance;
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    final configFile = File('$home/.aliasagent/config.json');
    if (configFile.existsSync()) {
      cfg = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    } else {
      cfg = <String, dynamic>{};
    }
  });

  // Tool definitions mirroring main.dart (edit_file uses the new edits schema).
  List<Map<String, dynamic>> buildTools() => [
        {
          'name': 'read_file',
          'description': 'Read the contents of a file within the workspace.',
          'input_schema': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
        {
          'name': 'write_file',
          'description': 'Create or overwrite a file in the workspace.',
          'input_schema': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'content': {'type': 'string'},
            },
            'required': ['path', 'content'],
          },
        },
        {
          'name': 'edit_file',
          'description': 'Edit a file by replacing text. Accepts a batch of '
              'replacement pairs. Each old_text must match exactly and must not '
              'be empty. If an old_text matches multiple locations without '
              'replace_all:true, the whole request is rejected. All pairs are '
              'validated first; if any fails, no changes are applied.',
          'input_schema': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'edits': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'old_text': {'type': 'string'},
                    'new_text': {'type': 'string'},
                    'replace_all': {'type': 'boolean', 'default': false},
                  },
                  'required': ['old_text', 'new_text'],
                },
              },
            },
            'required': ['path', 'edits'],
          },
        },
        {
          'name': 'glob_file',
          'description': 'Find files within the workspace matching a glob '
              'pattern (supports *, **, ?). Returns workspace-relative paths.',
          'input_schema': {
            'type': 'object',
            'properties': {
              'pattern': {'type': 'string'},
            },
            'required': ['pattern'],
          },
        },
        {
          'name': 'grep_file',
          'description': 'Search file contents within the workspace using a '
              'regular expression. Returns path:line:text matches with '
              'workspace-relative paths.',
          'input_schema': {
            'type': 'object',
            'properties': {
              'pattern': {'type': 'string'},
              'glob': {'type': 'string'},
            },
            'required': ['pattern'],
          },
        },
      ];

  Future<Map<String, dynamic>> executeTool(
      Map<String, dynamic> tc, SidecarBridge b) async {
    final name = tc['name'] as String;
    final input = (tc['input'] as Map<String, dynamic>?) ?? {};
    String jsonStr;
    switch (name) {
      case 'read_file':
        jsonStr = b.readFile(jsonEncode({'path': input['path'] ?? ''}));
      case 'write_file':
        jsonStr = b.writeFile(jsonEncode({
          'path': input['path'] ?? '',
          'content': input['content'] ?? '',
        }));
      case 'edit_file':
        jsonStr = b.editFile(jsonEncode({
          'path': input['path'] ?? '',
          'edits': input['edits'] ?? <dynamic>[],
        }));
      case 'list_dir':
        jsonStr = b.listDir(input['path'] ?? '.');
      case 'glob_file':
        jsonStr = b.globFile(jsonEncode({
          'pattern': input['pattern'] ?? '',
          'max_results': input['max_results'] ?? 200,
        }));
      case 'grep_file':
        jsonStr = b.grepFile(jsonEncode({
          'pattern': input['pattern'] ?? '',
          'glob': input['glob'] ?? '',
          'ignore_case': input['ignore_case'] ?? false,
          'max_results': input['max_results'] ?? 100,
        }));
      default:
        jsonStr = jsonEncode({'ok': false, 'error': 'unknown tool $name'});
    }
    final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
    // Give the model a readable content view (mirrors main.dart formatting).
    if (parsed['ok'] == true && name == 'glob_file') {
      parsed['content'] = (parsed['paths'] as List).join('\n');
    } else if (parsed['ok'] == true && name == 'grep_file') {
      final sb = StringBuffer();
      for (final m in (parsed['matches'] as List).take(50)) {
        final mm = m as Map<String, dynamic>;
        sb.writeln('${mm['path']}:${mm['line']}: ${mm['text']}');
      }
      parsed['content'] = sb.toString().trim().isEmpty
          ? '(no matches)'
          : sb.toString().trim();
    }
    return parsed;
  }

  test(
    'model naturally uses glob_file/grep_file/batch edit_file for a multi-file task',
    () async {
      final provider =
          (cfg['providers'] as Map<String, dynamic>?)?['anthropic'] as Map?;
      final agentType =
          (cfg['agent_types'] as Map<String, dynamic>?)?['general'] as Map?;
      final apiKey = provider?['api_key'] as String? ?? '';
      final baseUrl = provider?['base_url'] as String? ?? 'https://api.anthropic.com';
      final model = agentType?['model'] as String? ?? 'deepseek-chat';

      if (apiKey.isEmpty) {
        markTestSkipped('No anthropic API key configured — skipping live test');
        return;
      }

      // Fixture workspace with TODO comments across two files.
      final tmp = Directory.systemTemp.createTempSync('aliasagent_live_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final src = Directory('${tmp.path}/src')..createSync();
      File('${src.path}/a.dart').writeAsStringSync(
          '// TODO: fix the timeout\nvoid main() {}\n');
      File('${src.path}/b.dart').writeAsStringSync(
          '// TODO: also fix the retry\nvoid other() {}\n');
      File('${tmp.path}/README.md').writeAsStringSync('# Project\nNo todo.\n');

      bridge.setWorkspace(tmp.path);

      final messages = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content':
              'In the workspace, find every TODO comment and replace it with '
                  'DONE using the file tools. Use grep_file to find them, then '
                  'edit_file to fix them. When done, report which files you edited.',
        },
      ];
      final systemPrompt =
          'You are a helpful coding assistant. Use the available tools to '
          'complete file tasks. Today: 2026-08-15.';

      final usedTools = <String>{};
      var turn = 0;
      var success = false;
      var finalText = '';

      while (turn < 15) {
        turn++;
        final turnToolCalls = <Map<String, dynamic>>[];
        final textParts = <String>[];

        await bridge.sendMessage(
          apiKey: apiKey,
          baseUrl: baseUrl,
          model: model,
          systemPrompt: systemPrompt,
          messagesJson: jsonEncode(messages),
          toolsJson: jsonEncode(buildTools()),
          thinkingMode: 'adaptive',
          thinkingEffort: 'high',
          onChunk: (t) => textParts.add(t),
          onToolCall: (jsonStr) =>
              turnToolCalls.add(jsonDecode(jsonStr) as Map<String, dynamic>),
          onThinking: (_) {},
          onDone: (code, err, stop) {
            if (code != 0) {
              throw StateError('model call failed: $err');
            }
          },
        );

        if (turnToolCalls.isEmpty) {
          finalText = textParts.join();
          success = true;
          break;
        }

        messages.add({
          'role': 'assistant',
          'content': [
            if (textParts.isNotEmpty)
              {'type': 'text', 'text': textParts.join()},
            ...turnToolCalls,
          ],
        });

        final results = <Map<String, dynamic>>[];
        for (final tc in turnToolCalls) {
          usedTools.add(tc['name'] as String);
          final r = await executeTool(tc, bridge);
          results.add({
            'type': 'tool_result',
            'tool_use_id': tc['id'] ?? '',
            'content':
                r['ok'] == true ? (r['content'] ?? jsonEncode(r)) : jsonEncode(r),
          });
        }
        messages.add({'role': 'user', 'content': results});
      }

      // The model used the new tools: edit_file, and at least one of
      // grep_file / glob_file (the search step is required to find the TODOs).
      expect(usedTools, contains('edit_file'));
      final usedSearch = usedTools.intersection({'grep_file', 'glob_file'});
      expect(usedSearch, isNotEmpty,
          reason: 'model should use grep_file or glob_file to find the TODOs');

      // The fixture was actually edited: TODO → DONE.
      final a = File('${src.path}/a.dart').readAsStringSync();
      final b = File('${src.path}/b.dart').readAsStringSync();
      expect(a, contains('DONE'));
      expect(b, contains('DONE'));
      expect(success, isTrue, reason: 'model did not finish: $finalText');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
