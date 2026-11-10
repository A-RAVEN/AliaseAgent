import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/model_catalog_entry.dart';
import 'package:alias_agent/models/provider_config.dart';
import 'package:alias_agent/models/resolved_agent_config.dart';
import 'package:alias_agent/services/agent_config_resolver.dart';
import 'package:alias_agent/services/provider_resolver.dart';

/// 实例生效配置的解析规则（change `add-agent-object-and-templates` 任务 1.1）。
///
/// 这里固定的是**创建实例那一刻**的取值与校验：推理模式推导、窗口必为正整数、
/// 压缩阈值由窗口乘百分比推导、图片模态 / 命令超时 / 不可压缩要求随实例冻结，
/// 以及 provider 密钥不进入可序列化快照。
void main() {
  ProviderResolver providers() => ProviderResolver(const AppConfig(
        version: 1,
        providers: {
          'test': ProviderConfig(apiKey: 'sk-secret-value', baseUrl: 'https://x'),
        },
      ));

  /// 带目录的 provider 引用表（change `model-truth-from-gateway` 1.2）。
  ///
  /// `models` 是持久化目录的形状（`ModelCatalogEntry`，窗口键 `context_window`）；
  /// `null` = 从未探测（配置里没有 models 键）。
  ProviderResolver providersWithCatalog(List<ModelCatalogEntry>? models) =>
      ProviderResolver(AppConfig(
        version: 1,
        providers: {
          'magpie': ProviderConfig(
            apiKey: 'k',
            baseUrl: 'https://x',
            models: models ?? const [],
            discoveredAt: models == null ? null : '2026-11-09T00:00:00.000Z',
          ),
        },
      ));

  AgentTypeConfig template({
    String name = 'general',
    String? thinkingEffort,
    int? maxContextTokens = 1000000,
    List<String> tools = const ['read_file'],
    List<String> modalities = const ['text', 'image'],
    int commandTimeoutMs = 15000,
    int commandMaxTimeoutMs = 45000,
    List<String> standing = const ['不要删除用户文件'],
    int threshold = 25,
    int wait = 75,
    String provider = 'test',
    String model = 'model-a',
  }) =>
      AgentTypeConfig(
        name: name,
        provider: provider,
        model: model,
        systemPrompt: '你是助手',
        tools: tools,
        thinkingEffort: thinkingEffort,
        maxContextTokens: maxContextTokens,
        compactionThresholdPercent: threshold,
        compactionWaitThresholdPercent: wait,
        inputModalities: modalities,
        commandTimeoutMs: commandTimeoutMs,
        commandMaxTimeoutMs: commandMaxTimeoutMs,
        standingRequirements: standing,
      );

  group('推理模式与强度', () {
    test('五个合法强度都解析为 adaptive 并保留原值', () {
      for (final effort in AgentConfigResolver.kThinkingEfforts) {
        final resolved = AgentConfigResolver(providers())
            .resolve(template: template(thinkingEffort: effort), spillPreviewChars: 1000);
        // ignore: avoid_print
        print('  [OBS] thinking_effort=$effort -> mode=${resolved.thinkingMode} '
            'effort=${resolved.thinkingEffort}');
        expect(resolved.thinkingMode, 'adaptive');
        expect(resolved.thinkingEffort, effort);
      }
    });

    test('缺失与非法强度都解析为 disabled 且强度为空串', () {
      for (final effort in <String?>[null, '', 'turbo', 'MAX']) {
        final resolved = AgentConfigResolver(providers()).resolve(
            template: template(thinkingEffort: effort), spillPreviewChars: 1000);
        // ignore: avoid_print
        print('  [OBS] thinking_effort=${effort ?? "(缺失)"} -> '
            'mode=${resolved.thinkingMode} effort="${resolved.thinkingEffort}"');
        expect(resolved.thinkingMode, 'disabled');
        expect(resolved.thinkingEffort, '');
      }
    });
  });

  group('上下文窗口', () {
    test('缺失、零、负数都拒绝创建，错误消息带模板名', () {
      for (final value in <int?>[null, 0, -1]) {
        var message = '';
        try {
          AgentConfigResolver(providers()).resolve(
              template: template(name: '坏窗口模板', maxContextTokens: value),
              spillPreviewChars: 1000);
          fail('max_context_tokens=$value 必须被拒绝，不许按 0 继续发送全文');
        } on InvalidAgentContextWindowException catch (e) {
          message = e.toString();
        }
        // ignore: avoid_print
        print('  [OBS] max_context_tokens=$value 被拒绝：$message');
        expect(message, contains('坏窗口模板'),
            reason: '用户必须知道是哪个模板坏了');
        expect(message, contains('正整数'));
        expect(message, contains('拒绝创建'));
      }
    });

    test('100 万 token × 25% = 25 万 token 的压缩阈值（推导，不是配置里的绝对数）', () {
      final resolved = AgentConfigResolver(providers()).resolve(
          template: template(maxContextTokens: 1000000, threshold: 25),
          spillPreviewChars: 1000);
      // ignore: avoid_print
      print('  [OBS] 窗口=${resolved.maxContextTokens} × '
          '${resolved.compactionThresholdPercent}% = '
          '${resolved.compactionThresholdTokens}');
      expect(resolved.maxContextTokens, 1000000);
      expect(resolved.compactionThresholdTokens, 250000);
    });

    test('换模型时编辑器必须当场确认窗口', () {
      // ignore: avoid_print
      print('  [OBS] 同模型 -> ${AgentConfigResolver.windowConfirmationRequired(previousModel: "a", nextModel: "a")}；'
          '换模型 -> ${AgentConfigResolver.windowConfirmationRequired(previousModel: "a", nextModel: "b")}；'
          '清空模型 -> ${AgentConfigResolver.windowConfirmationRequired(previousModel: "a", nextModel: " ")}');
      expect(
          AgentConfigResolver.windowConfirmationRequired(
              previousModel: 'a', nextModel: 'a'),
          isFalse);
      expect(
          AgentConfigResolver.windowConfirmationRequired(
              previousModel: 'a', nextModel: 'b'),
          isTrue,
          reason: '换模型必须重新确认窗口，不能沿用旧模型的窗口值');
      expect(
          AgentConfigResolver.windowConfirmationRequired(
              previousModel: 'a', nextModel: '  '),
          isFalse,
          reason: '空模型由"模型非空"那条校验拦，不属于窗口确认');
    });
  });

  // change `model-truth-from-gateway` 1.2：D1 窗口链 + D6 思考链的 unit 断言。
  group('目录链（model-truth-from-gateway）', () {
    const flashEntry = ModelCatalogEntry(
      id: 'deepseek/deepseek-flash',
      displayName: 'DeepSeek-V4.1-Flash',
      contextWindow: 1048576,
      reasoningEfforts: ['none', 'low', 'high', 'max'],
    );
    const qwenEntry = ModelCatalogEntry(
      id: 'qwen/qwen-max',
      displayName: 'Qwen Max',
      contextWindow: 131072,
      reasoningEfforts: ['none', 'low', 'medium', 'xhigh'],
    );
    const noReasoningEntry = ModelCatalogEntry(
      id: 'plain/model',
      displayName: '无推理',
      contextWindow: 32000,
      reasoningEfforts: [],
    );

    /// 捕获 debugPrint 的全部输出（与 `agent_type_config_command_test.dart` 同一手法）。
    ({T value, List<String> logs}) capture<T>(T Function() body) {
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) captured.add(message);
      };
      try {
        return (value: body(), logs: captured);
      } finally {
        debugPrint = original;
      }
    }

    test('窗口：目录有正数窗口 ⇒ 一律以目录为准，覆盖值被忽略并打日志点名', () {
      ({ResolvedAgentConfig value, List<String> logs}) resolveWith(int override) =>
          capture(() => AgentConfigResolver(providersWithCatalog(const [flashEntry]))
              .resolve(
            template: template(
              provider: 'magpie',
              model: 'deepseek/deepseek-flash',
              maxContextTokens: override,
            ),
            spillPreviewChars: 1000,
          ));

      final smaller = resolveWith(200000);
      final bigger = resolveWith(4000000);
      // ignore: avoid_print
      print('  [OBS] 目录 ${flashEntry.contextWindow}：覆盖 200000 ⇒ 生效='
          '${smaller.value.maxContextTokens}，日志=${smaller.logs.where((l) => l.contains("被忽略")).toList()}');
      // ignore: avoid_print
      print('  [OBS] 覆盖 4000000 ⇒ 生效=${bigger.value.maxContextTokens}，日志='
          '${bigger.logs.where((l) => l.contains("被忽略")).toList()}');

      expect(smaller.value.maxContextTokens, 1048576,
          reason: '目录值存在且为正 ⇒ 覆盖值必须被忽略');
      expect(smaller.logs.any((l) => l.contains('被忽略') && l.contains('200000')),
          isTrue, reason: '覆盖值被忽略时必须有一行日志点名它（静默忽略等于骗人）');
      expect(bigger.value.maxContextTokens, 1048576);
      expect(bigger.logs.any((l) => l.contains('被忽略') && l.contains('4000000')),
          isTrue, reason: '大于目录方向的覆盖值也要点名');
    });

    test('窗口：目录缺失（未探测 / 无此模型 / 值非正）⇒ 用配置正整数覆盖', () {
      final cases = <String, ({ProviderResolver providers, AgentTypeConfig tpl})>{
        '未探测': (providers: providersWithCatalog(null), tpl: template(provider: 'magpie', maxContextTokens: 777000)),
        '目录无此模型': (providers: providersWithCatalog(const [flashEntry]), tpl: template(provider: 'magpie', model: 'gone/model', maxContextTokens: 666000)),
        '目录窗口非正': (
          providers: providersWithCatalog(const [
            ModelCatalogEntry(id: 'zero/window', contextWindow: 0),
          ]),
          tpl: template(provider: 'magpie', model: 'zero/window', maxContextTokens: 555000),
        ),
      };
      for (final entry in cases.entries) {
        final resolved = AgentConfigResolver(entry.value.providers).resolve(
          template: entry.value.tpl,
          spillPreviewChars: 1000,
        );
        // ignore: avoid_print
        print('  [OBS] ${entry.key} ⇒ 生效窗口=${resolved.maxContextTokens}');
        expect(resolved.maxContextTokens, entry.value.tpl.maxContextTokens,
            reason: '${entry.key} 时必须用覆盖值');
      }
    });

    test('窗口：双缺 ⇒ 抛错，消息带模板名与两条出路，不回落任何数字', () {
      var message = '';
      try {
        AgentConfigResolver(providersWithCatalog(null)).resolve(
          template: template(
            name: '裸配置模板',
            provider: 'magpie',
            model: 'deepseek/deepseek-flash',
            maxContextTokens: null,
          ),
          spillPreviewChars: 1000,
        );
        fail('目录与覆盖都缺时必须拒绝创建');
      } on InvalidAgentContextWindowException catch (e) {
        message = e.toString();
      }
      // ignore: avoid_print
      print('  [OBS] 双缺报错：$message');
      expect(message, contains('裸配置模板'));
      expect(message, contains('Providers 页探测'));
      expect(message, contains('max_context_tokens'));
      expect(message, contains('正整数'));
      expect(message, contains('拒绝创建'));
    });

    test('思考：缺键时按目录取中间档（flash → high，qwen → medium）', () {
      final flash = AgentConfigResolver(providersWithCatalog(const [flashEntry]))
          .resolve(
              template: template(
                  provider: 'magpie', model: 'deepseek/deepseek-flash'),
              spillPreviewChars: 1000);
      final qwen = AgentConfigResolver(providersWithCatalog(const [qwenEntry]))
          .resolve(
              template: template(provider: 'magpie', model: 'qwen/qwen-max'),
              spillPreviewChars: 1000);
      // ignore: avoid_print
      print('  [OBS] 缺键 ⇒ flash=${flash.thinkingMode}/${flash.thinkingEffort}；'
          'qwen=${qwen.thinkingMode}/${qwen.thinkingEffort}');
      expect(flash.thinkingMode, 'adaptive');
      expect(flash.thinkingEffort, 'high',
          reason: 'flash 目录档位 low/high/max ⇒ 按 kThinkingEfforts 顺序取中间档 high');
      expect(qwen.thinkingMode, 'adaptive');
      expect(qwen.thinkingEffort, 'medium',
          reason: 'qwen 目录档位 low/medium/xhigh ⇒ 中间档是 medium（不是字面写死）');
    });

    test('思考：空 / 全 none / 未探测 ⇒ disabled', () {
      final cases = <String, ({ProviderResolver providers, String model})>{
        '空档位': (providers: providersWithCatalog(const [noReasoningEntry]), model: 'plain/model'),
        '全 none': (
          providers: providersWithCatalog(const [
            ModelCatalogEntry(id: 'none/model', contextWindow: 1000, reasoningEfforts: ['none']),
          ]),
          model: 'none/model',
        ),
        '未探测': (providers: providersWithCatalog(null), model: 'deepseek/deepseek-flash'),
      };
      for (final entry in cases.entries) {
        final resolved = AgentConfigResolver(entry.value.providers).resolve(
          template: template(provider: 'magpie', model: entry.value.model),
          spillPreviewChars: 1000,
        );
        // ignore: avoid_print
        print('  [OBS] ${entry.key} ⇒ ${resolved.thinkingMode} '
            '"${resolved.thinkingEffort}"');
        expect(resolved.thinkingMode, 'disabled', reason: '${entry.key} 必须解析为 disabled');
        expect(resolved.thinkingEffort, '');
      }
    });

    test('思考：显式档位永远优先于目录中间档（xhigh）', () {
      final resolved = AgentConfigResolver(providersWithCatalog(const [flashEntry]))
          .resolve(
              template: template(
                provider: 'magpie',
                model: 'deepseek/deepseek-flash',
                thinkingEffort: 'xhigh',
              ),
              spillPreviewChars: 1000);
      // ignore: avoid_print
      print('  [OBS] 显式 xhigh + 目录 low/high/max ⇒ '
          '${resolved.thinkingMode}/${resolved.thinkingEffort}');
      expect(resolved.thinkingMode, 'adaptive');
      expect(resolved.thinkingEffort, 'xhigh');
    });

    test('思考：显式但非法（非白名单）仍解析为 disabled，不被目录推导静默修好', () {
      final resolved = AgentConfigResolver(providersWithCatalog(const [flashEntry]))
          .resolve(
              template: template(
                provider: 'magpie',
                model: 'deepseek/deepseek-flash',
                thinkingEffort: 'turbo',
              ),
              spillPreviewChars: 1000);
      // ignore: avoid_print
      print('  [OBS] 显式 turbo ⇒ ${resolved.thinkingMode} "${resolved.thinkingEffort}"');
      expect(resolved.thinkingMode, 'disabled');
      expect(resolved.thinkingEffort, '');
    });
  });

  group('随实例冻结的字段', () {
    test('图片模态、命令超时、不可压缩要求在模板保存往返后仍保持创建时取值', () {
      final before = AgentConfigResolver(providers()).resolve(
          template: template(), spillPreviewChars: 1000);
      // 保存 = toJson → fromJson（这就是 AgentTemplateController 写回配置的路径）。
      final saved = AgentTypeConfig.fromJson(
          'general', template().toJson());
      final after = AgentConfigResolver(providers())
          .resolve(template: saved, spillPreviewChars: 1000);
      // ignore: avoid_print
      print('  [OBS] 保存前 modalities=${before.inputModalities} '
          'commandTimeout=${before.commandTimeoutMs}/${before.commandMaxTimeoutMs} '
          'standing=${before.standingRequirements}；保存后 '
          'modalities=${after.inputModalities} '
          'commandTimeout=${after.commandTimeoutMs}/${after.commandMaxTimeoutMs} '
          'standing=${after.standingRequirements}');

      expect(after.inputModalities, ['text', 'image']);
      expect(after.commandTimeoutMs, 15000);
      expect(after.commandMaxTimeoutMs, 45000);
      expect(after.standingRequirements, ['不要删除用户文件']);
      expect(after.compactionThresholdPercent, 25);
      expect(after.compactionWaitThresholdPercent, 75);
      expect(after.acceptsImages, isTrue);
      expect(after.templateName, 'general');
    });

    test('已解析的配置是只读的：工具清单不可被就地改写', () {
      final resolved = AgentConfigResolver(providers()).resolve(
          template: template(tools: const ['read_file', 'write_file']),
          spillPreviewChars: 1000);
      var threw = false;
      try {
        resolved.tools.add('run_command');
      } on UnsupportedError {
        threw = true;
      }
      // ignore: avoid_print
      print('  [OBS] 修改 resolved.tools 抛异常=$threw；清单=${resolved.tools}');
      expect(threw, isTrue, reason: '生效配置必须不可变，运行中不许被别的实例改掉');
      expect(resolved.tools, ['read_file', 'write_file']);
    });
  });

  group('provider 与模板错误是显式且可区分的', () {
    test('可序列化快照不含 provider 的 api_key / base_url', () {
      final resolved = AgentConfigResolver(providers())
          .resolve(template: template(), spillPreviewChars: 1000);
      final json = resolved.toJson();
      final key = json.toString();
      // ignore: avoid_print
      print('  [OBS] 快照键=${json.keys.toList()}；含 sk-secret-value='
          '${key.contains('sk-secret-value')}；含 api_key=${key.contains('api_key')}');
      expect(key.contains('sk-secret-value'), isFalse,
          reason: '密钥不允许出现在可序列化快照里');
      expect(key.contains('api_key'), isFalse);
      expect(json['provider'], 'test', reason: '只保留 provider 名字（引用键）');
    });

    test('未定义的 provider 报错并带模板名与 provider 名', () {
      var message = '';
      try {
        AgentConfigResolver(providers()).resolve(
            template: template(provider: 'nope'), spillPreviewChars: 1000);
        // resolve 本身只产出引用；取 provider 时才校验（创建路径就是这样调的）。
        AgentConfigResolver(providers()).resolveProvider(
            AgentConfigResolver(providers()).resolve(
                template: template(provider: 'nope'), spillPreviewChars: 1000));
        fail('未定义的 provider 必须被拒绝');
      } on MissingAgentProviderException catch (e) {
        message = e.toString();
      }
      // ignore: avoid_print
      print('  [OBS] 未定义 provider 的报错：$message');
      expect(message, contains('general'));
      expect(message, contains('nope'));
      expect(message, contains('未定义'));
    });

    test('不存在的模板名给出可区分错误，不退回 general', () {
      final e = MissingAgentTemplateException('reviewer');
      // ignore: avoid_print
      print('  [OBS] 缺失模板错误：$e');
      expect(e.toString(), contains('reviewer'));
      expect(e.toString(), contains('不会退回 general'));
    });
  });
}
