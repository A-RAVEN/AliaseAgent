import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/config_service.dart';

const _validJson = '''
{
  "version": 1,
  "providers": {
    "anthropic": {
      "api_key": "sk-test-key",
      "base_url": "https://api.anthropic.com"
    }
  },
  "agent_types": {
    "general": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-6",
      "system_prompt": "You are helpful.",
      "tools": ["read_file"]
    }
  }
}
''';

void main() {
  late Directory tempDir;
  late String configPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_service_test_');
    configPath = '${tempDir.path}${Platform.pathSeparator}config.json';
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('ConfigService', () {
    // ── 2.1 Valid config ───────────────────────────────────────────

    test('valid config returns ok with parsed AppConfig', () {
      File(configPath).writeAsStringSync(_validJson);

      final result = ConfigService.load(configPath: configPath);
      expect(result.status, ConfigStatus.ok);

      final config = result.config!;
      expect(config.version, 1);
      expect(config.providers.length, 1);
      expect(config.providers['anthropic']!.apiKey, 'sk-test-key');
      expect(config.agentTypes.length, 1);
      expect(config.agentTypes['general']!.model, 'claude-sonnet-4-6');
    });

    test('valid config with multiple providers loads all', () {
      final multiJson = jsonEncode({
        'version': 1,
        'providers': {
          'a': {'api_key': 'key-a', 'base_url': 'https://a.com'},
          'b': {'api_key': 'key-b', 'base_url': 'https://b.com'},
        },
        'agent_types': {
          'g1': {'provider': 'a', 'model': 'm1'},
          'g2': {'provider': 'b', 'model': 'm2'},
        },
      });
      File(configPath).writeAsStringSync(multiJson);

      final result = ConfigService.load(configPath: configPath);
      expect(result.status, ConfigStatus.ok);
      expect(result.config!.providers.length, 2);
      expect(result.config!.agentTypes.length, 2);
    });

    // ── 2.2 Missing config file ────────────────────────────────────

    test('missing file returns notFound', () {
      // Don't create the file
      final nonExistent = '$configPath.nonexistent';
      final result = ConfigService.load(configPath: nonExistent);
      expect(result.status, ConfigStatus.notFound);
      expect(result.config, isNull);
    });

    // ── 2.3 Malformed config (invalid JSON) ────────────────────────

    test('invalid JSON returns malformed', () {
      File(configPath).writeAsStringSync('not valid json {{{');

      final result = ConfigService.load(configPath: configPath);
      expect(result.status, ConfigStatus.malformed);
      expect(result.error, isNotNull);
      expect(result.error, contains('Invalid JSON'));
    });

    // ── 2.4 Missing nested required fields ─────────────────────────
    // Note: missing top-level "providers" key does NOT trigger malformed —
    // AppConfig.fromJson gracefully defaults to empty maps.
    // Only missing NESTED required fields (e.g., provider's "api_key") trigger TypeError.

    test('provider missing api_key returns malformed', () {
      final missingKey = jsonEncode({
        'version': 1,
        'providers': {
          'a': {'base_url': 'https://a.com'},
        },
        'agent_types': {},
      });
      File(configPath).writeAsStringSync(missingKey);

      final result = ConfigService.load(configPath: configPath);
      expect(result.status, ConfigStatus.malformed);
    });

    // ── Backward compatibility ─────────────────────────────────────

    test('load without configPath uses default path (no crash)', () {
      // Verify the default codepath is still reachable — it may fail
      // if the real config doesn't exist, but it should not throw.
      final result = ConfigService.load();
      // Accept ok, notFound, or malformed — just verify no exception
      expect(result, isA<ConfigResult>());
    });

    // ── 完整配置的保存往返（change add-agent-object-and-templates 任务 1.2）──
    // 模板保存写回的是整份配置：providers / search / spill 与模板里未开放编辑的
    // 字段（图片模态、命令超时、不可压缩要求、压缩参数）一个都不许丢。
    test('保存往返保留 providers/search/spill 与模板未编辑字段', () {
      final full = jsonEncode({
        'version': 1,
        'providers': {
          'a': {'api_key': 'key-a', 'base_url': 'https://a.com'},
          'b': {'api_key': 'key-b', 'base_url': 'https://b.com'},
        },
        'search': {
          'deepseek': {'enabled': true, 'k': 5},
        },
        'spill': {'preview_chars': 4321},
        'agent_types': {
          'general': {
            'provider': 'a',
            'model': 'm1',
            'system_prompt': '系统',
            'tools': ['read_file', 'write_file'],
            'thinking_effort': 'max',
            'max_context_tokens': 1000000,
            'compaction_threshold_percent': 30,
            'compaction_wait_threshold_percent': 60,
            'input_modalities': ['text', 'image'],
            'command_timeout_ms': 8000,
            'command_max_timeout_ms': 16000,
            'standing_requirements': ['不要改用户配置'],
          },
        },
      });
      File(configPath).writeAsStringSync(full);

      final loaded = ConfigService.load(configPath: configPath).config!;
      ConfigService.save(loaded, configPath: configPath);
      final again = ConfigService.load(configPath: configPath).config!;
      final general = again.agentTypes['general']!;
      // ignore: avoid_print
      print('  [OBS] 往返后 providers=${again.providers.keys.toList()} '
          'search=${again.search} spill=${again.spillPreviewChars} '
          'modalities=${general.inputModalities} '
          'timeouts=${general.commandTimeoutMs}/${general.commandMaxTimeoutMs} '
          'standing=${general.standingRequirements} '
          'compaction=${general.compactionThresholdPercent}/'
          '${general.compactionWaitThresholdPercent}');

      expect(again.providers.keys.toSet(), {'a', 'b'});
      expect(again.search, {
        'deepseek': {'enabled': true, 'k': 5},
      });
      expect(again.spillPreviewChars, 4321);
      expect(general.inputModalities, ['text', 'image']);
      expect(general.commandTimeoutMs, 8000);
      expect(general.commandMaxTimeoutMs, 16000);
      expect(general.standingRequirements, ['不要改用户配置']);
      expect(general.compactionThresholdPercent, 30);
      expect(general.compactionWaitThresholdPercent, 60);
      expect(general.maxContextTokens, 1000000);
    });
  });
}
