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
  });
}
