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

    // ── 上下文压缩阈值百分比（配置键 compaction_threshold_percent）─────
    // 阈值 = 模型能装下的上下文总量 × 这个百分比 ÷ 100（用户钉死的规则：
    // 只设 token 阈值、阈值由容量乘百分比算出）。缺省 25 表示配置里不写这项
    // 就按 25% 算。下面三例覆盖「有值 / 没有这一项 / 值非法」。
    group('compactionThresholdPercent', () {
      test('reads an explicit compaction_threshold_percent from JSON', () {
        final config = AgentTypeConfig.fromJson('general', {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '',
          'max_context_tokens': 1000000,
          'compaction_threshold_percent': 10,
        });
        // ignore: avoid_print
        print('  [OBS] explicit percent -> ${config.compactionThresholdPercent}');
        expect(config.compactionThresholdPercent, 10);
      });

      test('defaults to 25 when compaction_threshold_percent is absent', () {
        final config = AgentTypeConfig.fromJson('general', {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '',
          'max_context_tokens': 1000000,
        });
        // ignore: avoid_print
        print('  [OBS] absent percent -> ${config.compactionThresholdPercent}');
        expect(config.compactionThresholdPercent, 25,
            reason: 'a config without the key falls back to 25%');
      });

      test('falls back to 25 for illegal values (0 / over 100 / not an integer)', () {
        for (final bad in <Object>['abc', 0, -5, 101, 12.5, true]) {
          final config = AgentTypeConfig.fromJson('general', {
            'provider': 'anthropic',
            'model': 'claude-sonnet-4-6',
            'system_prompt': '',
            'max_context_tokens': 1000000,
            'compaction_threshold_percent': bad,
          });
          // ignore: avoid_print
          print('  [OBS] illegal percent $bad -> '
              '${config.compactionThresholdPercent}');
          expect(config.compactionThresholdPercent, 25,
              reason: 'illegal value $bad must fall back to the 25% default');
        }
      });
    });

    // ── 等待阈值百分比（配置键 compaction_wait_threshold_percent）───────────
    // 用户 2026-10-02 的要求：只有"不压就发的那一趟"占模型总上下文超过一个较大比例
    // （缺省 75%）时，这一轮才为压缩等待。同样只按"容量 × 百分比"算，缺省 75。
    // 下面三例覆盖「有值 / 没有这一项 / 值非法」，与上面那组同一套规则。
    group('compactionWaitThresholdPercent', () {
      test('reads an explicit compaction_wait_threshold_percent from JSON', () {
        final config = AgentTypeConfig.fromJson('general', {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '',
          'max_context_tokens': 1000000,
          'compaction_wait_threshold_percent': 60,
        });
        // ignore: avoid_print
        print('  [OBS] explicit wait percent -> '
            '${config.compactionWaitThresholdPercent}');
        expect(config.compactionWaitThresholdPercent, 60);
      });

      test('defaults to 75 when compaction_wait_threshold_percent is absent', () {
        final config = AgentTypeConfig.fromJson('general', {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'system_prompt': '',
          'max_context_tokens': 1000000,
        });
        // ignore: avoid_print
        print('  [OBS] absent wait percent -> '
            '${config.compactionWaitThresholdPercent}');
        expect(config.compactionWaitThresholdPercent, 75,
            reason: '配置里不写这一项就按 75% 算');
      });

      test('falls back to 75 for illegal values (0 / over 100 / not an integer)', () {
        for (final bad in <Object>['abc', 0, -5, 101, 12.5, true]) {
          final config = AgentTypeConfig.fromJson('general', {
            'provider': 'anthropic',
            'model': 'claude-sonnet-4-6',
            'system_prompt': '',
            'max_context_tokens': 1000000,
            'compaction_wait_threshold_percent': bad,
          });
          // ignore: avoid_print
          print('  [OBS] illegal wait percent $bad -> '
              '${config.compactionWaitThresholdPercent}');
          expect(config.compactionWaitThresholdPercent, 75,
              reason: 'illegal value $bad must fall back to the 75% default');
        }
      });
    });
  });
}
