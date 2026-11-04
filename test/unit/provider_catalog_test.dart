import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/models/provider_config.dart';

/// 模型目录的配置模型与解析（change `add-provider-model-discovery` 任务 2.1 / 2.2）。
///
/// 覆盖：旧配置没有 `models`/`discovered_at` 时读为空目录；`models` 不是数组时整体回落
/// 且日志点名原始值；数组里缺字符串 `id` 的条目逐条丢弃、其余保留、每条都有日志；
/// 网关地址归一化（剥尾随 `/` 与尾部 `/v1`，循环至稳定，其它路径逐字不变）。
///
/// 断言前逐条打印现场（命中了哪条日志、解析出几个条目、归一化前后的字符串）。
void main() {
  group('ProviderConfig 目录字段', () {
    late List<String> logs;
    late void Function(String?, {int? wrapWidth}) originalDebugPrint;

    setUp(() {
      logs = <String>[];
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
    });

    test('旧配置没有 models / discovered_at：读为空目录、从未探测', () {
      final provider = ProviderConfig.fromJson({
        'api_key': 'sk-test',
        'base_url': 'https://api.anthropic.com',
      });
      // ignore: avoid_print
      print('  [OBS] 旧配置解析：models=${provider.models.length} 条，'
          'discoveredAt=${provider.discoveredAt}，日志=${logs.length} 行');
      expect(provider.models, isEmpty);
      expect(provider.discoveredAt, isNull);
      expect(logs, isEmpty, reason: '缺失两个键是合法的向后兼容形态，不该打日志');
    });

    test('models 写成对象或字符串：整体按空目录处理，日志点名原始值', () {
      for (final raw in <Object>[
        {'deepseek/deepseek-flash': {'context_window': 1048576}},
        'not-a-list',
      ]) {
        logs.clear();
        final provider = ProviderConfig.fromJson({
          'api_key': 'sk-test',
          'base_url': 'https://x.example',
          'models': raw,
        });
        final modelLogs = logs.where((l) => l.contains('models')).toList();
        // ignore: avoid_print
        print('  [OBS] models=$raw ⇒ 目录 ${provider.models.length} 条；'
            '日志=$modelLogs');
        expect(provider.models, isEmpty);
        expect(modelLogs, isNotEmpty, reason: '非数组必须有一行日志点名原始值');
        expect(modelLogs.join('\n'), contains('$raw'));
      }
    });

    test('坏条目逐条丢弃、其余保留，日志点名被丢弃条目的原始 JSON', () {
      final good = {
        'id': 'deepseek/deepseek-flash',
        'display_name': 'DeepSeek-V4.1-Flash',
        'context_window': 1048576,
        'modalities': {
          'input': ['text', 'image'],
          'output': ['text'],
        },
        'supported_reasoning_levels': [
          {'effort': 'none'},
          {'effort': 'low'},
        ],
        'native_endpoints': ['/v1/messages'],
        'pricing': {'prompt': '0.00000015'},
      };
      final provider = ProviderConfig.fromJson({
        'api_key': 'sk-test',
        'base_url': 'https://x.example',
        'models': [
          good,
          {'display_name': '缺 id'},
          {'id': 42, 'display_name': 'id 不是字符串'},
          {
            'id': 'kimi/kimi-for-coding',
            'context_window': 1048576,
            'modalities': {
              'input': ['text', 'image', 'video'],
              'output': ['text'],
            },
          },
        ],
      });

      final droppedLogs =
          logs.where((l) => l.contains('丢弃')).toList();
      // ignore: avoid_print
      print('  [OBS] 解析出 ${provider.models.length} 条：'
          '${provider.models.map((m) => m.id).toList()}');
      // ignore: avoid_print
      print('  [OBS] 丢弃日志 ${droppedLogs.length} 行：$droppedLogs');

      expect(provider.models.map((m) => m.id).toList(),
          ['deepseek/deepseek-flash', 'kimi/kimi-for-coding']);
      expect(droppedLogs, hasLength(2), reason: '两条坏条目各打一行日志');
      expect(droppedLogs.join('\n'), contains('缺 id'));
      expect(droppedLogs.join('\n'), contains('id 不是字符串'));

      final flash = provider.models.first;
      // ignore: avoid_print
      print('  [OBS] flash: 窗口=${flash.contextWindow} 输入模态='
          '${flash.inputModalities} 档位=${flash.reasoningEfforts} '
          'native=${flash.nativeEndpoints} pricing=${flash.pricing}');
      expect(flash.contextWindow, 1048576);
      expect(flash.maxOutputTokens, isNull, reason: '没给就记未知');
      expect(flash.inputModalities, ['text', 'image']);
      expect(flash.reasoningEfforts, ['none', 'low']);
      expect(flash.nativeEndpoints, ['/v1/messages']);
      expect(flash.pricing, {'prompt': '0.00000015'});
    });

    test('discovered_at 不是字符串：按从未探测处理并打一行日志', () {
      final provider = ProviderConfig.fromJson({
        'api_key': 'sk-test',
        'base_url': 'https://x.example',
        'discovered_at': 1712345678,
      });
      // ignore: avoid_print
      print('  [OBS] discovered_at=1712345678 ⇒ ${provider.discoveredAt}；'
          '日志=${logs.where((l) => l.contains('discovered_at')).toList()}');
      expect(provider.discoveredAt, isNull);
      expect(logs.where((l) => l.contains('discovered_at')), isNotEmpty);
    });

    test('toJson 写回目录与探测时刻：探测过的 Provider 两键都可发现', () {
      final provider = ProviderConfig(
        apiKey: 'sk-test',
        baseUrl: 'https://x.example',
        models: const [
          ModelCatalogEntry(
            id: 'deepseek/deepseek-flash',
            displayName: 'DeepSeek-V4.1-Flash',
            contextWindow: 1048576,
            maxOutputTokens: 393216,
            inputModalities: ['text', 'image'],
            outputModalities: ['text'],
            reasoningEfforts: ['none', 'low', 'high', 'max'],
            nativeEndpoints: ['/v1/messages'],
            pricing: {'prompt': '0.00000015'},
          ),
        ],
        discoveredAt: '2026-11-04T02:00:00.000Z',
      );
      final json = provider.toJson();
      // ignore: avoid_print
      print('  [OBS] toJson=$json');
      expect(json['models'], isA<List<dynamic>>());
      expect((json['models'] as List).first['id'], 'deepseek/deepseek-flash');
      expect(json['discovered_at'], '2026-11-04T02:00:00.000Z');

      final round = ProviderConfig.fromJson(json);
      expect(round.models.single.id, 'deepseek/deepseek-flash');
      expect(round.models.single.contextWindow, 1048576);
      expect(round.discoveredAt, '2026-11-04T02:00:00.000Z');
    });

    test('从未探测的 Provider 序列化不新增目录键（其它 Provider 保持原样）', () {
      final json = const ProviderConfig(
        apiKey: 'sk-test',
        baseUrl: 'https://api.anthropic.com',
      ).toJson();
      // ignore: avoid_print
      print('  [OBS] 未探测 Provider 的 toJson=$json');
      expect(json.containsKey('models'), isFalse);
      expect(json.containsKey('discovered_at'), isFalse);
    });
  });

  group('模型目录条目逐字段回落', () {
    test('窗口缺失 / 非正整数记未知；档位 [] 合法；native_endpoints 缺失不补空集合', () {
      for (final raw in <Object?>[
        null,
        0,
        -1,
        '1048576',
      ]) {
        final entry = ModelCatalogEntry.fromJson({
          'id': 'm1',
          'context_window': raw,
          'modalities': {'input': ['text']},
          'supported_reasoning_levels': <Object>[],
        });
        // ignore: avoid_print
        print('  [OBS] context_window=$raw ⇒ ${entry?.contextWindow}；'
            '档位=${entry?.reasoningEfforts}；native=${entry?.nativeEndpoints}');
        expect(entry, isNotNull);
        expect(entry!.contextWindow, isNull);
        expect(entry.reasoningEfforts, isEmpty,
            reason: '显式空数组 = 无已知档位，不是解析失败');
        expect(entry.nativeEndpoints, isNull, reason: '缺失 = 未知，不能补齐成空集合');
        expect(entry.pricing, isNull);
      }
    });

    test('id 缺失或非字符串：返回 null（逐条丢弃的判定入口）', () {
      for (final raw in <Object?>[
        null,
        'hello',
        <String, dynamic>{'display_name': '无 id'},
        <String, dynamic>{'id': 7},
      ]) {
        final entry = ModelCatalogEntry.fromJson(raw);
        // ignore: avoid_print
        print('  [OBS] fromJson($raw) ⇒ $entry');
        expect(entry, isNull);
      }
    });
  });

  group('网关地址归一化', () {
    test('剥尾随斜杠与尾部 /v1，循环至稳定；其它路径逐字保留', () {
      final cases = <String, String>{
        'http://127.0.0.1:3425/v1': 'http://127.0.0.1:3425',
        'http://127.0.0.1:3425/v1/': 'http://127.0.0.1:3425',
        'http://127.0.0.1:3425/v1/v1': 'http://127.0.0.1:3425',
        'https://api.deepseek.com/anthropic': 'https://api.deepseek.com/anthropic',
        'https://api.deepseek.com/anthropic/v1': 'https://api.deepseek.com/anthropic',
        'https://x.example/': 'https://x.example',
        'https://x.example/v1/': 'https://x.example',
      };
      for (final entry in cases.entries) {
        final got = normalizeBaseUrl(entry.key);
        // ignore: avoid_print
        print('  [OBS] normalize("${entry.key}") = "$got"');
        expect(got, entry.value, reason: '输入 ${entry.key} 的归一化结果不对');
      }
    });
  });
}
