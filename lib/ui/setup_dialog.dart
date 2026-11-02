import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/provider_config.dart';
import '../services/config_service.dart';
import '../services/tool_catalog.dart';

class SetupDialog extends StatefulWidget {
  final VoidCallback onComplete;
  final void Function(AppConfig)? saveConfig;

  /// 已经加载到的现有配置（首启补问时非空）。
  ///
  /// 补问只缺 `general.max_context_tokens`（或密钥），**不许**拿一份新的缺省配置
  /// 整份覆盖：providers、search、spill 与其它模板都要合并保留。首启时传 null。
  final AppConfig? existingConfig;

  const SetupDialog({
    super.key,
    required this.onComplete,
    this.saveConfig,
    this.existingConfig,
  });

  @override
  State<SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<SetupDialog> {
  final _keyController = TextEditingController();
  final _contextTokensController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _keyController.dispose();
    _contextTokensController.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Please enter an API key');
      return;
    }

    final tokensText = _contextTokensController.text.trim();
    final maxContextTokens = int.tryParse(tokensText);
    if (tokensText.isEmpty || maxContextTokens == null || maxContextTokens <= 0) {
      setState(() => _error = 'Please enter a valid max context token count (a positive integer)');
      return;
    }

    setState(() => _saving = true);

    final config = _mergeConfig(key, maxContextTokens);
    if (widget.saveConfig != null) {
      widget.saveConfig!(config);
    } else {
      ConfigService.save(config);
    }

    widget.onComplete();
  }

  /// 把这次输入**合并**到现有配置上：只替换密钥与窗口，其余原样保留。
  ///
  /// 首启（没有现有配置）才生成一条 `general`；补问时沿用现有 `general` 的模型、
  /// 系统提示词、工具、图片模态、命令超时、压缩参数和不可压缩要求。
  AppConfig _mergeConfig(String apiKey, int maxContextTokens) {
    final existing = widget.existingConfig;
    final providers = <String, ProviderConfig>{};
    if (existing == null) {
      // 首启写出的供应商键名固定是 anthropic（与用户文档里的示例一致）。
      providers['anthropic'] = ProviderConfig(
        apiKey: apiKey,
        baseUrl: 'https://api.anthropic.com',
      );
    }
    providers.addAll(existing?.providers ?? const {});
    final types =
        Map<String, AgentTypeConfig>.from(existing?.agentTypes ?? const {});

    final general = types['general'];
    // 补问时把密钥写给它实际在用的 provider；首启用 anthropic。
    final providerName =
        (general != null && general.provider.isNotEmpty) ? general.provider : 'anthropic';
    final previousProvider = providers[providerName];
    providers[providerName] = ProviderConfig(
      apiKey: apiKey,
      baseUrl: (previousProvider != null && previousProvider.baseUrl.isNotEmpty)
          ? previousProvider.baseUrl
          : 'https://api.anthropic.com',
    );

    if (general != null) {
      types['general'] = AgentTypeConfig(
        name: general.name,
        provider: providerName,
        model: general.model,
        systemPrompt: general.systemPrompt,
        tools: general.tools,
        thinkingEffort: general.thinkingEffort,
        maxContextTokens: maxContextTokens,
        compactionThresholdPercent: general.compactionThresholdPercent,
        compactionWaitThresholdPercent: general.compactionWaitThresholdPercent,
        inputModalities: general.inputModalities,
        commandTimeoutMs: general.commandTimeoutMs,
        commandMaxTimeoutMs: general.commandMaxTimeoutMs,
        standingRequirements: general.standingRequirements,
      );
    } else {
      types['general'] = AgentTypeConfig(
        name: 'general',
        provider: providerName,
        model: 'claude-sonnet-4-6',
        systemPrompt: 'You are a helpful assistant.',
        // 首启默认清单覆盖当前基础工具（不是旧版那两项）。
        tools: ToolCatalog.kBaseToolNames,
        maxContextTokens: maxContextTokens,
        // 默认只有文本，图片不发（模型能不能看图由这一项声明，见
        // Docs/user-guide/configuration.md 的 input_modalities）。
        inputModalities: AgentTypeConfig.kDefaultInputModalities,
      );
    }

    return (existing ?? const AppConfig(version: 1))
        .copyWith(providers: providers, agentTypes: types);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Welcome to AliasAgent'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'To get started, enter your Anthropic API key.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _keyController,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-ant-...',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            enabled: !_saving,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contextTokensController,
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
            decoration: InputDecoration(
              labelText: 'Max Context Tokens',
              hintText: 'e.g. 200000',
              helperText: 'Compaction threshold (one-time setting)',
              border: const OutlineInputBorder(),
            ),
            enabled: !_saving,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}
