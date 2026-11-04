import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/provider_config.dart';
import '../services/config_service.dart';
import '../services/tool_catalog.dart';

/// 首启 / 补问的两步向导（change `add-provider-model-discovery` 任务 5.1，design D8）。
///
/// 第一步收集 Provider 三要素（名字 / 网关地址 / 密钥），第二步保留既有的
/// "上下文窗口必填正整数"——那一步是补问的触发条件，不能被砍掉，否则对话框会反复弹出。
/// 整条向导完成前不可关闭：调用方用 `barrierDismissible: false` 打开它。
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
  static const int _stepProvider = 0;
  static const int _stepWindow = 1;

  /// 首启默认 Provider：名字 → 标准 API 端点（与 `Docs/user-guide/configuration.md`
  /// 里的示例一致）。名字是用户可改的默认值，不是写死的唯一供应商。
  ///
  /// 用户 2026-11-04 裁定：默认改用本机 magpie 网关（`http://127.0.0.1:3425`），
  /// 不再沿用 `anthropic` / `https://api.anthropic.com`。
  static const Map<String, String> kFirstRunDefaults = {
    'magpie': 'http://127.0.0.1:3425',
  };

  /// 首启默认密钥：magpie 网关的密钥约定就叫 `magpie`（用户 2026-11-04 原话
  /// 「另外 magpie 的 APIkey 就叫 magpie」）。补问不回填旧密钥，保持空白。
  static const String kFirstRunDefaultApiKey = 'magpie';

  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _contextTokensController = TextEditingController();

  /// 打开时 `general` 实际在用的 provider 名；补问时"写回它"，首启是 `magpie`。
  late final String _initialProviderName;

  int _step = _stepProvider;
  String? _error;
  bool _saving = false;

  bool get _isFollowUp => widget.existingConfig != null;

  @override
  void initState() {
    super.initState();
    final general = widget.existingConfig?.agentTypes['general'];
    _initialProviderName =
        (general != null && general.provider.isNotEmpty) ? general.provider : 'magpie';
    _nameCtrl.text = _initialProviderName;
    final existingProvider =
        widget.existingConfig?.providers[_initialProviderName];
    _urlCtrl.text = (existingProvider != null && existingProvider.baseUrl.isNotEmpty)
        ? existingProvider.baseUrl
        : (kFirstRunDefaults[_initialProviderName] ??
            kFirstRunDefaults.values.first);
    // 首启预填 magpie 的约定密钥；补问保持空白（旧密钥不回显、要重新输入）。
    _keyCtrl.text = _isFollowUp ? '' : kFirstRunDefaultApiKey;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _contextTokensController.dispose();
    super.dispose();
  }

  /// 第一步校验。失败时点名字段、保留用户已填的其它内容，并停在第一步。
  void _nextStep() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写 Provider 名称');
      return;
    }
    final otherNames = (widget.existingConfig?.providers.keys ?? const <String>[])
        .where((n) => n != _initialProviderName)
        .toSet();
    if (otherNames.contains(name)) {
      setState(() => _error = 'Provider "$name" 已存在');
      return;
    }
    final rawUrl = _urlCtrl.text.trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _error = '网关地址必须是以 http:// 或 https:// 开头的绝对地址');
      return;
    }
    if (_keyCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please enter an API key');
      return;
    }
    setState(() {
      _error = null;
      _step = _stepWindow;
    });
  }

  void _submit() {
    if (_step == _stepProvider) {
      _nextStep();
      return;
    }

    final tokensText = _contextTokensController.text.trim();
    final maxContextTokens = int.tryParse(tokensText);
    if (tokensText.isEmpty || maxContextTokens == null || maxContextTokens <= 0) {
      setState(() => _error = 'Please enter a valid max context token count (a positive integer)');
      return;
    }

    setState(() => _saving = true);

    final config = _mergeConfig(
      providerName: _nameCtrl.text.trim(),
      baseUrl: _urlCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
      maxContextTokens: maxContextTokens,
    );
    if (widget.saveConfig != null) {
      widget.saveConfig!(config);
    } else {
      ConfigService.save(config);
    }

    widget.onComplete();
  }

  /// 把这次输入**合并**到现有配置上：只替换该 Provider 的三要素与 general 的窗口，
  /// 其余原样保留。补问时若改了 Provider 名，所有引用旧名的模板在同一次写回里改过去，
  /// 不留悬空引用。
  AppConfig _mergeConfig({
    required String providerName,
    required String baseUrl,
    required String apiKey,
    required int maxContextTokens,
  }) {
    final existing = widget.existingConfig;
    final providers = <String, ProviderConfig>{
      ...?existing?.providers,
    };
    final previous = providers[providerName] ?? providers[_initialProviderName];
    providers[providerName] = ProviderConfig(
      apiKey: apiKey,
      baseUrl: normalizeBaseUrl(baseUrl),
      models: previous?.models ?? const [],
      discoveredAt: previous?.discoveredAt,
    );
    if (providerName != _initialProviderName && existing != null) {
      providers.remove(_initialProviderName);
    }

    final types = <String, AgentTypeConfig>{
      ...?existing?.agentTypes,
    };
    if (providerName != _initialProviderName) {
      for (final entry in types.entries.toList()) {
        if (entry.value.provider == _initialProviderName) {
          types[entry.key] = AgentTypeConfig.fromJson(entry.key, {
            ...entry.value.toJson(),
            'provider': providerName,
          });
        }
      }
    }

    final general = types['general'];
    if (general != null) {
      // 补问时把密钥写给它实际在用的 provider，并只改窗口；其余字段原样保留。
      types['general'] = AgentTypeConfig.fromJson('general', {
        ...general.toJson(),
        'provider': providerName,
        'max_context_tokens': maxContextTokens,
      });
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
          Text(
            _step == _stepProvider
                ? '第 1 步 / 共 2 步：填一个 Provider（名字、网关地址、密钥）。'
                : '第 2 步 / 共 2 步：这个模型的上下文窗口。',
          ),
          const SizedBox(height: 16),
          if (_step == _stepProvider) ..._providerFields() else _windowField(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const ValueKey('setup-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        if (_step == _stepWindow)
          TextButton(
            key: const ValueKey('setup-back'),
            onPressed: _saving ? null : () => setState(() => _step = _stepProvider),
            child: const Text('上一步'),
          ),
        TextButton(
          key: ValueKey(_step == _stepProvider ? 'setup-next' : 'setup-start'),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_step == _stepProvider ? '下一步' : 'Start'),
        ),
      ],
    );
  }

  List<Widget> _providerFields() => [
        TextField(
          key: const ValueKey('setup-provider-name'),
          controller: _nameCtrl,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Provider 名称',
            hintText: 'magpie',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('setup-base-url'),
          controller: _urlCtrl,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: '网关地址',
            hintText: 'http://127.0.0.1:3425',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('setup-api-key'),
          controller: _keyCtrl,
          enabled: !_saving,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'API Key',
            hintText: _isFollowUp ? '重新输入密钥（不会回显旧值）' : 'magpie',
            border: const OutlineInputBorder(),
          ),
        ),
      ];

  Widget _windowField() => TextField(
        key: const ValueKey('setup-max-context-tokens'),
        controller: _contextTokensController,
        enabled: !_saving,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: const InputDecoration(
          labelText: 'Max Context Tokens',
          hintText: 'e.g. 200000',
          helperText: 'Compaction threshold (one-time setting)',
          border: OutlineInputBorder(),
        ),
      );
}
