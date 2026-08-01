import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/services/agent_type_registry.dart';
import 'package:alias_agent/services/provider_resolver.dart';

void main() {
  group('AgentTypeRegistry', () {
    late AgentTypeRegistry registry;

    setUp(() {
      registry = AgentTypeRegistry();
    });

    // ── 3.1 Register + lookup ──────────────────────────────────────

    test('register and lookup returns correct config', () {
      const config = AgentTypeConfig(
        name: 'general',
        provider: 'test',
        model: 'test-model',
        systemPrompt: '',
      );
      registry.register(config);

      final result = registry.lookup('general');
      expect(result, isNotNull);
      expect(result!.name, 'general');
      expect(result.provider, 'test');
      expect(result.model, 'test-model');
    });

    // ── 3.2 Lookup unregistered name ───────────────────────────────

    test('lookup unregistered name returns null', () {
      final result = registry.lookup('nonexistent');
      expect(result, isNull);
    });

    // ── 3.3 listNames ──────────────────────────────────────────────

    test('listNames returns all registered names', () {
      registry.register(const AgentTypeConfig(
        name: 'a', provider: 'p', model: 'm', systemPrompt: '',
      ));
      registry.register(const AgentTypeConfig(
        name: 'b', provider: 'p', model: 'm', systemPrompt: '',
      ));

      final names = registry.listNames();
      expect(names, containsAll(['a', 'b']));
      expect(names.length, 2);
    });

    test('clear removes all registered configs', () {
      registry.register(const AgentTypeConfig(
        name: 'a', provider: 'p', model: 'm', systemPrompt: '',
      ));
      registry.clear();
      expect(registry.lookup('a'), isNull);
      expect(registry.listNames(), isEmpty);
    });
  });

  group('ProviderResolver', () {
    // ── 3.4 ProviderResolver.resolve ───────────────────────────────

    test('resolve returns ProviderConfig for known name', () {
      final config = AppConfig(
        version: 1,
        providers: {
          'anthropic': const ProviderConfig(
            apiKey: 'key', baseUrl: 'https://api.anthropic.com',
          ),
        },
      );
      final resolver = ProviderResolver(config);

      final result = resolver.resolve('anthropic');
      expect(result, isNotNull);
      expect(result!.apiKey, 'key');
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

      test('thinkingEffort is null when absent from JSON', () {
        final config = AgentTypeConfig.fromJson('basic', {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '',
        });
        expect(config.thinkingEffort, isNull);
      });

      test('toJson includes thinking_effort when non-null', () {
        const config = AgentTypeConfig(
          name: 'coder', provider: 'a', model: 'm',
          systemPrompt: '', thinkingEffort: 'max',
        );
        final json = config.toJson();
        expect(json['thinking_effort'], 'max');
      });

      test('toJson omits thinking_effort when null', () {
        const config = AgentTypeConfig(
          name: 'basic', provider: 'a', model: 'm',
          systemPrompt: '',
        );
        final json = config.toJson();
        expect(json.containsKey('thinking_effort'), isFalse);
      });
    });

    test('resolve returns null for unknown provider name', () {
      final config = AppConfig(
        version: 1,
        providers: {
          'anthropic': const ProviderConfig(
            apiKey: 'key', baseUrl: '',
          ),
        },
      );
      final resolver = ProviderResolver(config);

      final result = resolver.resolve('openai');
      expect(result, isNull);
    });
  });
}
