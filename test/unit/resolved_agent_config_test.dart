import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/models/agent_type_config.dart';
import 'package:alias_agent/models/app_config.dart';
import 'package:alias_agent/models/provider_config.dart';
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
  }) =>
      AgentTypeConfig(
        name: name,
        provider: provider,
        model: 'model-a',
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
